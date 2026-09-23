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
    static func decompress(_ data: Data, count: Int) -> Data? {
        guard count >= 0, count < Int.max, !data.isEmpty else { return nil }
        // Leave room to detect output beyond the declared length, including
        // when that length is zero. Filling a buffer does not prove EOF.
        let capacity = count + 1
        var output = Data(count: capacity)
        let valid = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Bool in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Bool in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return false }
                var stream = compression_stream(
                    dst_ptr: destinationBase, dst_size: 0,
                    src_ptr: sourceBase, src_size: 0, state: nil
                )
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                    != COMPRESSION_STATUS_ERROR else { return false }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = sourceBase
                stream.src_size = data.count
                stream.dst_ptr = destinationBase
                stream.dst_size = capacity
                while true {
                    let previousInput = stream.src_size
                    let previousOutput = stream.dst_size
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    if status == COMPRESSION_STATUS_END {
                        return stream.src_size == 0 && capacity - stream.dst_size == count
                    }
                    guard status == COMPRESSION_STATUS_OK, stream.dst_size > 0,
                          stream.src_size < previousInput || stream.dst_size < previousOutput
                    else { return false }
                }
            }
        }
        guard valid else { return nil }
        output.removeLast()
        return output
    }
}
