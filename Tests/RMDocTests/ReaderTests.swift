// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMDoc
import Testing

@Suite("The reader: every way an archive can lie about itself")
struct ReaderTests {
    @Test("Bytes that are not a zip are named as such")
    func nonZipBytesAreRefused() {
        #expect(throws: RMDocError.notAnArchive) {
            _ = try RMDocArchive(unpacking: Data("not a zip at all".utf8))
        }
    }

    @Test("A truncated archive is refused rather than misread")
    func truncatedArchiveIsRefused() throws {
        let data = try sampleArchive().packed()
        // Named, not merely thrown. The end record is the reader's only
        // anchor into the file, and seven bytes off the tail take it with
        // them — so a truncated archive is indistinguishable from bytes that
        // were never a zip, and must refuse as one. `(any Error).self` would
        // pass on anything at all, an error raised before the reader was
        // reached included.
        #expect(throws: RMDocError.notAnArchive) {
            _ = try RMDocArchive(unpacking: data.dropLast(7))
        }
    }

    @Test("A flipped payload byte fails the checksum, and the failure names the file")
    func corruptedPayloadFailsChecksum() throws {
        var data = try sampleArchive().packed()
        let payload = Data("{\"formatVersion\":2}".utf8)
        let range = try #require(data.range(of: payload))
        data[range.lowerBound] ^= 0xFF
        #expect(throws: RMDocError.checksumMismatch(name: "\(documentID).content")) {
            _ = try RMDocArchive(unpacking: data)
        }
    }

    @Test("A hostile name inside the archive itself is refused on unpack")
    func hostileNameInsideArchiveIsRefused() {
        // A zip built by hand, because the packer refuses such a name
        // before it ever reaches the bytes: one stored entry named
        // "../evil" with an empty payload — the CRC of nothing is zero, so
        // the checksum gate passes and the name check is what must refuse.
        let name = Data("../evil".utf8)
        var zip = Data()
        func le16(_ value: UInt16) {
            zip.append(UInt8(value & 0xFF))
            zip.append(UInt8(value >> 8))
        }
        func le32(_ value: UInt32) {
            le16(UInt16(value & 0xFFFF))
            le16(UInt16(value >> 16))
        }
        le32(0x0403_4B50)                     // local file header
        le16(10); le16(0); le16(0)            // version, flags, method
        le16(0); le16(0x0021)                 // time, date
        le32(0); le32(0); le32(0)             // crc, sizes
        le16(UInt16(name.count)); le16(0)     // name, extra
        zip.append(name)
        let directoryOffset = UInt32(zip.count)
        le32(0x0201_4B50)                     // central directory
        le16(20); le16(10); le16(0); le16(0)  // made by, version, flags, method
        le16(0); le16(0x0021)                 // time, date
        le32(0); le32(0); le32(0)             // crc, sizes
        le16(UInt16(name.count))
        le16(0); le16(0); le16(0); le16(0)    // extra, comment, disk, internal
        le32(0)                               // external attributes
        le32(0)                               // local header offset
        zip.append(name)
        let directorySize = UInt32(zip.count) - directoryOffset
        le32(0x0605_4B50)                     // end of central directory
        le16(0); le16(0); le16(1); le16(1)    // disks, entry counts
        le32(directorySize); le32(directoryOffset)
        le16(0)                               // comment

        #expect(throws: RMDocError.invalidName("../evil")) {
            _ = try RMDocArchive(unpacking: zip)
        }
    }

    @Test("An entry compressed by a method we do not read is refused, with the method named")
    func unknownCompressionIsRefused() throws {
        var data = try sampleArchive().packed()
        // The method field of the first central directory entry sits ten
        // bytes past its signature. 12 is bzip2: a real zip method, and one
        // no measured export uses — so it is a sample to ask for, not a gap.
        let directory = try #require(data.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        data[directory.lowerBound + 10] = 12
        #expect(throws: RMDocError.unsupportedCompression(name: "\(documentID).content", method: 12)) {
            _ = try RMDocArchive(unpacking: data)
        }
    }

    // What the writer deflates, the reader must read: the desktop app
    // deflates, so a reader that took stored entries alone could not open a
    // real export — nor what this package itself writes.

    @Test("A deflated archive unpacks into the same files it was given")
    func deflatedArchiveRoundTrips() throws {
        let archive = try RMDocArchive(
            files: sampleArchive().files + [
                // Compressible enough that deflate certainly wins, so the
                // entry really does go out with method 8.
                RMDocFile(name: "\(documentID).pdf", data: Data(repeating: 0x41, count: 100_000)),
            ]
        )
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-deflate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out, compression: .deflate)
        for file in archive.files {
            try writer.add(name: file.name, data: file.data)
        }
        try writer.finish()

        let bytes = try Data(contentsOf: out)
        // Smaller than the payload it carries: proof the entry was deflated
        // rather than quietly stored, which would make the round trip pass
        // for the wrong reason.
        #expect(bytes.count < 100_000)
        #expect(try RMDocArchive(unpacking: bytes) == archive)
    }

    // A1: the reading half of what `RMDocWriter` is for.

    @Test("Files stream out of an archive one at a time, and the refusals still hold")
    func filesStreamOutOfAnArchive() throws {
        let archive = try sampleArchive()
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        try archive.packed().write(to: out)

        var streamed: [RMDocFile] = []
        try RMDocArchive.forEachFile(unpacking: out) { streamed.append($0) }
        #expect(streamed == archive.files)

        // The mapped initialiser answers the same archive as the bytes do.
        #expect(try RMDocArchive(unpacking: out) == archive)

        // A hostile name is refused on the way through, not collected.
        var reached = 0
        #expect(throws: RMDocError.invalidName("../evil")) {
            try RMDocArchive.forEachFile(unpacking: hostileArchiveOnDisk()) { _ in reached += 1 }
        }
        #expect(reached == 0)
    }

    @Test("A deflated entry cannot claim more than deflate could have produced")
    func deflateBombIsRefused() throws {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-bomb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out, compression: .deflate)
        try writer.add(name: "\(documentID).content", data: Data(repeating: 0x41, count: 100_000))
        try writer.finish()
        var bytes = try Data(contentsOf: out)
        // Rewrite the directory's uncompressed length to four gigabytes. The
        // reader must refuse on the claim rather than allocate against it.
        let directory = try #require(bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        for (index, byte) in [0xFF, 0xFF, 0xFF, 0xFF].enumerated() {
            bytes[directory.lowerBound + 24 + index] = UInt8(byte)
        }
        // The bound itself, named. `RMDocError.self` passes on any refusal
        // the reader makes — including one raised before the ratio was ever
        // consulted — so it cannot tell a working bound from a widened one,
        // which is the single thing this test exists to hold.
        #expect(
            throws: RMDocError.malformedArchive(
                "deflated entry claims more than deflate can produce: \(documentID).content"
            )
        ) {
            _ = try RMDocArchive(unpacking: bytes)
        }
    }

    @Test("An entry whose payload runs past the file is refused on the claim")
    func entryPayloadRunsPastTheFileIsRefused() throws {
        var data = try sampleArchive().packed()
        // The first directory entry's sizes: compressed at offset 20,
        // uncompressed at 24. Both are set to 65535 — equal, so the stored
        // entry's own agreement check passes and the bounds check is what
        // must refuse — and far past the end of an archive this small.
        let directory = try #require(data.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        for field in [20, 24] {
            data[directory.lowerBound + field] = 0xFF
            data[directory.lowerBound + field + 1] = 0xFF
            data[directory.lowerBound + field + 2] = 0
            data[directory.lowerBound + field + 3] = 0
        }
        #expect(
            throws: RMDocError.malformedArchive(
                "entry data runs past the file: \(documentID).content"
            )
        ) {
            _ = try RMDocArchive(unpacking: data)
        }
    }
}
