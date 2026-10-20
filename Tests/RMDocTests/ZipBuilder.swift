// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMDoc

/// A zip spelled field by field, for the archives the writer will not make:
/// every claim the reader checks can be set to a lie here, one at a time,
/// with everything else left honest.
struct ZipBuilder {
    struct Entry {
        var name: String
        /// The bytes as they stand in the file: stored, or already deflated.
        var payload: Data
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var flags: UInt16 = 0
        var startDisk: UInt16 = 0
        var centralExtra = Data()
        var centralComment = Data()
        var localExtra = Data()
        /// What the local header says, where it should differ from the
        /// directory.
        var localName: String?
        var localMethod: UInt16?
        var localFlags: UInt16?
        var localCRC: UInt32?
        var localCompressedSize: UInt32?
        var localUncompressedSize: UInt32?
        /// Bytes after the payload: a data descriptor, honest or not.
        var trailer = Data()
        /// Where the directory says the local header is, when that is not
        /// where it was written — or `writeLocal` is false and it was never
        /// written on its own at all.
        var localOffset: UInt32?
        var writeLocal = true

        static func stored(_ name: String, _ data: Data) -> Entry {
            let size = UInt32(data.count)
            return Entry(
                name: name, payload: data, method: 0,
                crc: CRC32.checksum(data), compressedSize: size, uncompressedSize: size
            )
        }

        static func deflated(_ name: String, _ data: Data) -> Entry {
            let squeezed = Deflate.compress(data)
            return Entry(
                name: name, payload: squeezed, method: 8, crc: CRC32.checksum(data),
                compressedSize: UInt32(squeezed.count), uncompressedSize: UInt32(data.count)
            )
        }

        /// The local header this entry would be written with.
        var localHeader: Data {
            var out = Data()
            let nameData = Data((localName ?? name).utf8)
            out.le32(0x0403_4B50)
            out.le16(20)
            out.le16(localFlags ?? flags)
            out.le16(localMethod ?? method)
            out.le16(0)
            out.le16(0x0021)
            out.le32(localCRC ?? crc)
            out.le32(localCompressedSize ?? compressedSize)
            out.le32(localUncompressedSize ?? uncompressedSize)
            out.le16(UInt16(nameData.count))
            out.le16(UInt16(localExtra.count))
            out.append(nameData)
            out.append(localExtra)
            return out
        }
    }

    var entries: [Entry]
    /// End-record fields, where they should lie.
    var thisDisk: UInt16 = 0
    var directoryDisk: UInt16 = 0
    var entriesOnDisk: UInt16?
    var entryCount: UInt16?
    /// Bytes inside the central directory after the last counted record.
    var directoryTrailer = Data()
    /// A ZIP64 end-of-directory locator right before the end record.
    var zip64Locator = false

    init(_ entries: [Entry]) {
        self.entries = entries
    }

    func build() -> Data {
        var out = Data()
        var offsets: [UInt32] = []
        for entry in entries {
            offsets.append(entry.localOffset ?? UInt32(out.count))
            guard entry.writeLocal else { continue }
            out.append(entry.localHeader)
            out.append(entry.payload)
            out.append(entry.trailer)
        }
        let directoryOffset = UInt32(out.count)
        for (entry, offset) in zip(entries, offsets) {
            let nameData = Data(entry.name.utf8)
            out.le32(0x0201_4B50)
            out.le16(20)
            out.le16(20)
            out.le16(entry.flags)
            out.le16(entry.method)
            out.le16(0)
            out.le16(0x0021)
            out.le32(entry.crc)
            out.le32(entry.compressedSize)
            out.le32(entry.uncompressedSize)
            out.le16(UInt16(nameData.count))
            out.le16(UInt16(entry.centralExtra.count))
            out.le16(UInt16(entry.centralComment.count))
            out.le16(entry.startDisk)
            out.le16(0)
            out.le32(0)
            out.le32(offset)
            out.append(nameData)
            out.append(entry.centralExtra)
            out.append(entry.centralComment)
        }
        out.append(directoryTrailer)
        let directorySize = UInt32(out.count) - directoryOffset
        if zip64Locator {
            out.le32(0x0706_4B50)
            out.le32(0)
            out.le32(0)
            out.le32(0)
            out.le32(1)
        }
        out.le32(0x0605_4B50)
        out.le16(thisDisk)
        out.le16(directoryDisk)
        out.le16(entriesOnDisk ?? UInt16(entries.count))
        out.le16(entryCount ?? UInt16(entries.count))
        out.le32(directorySize)
        out.le32(directoryOffset)
        out.le16(0)
        return out
    }
}

extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func le32(_ value: UInt32) {
        le16(UInt16(value & 0xFFFF))
        le16(UInt16(value >> 16))
    }
}

/// A scratch file for an archive the tests write out, removed by the caller.
func temporaryArchive(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "rmdoc-\(label)-\(UUID().uuidString)")
}
