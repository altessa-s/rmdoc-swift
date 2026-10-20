// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMDoc
import Testing

private let content = Data("{\"formatVersion\":2}".utf8)
private let contentName = "\(documentID).content"
private let pdfName = "\(documentID).pdf"

/// One honest stored entry and one honest deflated one.
private func honest() -> [ZipBuilder.Entry] {
    [.stored(contentName, content), .deflated(pdfName, Data(repeating: 0x41, count: 20_000))]
}

@Suite("The directory: every claim checked against the file and against itself")
struct StructureTests {
    @Test("The builder's honest archive reads, so every refusal below is the one lie it tells")
    func honestArchiveReads() throws {
        let archive = try RMDocArchive(unpacking: ZipBuilder(honest()).build())
        #expect(archive.files.map(\.name) == [contentName, pdfName])
    }

    @Test("Every truncation of an archive is refused, never misread or trapped on")
    func everyTruncationIsRefused() throws {
        let zip = ZipBuilder(honest()).build()
        for length in 0 ..< zip.count {
            #expect(throws: (any Error).self, "\(length) bytes") {
                _ = try RMDocArchive(unpacking: zip.prefix(length))
            }
        }
    }

    @Test("Every single flipped byte is refused or read exactly — never a trap")
    func everyFlippedByteIsSafe() throws {
        let zip = ZipBuilder(honest()).build()
        let original = try RMDocArchive(unpacking: zip)
        for index in 0 ..< zip.count {
            var corrupt = zip
            corrupt[index] ^= 0x5A
            // A byte nothing reads — a timestamp, an attribute — may change
            // and leave the archive what it was; anything else must refuse.
            if let archive = try? RMDocArchive(unpacking: corrupt) {
                #expect(archive == original, "byte \(index)")
            }
        }
    }

    @Test("A checksum mismatch is refused, stored or deflated, and names the file")
    func checksumMismatchIsRefused() {
        for index in 0 ..< 2 {
            var entries = honest()
            entries[index].crc ^= 1
            #expect(throws: RMDocError.checksumMismatch(name: entries[index].name)) {
                _ = try RMDocArchive(unpacking: ZipBuilder(entries).build())
            }
        }
    }

    @Test("Two entries under one name are refused while listing, chosen or not")
    func duplicateNamesAreRefused() throws {
        let zip = ZipBuilder([.stored(contentName, content), .stored(contentName, content)]).build()
        #expect(throws: RMDocError.duplicateName(contentName)) {
            _ = try RMDocArchive.entries(in: zip)
        }
        let url = temporaryArchive("duplicate")
        defer { try? FileManager.default.removeItem(at: url) }
        try zip.write(to: url)
        #expect(throws: RMDocError.duplicateName(contentName)) {
            try RMDocArchive.forEachFile(unpacking: url, where: { _ in false }, { _ in })
        }
    }

    @Test(
        "A name that could leave the unpack directory is refused while listing",
        arguments: ["../evil", "/etc/passwd", "a/../b", "a\\b", "\(documentID)/../../x", "a/b/c.rm", "dir/"]
    )
    func traversalNamesAreRefused(name: String) {
        #expect(throws: RMDocError.invalidName(name)) {
            _ = try RMDocArchive.entries(in: ZipBuilder([.stored(name, Data())]).build())
        }
    }

    @Test("A local header naming another file is refused")
    func localNameMismatchIsRefused() {
        var entries = honest()
        entries[0].localName = "\(documentID).metadata"
        #expect(throws: RMDocError.malformedArchive("local header names another file: \(contentName)")) {
            _ = try RMDocArchive.entries(in: ZipBuilder(entries).build())
        }
    }

    @Test("A local header disagreeing on method, checksum or sizes is refused")
    func localFieldMismatchIsRefused() {
        let lies: [(inout ZipBuilder.Entry) -> Void] = [
            { $0.localMethod = 0 },
            { $0.localCRC = $0.crc ^ 1 },
            { $0.localCompressedSize = $0.compressedSize - 1 },
            { $0.localUncompressedSize = $0.uncompressedSize + 1 },
        ]
        for lie in lies {
            var entries = honest()
            lie(&entries[1])
            #expect(throws: RMDocError.malformedArchive("local header disagrees with the directory: \(pdfName)")) {
                _ = try RMDocArchive.entries(in: ZipBuilder(entries).build())
            }
        }
    }

    @Test("A data descriptor is read when it agrees with the directory, with or without its signature")
    func dataDescriptorsAreChecked() throws {
        for signed in [true, false] {
            var entries = honest()
            var entry = entries[1]
            entry.flags = 0x0008
            entry.localCRC = 0
            entry.localCompressedSize = 0
            entry.localUncompressedSize = 0
            var trailer = Data()
            if signed { trailer.le32(0x0807_4B50) }
            trailer.le32(entry.crc)
            trailer.le32(entry.compressedSize)
            trailer.le32(entry.uncompressedSize)
            entry.trailer = trailer
            entries[1] = entry
            let archive = try RMDocArchive(unpacking: ZipBuilder(entries).build())
            #expect(archive.files.last?.data == Data(repeating: 0x41, count: 20_000))

            // The descriptor lies about the size: refused.
            entry.trailer = trailer.dropLast(4) + Data([0, 0, 0, 0])
            entries[1] = entry
            #expect(throws: RMDocError.malformedArchive("data descriptor disagrees with the directory: \(pdfName)")) {
                _ = try RMDocArchive.entries(in: ZipBuilder(entries).build())
            }
        }
    }

    @Test("ZIP64 is refused by name, from the end-record locator or an extra field")
    func zip64IsRefused() {
        var builder = ZipBuilder(honest())
        builder.zip64Locator = true
        #expect(throws: RMDocReadError.zip64Unsupported) {
            _ = try RMDocArchive.entries(in: builder.build())
        }

        var zip64Field = Data()
        zip64Field.le16(0x0001)
        zip64Field.le16(8)
        zip64Field.append(Data(count: 8))
        var central = honest()
        central[0].centralExtra = zip64Field
        #expect(throws: RMDocReadError.zip64Unsupported) {
            _ = try RMDocArchive.entries(in: ZipBuilder(central).build())
        }
        var local = honest()
        local[0].localExtra = zip64Field
        #expect(throws: RMDocReadError.zip64Unsupported) {
            _ = try RMDocArchive.entries(in: ZipBuilder(local).build())
        }
    }

    @Test("A non-ZIP64 extra field is read past, and padding after a local one is tolerated")
    func ordinaryExtraFieldsAreAccepted() throws {
        var timestamp = Data()
        timestamp.le16(0x5455)
        timestamp.le16(5)
        timestamp.append(Data([1, 0, 0, 0, 0]))
        var entries = honest()
        entries[0].centralExtra = timestamp
        entries[0].localExtra = timestamp + Data([0, 0])
        #expect(try RMDocArchive(unpacking: ZipBuilder(entries).build()).files.count == 2)

        // In the directory, the same padding is a field that does not fit.
        entries[0].centralExtra = timestamp + Data([0, 0])
        #expect(throws: RMDocError.malformedArchive("extra field runs past its record")) {
            _ = try RMDocArchive.entries(in: ZipBuilder(entries).build())
        }
    }

    @Test("An encrypted entry is refused by name")
    func encryptedEntryIsRefused() {
        var entries = honest()
        entries[0].flags = 0x0001
        #expect(throws: RMDocReadError.encryptedEntry(name: contentName)) {
            _ = try RMDocArchive.entries(in: ZipBuilder(entries).build())
        }
    }

    @Test("An archive spanning disks is refused, whichever field says so")
    func spannedArchiveIsRefused() {
        var thisDisk = ZipBuilder(honest())
        thisDisk.thisDisk = 1
        var directoryDisk = ZipBuilder(honest())
        directoryDisk.directoryDisk = 1
        var onDisk = ZipBuilder(honest())
        onDisk.entriesOnDisk = 1
        var entries = honest()
        entries[1].startDisk = 1
        for zip in [thisDisk.build(), directoryDisk.build(), onDisk.build(), ZipBuilder(entries).build()] {
            #expect(throws: RMDocReadError.spannedArchive) {
                _ = try RMDocArchive.entries(in: zip)
            }
        }
    }

    @Test("Entries sharing bytes are refused: the overlapping-entry bomb")
    func overlappingEntriesAreRefused() {
        // The second entry's local header and payload live inside the first
        // entry's stored payload, so both records are honest on their own
        // and only their overlap is the lie.
        let inner = ZipBuilder.Entry.stored(pdfName, Data(repeating: 0x41, count: 100))
        var outer = ZipBuilder.Entry.stored(contentName, inner.localHeader + inner.payload)
        outer.localOffset = 0
        var hidden = inner
        hidden.writeLocal = false
        hidden.localOffset = UInt32(outer.localHeader.count)
        #expect(throws: RMDocError.malformedArchive("entries overlap: \(pdfName)")) {
            _ = try RMDocArchive.entries(in: ZipBuilder([outer, hidden]).build())
        }
    }

    @Test("A directory holding more records than the end record counts is refused")
    func uncountedRecordsAreRefused() {
        var builder = ZipBuilder(honest())
        builder.entryCount = 1
        builder.entriesOnDisk = 1
        #expect(throws: RMDocError.malformedArchive("central directory holds more than the end record counts")) {
            _ = try RMDocArchive.entries(in: builder.build())
        }
    }

    @Test("A record whose extra field runs past the directory is refused")
    func recordPastTheDirectoryIsRefused() {
        var entries = honest()
        entries[1].centralExtra = Data(count: 4)
        var zip = ZipBuilder(entries).build()
        // Grow the last record's declared extra length past the directory.
        let record = zip.lastRange(of: Data([0x50, 0x4B, 0x01, 0x02]))?.lowerBound ?? 0
        zip[record + 30] = 0xFF
        #expect(throws: RMDocError.malformedArchive("directory entry runs past the directory")) {
            _ = try RMDocArchive.entries(in: zip)
        }
    }

    @Test("A payload reaching into the central directory is refused")
    func payloadIntoTheDirectoryIsRefused() {
        var entries = honest()
        entries[0].compressedSize += 10
        entries[0].uncompressedSize += 10
        entries[1] = .stored("\(documentID).metadata", Data())
        entries = [entries[1], entries[0]]
        #expect(throws: RMDocError.malformedArchive("entry data runs into the central directory: \(contentName)")) {
            _ = try RMDocArchive.entries(in: ZipBuilder(entries).build())
        }
    }

    @Test("A local header offset past the file is refused")
    func localHeaderPastTheFileIsRefused() {
        var entries = honest()
        entries[1].localOffset = 0xFFFF_FFF0
        #expect(throws: RMDocError.malformedArchive("local header missing: \(pdfName)")) {
            _ = try RMDocArchive.entries(in: ZipBuilder(entries).build())
        }
    }

    @Test("An archive with no entries is empty, listed or read")
    func emptyArchiveIsRefused() {
        let zip = ZipBuilder([]).build()
        #expect(throws: RMDocError.emptyArchive) { _ = try RMDocArchive.entries(in: zip) }
        #expect(throws: RMDocError.emptyArchive) { _ = try RMDocArchive(unpacking: zip) }
    }

    @Test("What the library writes, it lists and reads back — stored and deflated")
    func writerRoundTripsThroughTheListing() throws {
        for compression in [RMDocWriter.Compression.store, .deflate] {
            let url = temporaryArchive("round-trip")
            defer { try? FileManager.default.removeItem(at: url) }
            let files = try sampleArchive().files + [
                RMDocFile(name: pdfName, data: Data((0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 * 7) })),
            ]
            let writer = try RMDocWriter(to: url, compression: compression)
            for file in files {
                try writer.add(name: file.name, data: file.data)
            }
            try writer.finish()

            let listed = try RMDocArchive.entries(in: url)
            #expect(listed.map(\.name) == files.map(\.name))
            #expect(listed.map(\.uncompressedSize) == files.map(\.data.count))
            var read: [RMDocFile] = []
            try RMDocArchive.forEachFile(unpacking: url, where: { _ in true }, { read.append($0) })
            #expect(read == files)
        }
    }
}
