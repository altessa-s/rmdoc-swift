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
        guard count > 0 else { return Data() }
        var output = Data(count: count)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, count, sourceBase, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == count else { return nil }
        return output
    }
}
