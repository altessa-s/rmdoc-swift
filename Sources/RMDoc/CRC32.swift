// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The zip flavour of CRC-32: the IEEE polynomial, reflected.
///
/// Not the CRC-32C the cloud's blob storage demands — same name, different
/// polynomial — which is why each implementation lives beside its own
/// format instead of one pretending to serve both.
///
/// In three parts rather than one call, because the streaming writer meets
/// a payload a chunk at a time and must not hold it whole just to check
/// it: `start`, then `adding` per chunk, then `finished`.
enum CRC32 {
    /// Slice-by-eight: eight tables, each the one before it advanced by a
    /// byte, so eight input bytes fold into the register with eight lookups
    /// instead of eight dependent round trips through one table.
    ///
    /// Measured on a ten-megabyte archive: packing 20.3 ms byte-at-a-time
    /// against 5.0 ms this way, unpacking 20.9 ms against 4.5 ms — a little
    /// over four times, in release. The checksum runs twice
    /// over every attachment — once packing, once verifying — and a
    /// book-sized PDF is exactly the payload an `.rmdoc` carries, so this is
    /// the one place in the package where the obvious loop was not enough.
    ///
    /// Flat rather than eight arrays: `[[UInt32]]` is a pointer chase per
    /// lookup, which is most of what the extra tables just bought.
    private static let tables: [UInt32] = {
        var tables = [UInt32](repeating: 0, count: 8 * 256)
        for index in 0 ..< 256 {
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
            tables[index] = value
        }
        for index in 0 ..< 256 {
            for slice in 1 ..< 8 {
                let previous = tables[(slice - 1) * 256 + index]
                tables[slice * 256 + index] = (previous >> 8) ^ tables[Int(previous & 0xFF)]
            }
        }
        return tables
    }()

    /// Where a running checksum begins.
    static let start: UInt32 = .max

    /// The running checksum advanced over the next chunk.
    ///
    /// Over the raw buffer rather than byte-by-byte through Data's
    /// subscript: the subscript is bounds-checked and non-contiguous-aware,
    /// and neither is worth paying per byte of an attachment.
    static func adding(_ data: Data, to crc: UInt32) -> UInt32 {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> UInt32 in
            var crc = crc
            tables.withUnsafeBufferPointer { table in
                var index = 0
                // The words are assembled byte by byte rather than loaded:
                // a zip's checksum is little-endian wherever it is computed,
                // and an unaligned load of the caller's buffer is not ours
                // to assume.
                while index + 8 <= bytes.count {
                    let low = UInt32(bytes[index])
                        | UInt32(bytes[index + 1]) << 8
                        | UInt32(bytes[index + 2]) << 16
                        | UInt32(bytes[index + 3]) << 24
                    let high = UInt32(bytes[index + 4])
                        | UInt32(bytes[index + 5]) << 8
                        | UInt32(bytes[index + 6]) << 16
                        | UInt32(bytes[index + 7]) << 24
                    crc ^= low
                    crc = table[7 * 256 + Int(crc & 0xFF)]
                        ^ table[6 * 256 + Int((crc >> 8) & 0xFF)]
                        ^ table[5 * 256 + Int((crc >> 16) & 0xFF)]
                        ^ table[4 * 256 + Int(crc >> 24)]
                        ^ table[3 * 256 + Int(high & 0xFF)]
                        ^ table[2 * 256 + Int((high >> 8) & 0xFF)]
                        ^ table[1 * 256 + Int((high >> 16) & 0xFF)]
                        ^ table[Int(high >> 24)]
                    index += 8
                }
                // The tail, and any chunk shorter than a word, the plain way.
                while index < bytes.count {
                    crc = table[Int((crc ^ UInt32(bytes[index])) & 0xFF)] ^ (crc >> 8)
                    index += 1
                }
            }
            return crc
        }
    }

    static func finished(_ crc: UInt32) -> UInt32 {
        crc ^ .max
    }

    /// One shot, for bytes already in memory.
    static func checksum(_ data: Data) -> UInt32 {
        finished(adding(data, to: start))
    }
}
