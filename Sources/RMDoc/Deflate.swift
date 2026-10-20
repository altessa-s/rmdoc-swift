// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Compression
import Foundation

/// Raw deflate, the way a zip entry holds it — Apple's `COMPRESSION_ZLIB`
/// is exactly that, no zlib wrapper around it.
enum Deflate {
    /// Deflate cannot expand its input by more than 1032:1, so an entry
    /// claiming a larger ratio is lying about one of its two lengths. The
    /// reader checks the claim before allocating against it: the alternative
    /// is a two-hundred-byte file that asks for four gigabytes.
    static let maximumRatio = 1032

    /// Where the output buffer starts, and the step it doubles from. Small
    /// enough that a claim nobody has kept yet costs nothing to begin on.
    static let initialCapacity = 256 * 1024

    /// The squeezed bytes, or the input unchanged when squeezing failed —
    /// the caller compares lengths and stores the entry in that case, so a
    /// failure here costs size, never correctness.
    static func compress(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var output = Data(count: data.count + 256)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBase, data.count + 256, sourceBase, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return data }
        // Copied out rather than sliced: `prefix` would keep the whole
        // over-allocated buffer alive behind a short entry, and the payload
        // this package carries is a book-sized PDF.
        return Data(output.prefix(written))
    }

    /// The entry's bytes back, or `nil` when they do not inflate to exactly
    /// the length the directory promised. `count` is that promise and is
    /// bounded by the caller before it reaches here — a wrong one is a
    /// malformed archive, never a short read passed off as the payload.
    ///
    /// Streamed, and never ahead of the stream. The declared length is not
    /// allocated up front: the buffer starts small and doubles only as the
    /// decoder fills it, never past `count`, so what memory sees is what the
    /// payload has actually produced. Once `count` bytes are out, the decoder
    /// is handed a single spare byte — enough to tell "ended here" from "had
    /// more to say" without producing the more.
    static func decompress(_ data: Data, count: Int) -> Data? {
        data.withUnsafeBytes { decompress($0, count: count) }
    }

    /// The same, straight out of the caller's bytes — a range of a mapped
    /// archive, typically — so the compressed payload is never copied: what
    /// a read allocates is what the entry inflates to, and nothing for what
    /// it occupies.
    static func decompress(_ source: UnsafeRawBufferPointer, count: Int) -> Data? {
        guard count >= 0, count < Int.max, !source.isEmpty,
              let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        var buffer = Buffer(limit: count)
        let valid = inflate(sourceBase, count: source.count, into: &buffer)
        guard valid, buffer.produced == count else {
            buffer.release()
            return nil
        }
        return buffer.take()
    }

    private static func inflate(_ source: UnsafePointer<UInt8>, count: Int, into buffer: inout Buffer) -> Bool {
        let spare = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { spare.deallocate() }
        var stream = compression_stream(
            dst_ptr: spare, dst_size: 0, src_ptr: source, src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            != COMPRESSION_STATUS_ERROR else { return false }
        defer { compression_stream_destroy(&stream) }
        stream.src_ptr = source
        stream.src_size = count
        while true {
            guard let window = buffer.window() else { return false }
            // Past the promise, only the spare byte is on offer.
            let overrun = window.room == 0
            stream.dst_ptr = overrun ? spare : (window.base ?? spare)
            stream.dst_size = overrun ? 1 : window.room
            let previousInput = stream.src_size
            let previousOutput = stream.dst_size
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let written = previousOutput - stream.dst_size
            if overrun {
                // The stream had more than the directory promised.
                guard written == 0 else { return false }
            } else {
                buffer.produced += written
            }
            if status == COMPRESSION_STATUS_END {
                return stream.src_size == 0
            }
            guard status == COMPRESSION_STATUS_OK,
                  stream.src_size < previousInput || written > 0
            else { return false }
        }
    }

    /// Memory that grows with the stream: allocated with `malloc` so it can
    /// be grown with `realloc` and handed to `Data` without a copy.
    private struct Buffer {
        let limit: Int
        var storage: UnsafeMutableRawPointer?
        var capacity = 0
        var produced = 0

        init(limit: Int) {
            self.limit = limit
        }

        /// Where the decoder writes next, growing first if the buffer is
        /// full and the promise allows it. An empty window means the promise
        /// is kept to the byte; `nil`, that memory ran out.
        mutating func window() -> (base: UnsafeMutablePointer<UInt8>?, room: Int)? {
            if produced == capacity, capacity < limit {
                let grown = min(limit, max(capacity * 2, Deflate.initialCapacity))
                guard let moved = realloc(storage, grown) else { return nil }
                storage = moved
                capacity = grown
            }
            guard let storage else { return (nil, 0) }
            let base = storage.advanced(by: produced).assumingMemoryBound(to: UInt8.self)
            return (base, capacity - produced)
        }

        /// The bytes, owned by the `Data` from here on.
        mutating func take() -> Data {
            guard let storage, produced > 0 else {
                release()
                return Data()
            }
            self.storage = nil
            return Data(bytesNoCopy: storage, count: produced, deallocator: .free)
        }

        mutating func release() {
            free(storage)
            storage = nil
        }
    }
}
