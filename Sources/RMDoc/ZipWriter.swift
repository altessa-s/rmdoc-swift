// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Writing the container.
///
/// Written by hand because the platform offers no zip container API and a
/// third-party archiver is a heavy dependency for two dozen header fields.
/// Packing is deterministic on purpose — a fixed timestamp, entries in the
/// order given — so the same document packs into the same bytes and a test
/// can hold it to that.
///
/// Apart from the reader, deliberately: what may be written is a narrower
/// question than what must be read, and one type answering both invites the
/// reader's tolerance into the writer.
enum ZipWriter {
    /// 1980-01-01, the earliest moment DOS time can spell. A real
    /// modification date would make two packs of one document differ.
    private static let dosDate: UInt16 = 0x0021
    private static let dosTime: UInt16 = 0

    /// One entry as the central directory will restate it. Internal rather
    /// than private: `RMDocWriter` gathers the same records while streaming
    /// and closes them with the same `closing(records:directoryOffset:)`.
    struct Record {
        let name: Data
        let crc: UInt32
        /// Uncompressed — and beside it what actually went into the file:
        /// equal for a stored entry, smaller for a deflated one.
        let size: UInt32
        let compressedSize: UInt32
        let method: UInt16
        let offset: UInt32
    }

    /// The header before an entry's payload. The writer hands zeros for the
    /// checksum and the sizes of a streamed file — they are known only once
    /// the payload has gone past, and `patch(crc:size:)` writes them back.
    static func localHeader(name: Data, crc: UInt32, size: UInt32) -> Data {
        localHeader(name: name, crc: crc, compressedSize: size, uncompressedSize: size, method: 0)
    }

    static func localHeader(
        name: Data, crc: UInt32, compressedSize: UInt32, uncompressedSize: UInt32, method: UInt16
    ) -> Data {
        var out = Data()
        out.appendLE(UInt32(0x0403_4B50))               // local file header
        out.appendLE(UInt16(method == 0 ? 10 : 20))     // version needed
        out.appendLE(UInt16(0))                         // flags
        out.appendLE(method)
        out.appendLE(dosTime)
        out.appendLE(dosDate)
        out.appendLE(crc)
        out.appendLE(compressedSize)
        out.appendLE(uncompressedSize)
        out.appendLE(UInt16(name.count))
        out.appendLE(UInt16(0))                         // extra
        out.append(name)
        return out
    }

    /// Where the patch lands: bytes 14..<26 of a local header are the
    /// checksum and the two sizes.
    static let patchOffset = 14

    static func patch(crc: UInt32, size: UInt32) -> Data {
        var out = Data()
        out.appendLE(crc)
        out.appendLE(size)
        out.appendLE(size)
        return out
    }

    /// The central directory and the end record — everything after the last
    /// payload, for both producers.
    static func closing(records: [Record], directoryOffset: UInt32) -> Data {
        var out = Data()
        for record in records {
            out.appendLE(UInt32(0x0201_4B50))           // central directory
            out.appendLE(UInt16(20))                    // made by: MS-DOS, 2.0
            out.appendLE(UInt16(record.method == 0 ? 10 : 20))  // version needed
            out.appendLE(UInt16(0))                     // flags
            out.appendLE(record.method)
            out.appendLE(dosTime)
            out.appendLE(dosDate)
            out.appendLE(record.crc)
            out.appendLE(record.compressedSize)
            out.appendLE(record.size)
            out.appendLE(UInt16(record.name.count))
            out.appendLE(UInt16(0))                     // extra
            out.appendLE(UInt16(0))                     // comment
            out.appendLE(UInt16(0))                     // disk number
            out.appendLE(UInt16(0))                     // internal attributes
            out.appendLE(UInt32(0))                     // external attributes
            out.appendLE(record.offset)
            out.append(record.name)
        }
        let directorySize = UInt32(out.count)
        out.appendLE(UInt32(0x0605_4B50))               // end of central directory
        out.appendLE(UInt16(0))                         // this disk
        out.appendLE(UInt16(0))                         // directory disk
        out.appendLE(UInt16(records.count))             // entries on this disk
        out.appendLE(UInt16(records.count))             // entries in total
        out.appendLE(directorySize)
        out.appendLE(directoryOffset)
        out.appendLE(UInt16(0))                         // comment
        return out
    }

    static func pack(_ entries: [ZipEntry]) -> Data {
        var body = Data()
        // Exactly what the archive will weigh: a local header (30 bytes and
        // the name), the payload, a directory entry (46 and the name again),
        // and the 22-byte end record. Sized once rather than grown into.
        body.reserveCapacity(entries.reduce(22) { total, entry in
            total + 76 + 2 * entry.name.utf8.count + entry.data.count
        })
        var records: [Record] = []
        records.reserveCapacity(entries.count)
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            records.append(Record(
                name: name, crc: crc, size: size,
                compressedSize: size, method: 0, offset: UInt32(body.count)
            ))
            body.append(localHeader(name: name, crc: crc, size: size))
            body.append(entry.data)
        }
        let directoryOffset = UInt32(body.count)
        body.append(closing(records: records, directoryOffset: directoryOffset))
        return body
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(value & 0xFFFF))
        appendLE(UInt16(value >> 16))
    }
}
