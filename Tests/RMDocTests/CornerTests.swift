// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMDoc
import Testing

private let contentName = "\(documentID).content"
private let pdfName = "\(documentID).pdf"

/// A valid deflate stream of `blocks` empty stored blocks and a final empty
/// fixed block: arbitrarily long, and it inflates to nothing at all.
private func emptyBlocks(_ blocks: Int) -> Data {
    var stream = Data(capacity: blocks * 5 + 2)
    for _ in 0 ..< blocks {
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0xFF, 0xFF])
    }
    stream.append(contentsOf: [0x03, 0x00])
    return stream
}

/// An entry declaring nothing and occupying `blocks * 5 + 2` bytes.
private func nothingDeclared(_ blocks: Int) -> ZipBuilder.Entry {
    let stream = emptyBlocks(blocks)
    return ZipBuilder.Entry(
        name: pdfName, payload: stream, method: 8, crc: 0,
        compressedSize: UInt32(stream.count), uncompressedSize: 0
    )
}

@Suite("The corners: what a careful reader must not mistake")
struct CornerTests {
    @Test("A large payload declaring nothing inflates in place, and the compressed budget bounds it")
    func compressedBudgetBoundsWhatDeclaresNothing() throws {
        // Eight megabytes of valid deflate that inflate to nothing: every
        // uncompressed limit passes it, even at zero.
        let entry = nothingDeclared(8 << 20 / 5)
        let zip = ZipBuilder([.stored(contentName, Data("{}".utf8)), entry]).build()

        // Unbounded, it is read in place — out of the archive's own bytes,
        // never copied — and is the empty file it says it is.
        let zeroSizes = RMDocReadLimits(maximumEntrySize: 2, maximumTotalSize: 2)
        let archive = try RMDocArchive(unpacking: zip, limits: zeroSizes)
        #expect(archive.files.last?.data.isEmpty == true)

        let size = Int(entry.compressedSize)
        #expect(throws: RMDocReadError.compressedEntryTooLarge(name: pdfName, size: size, limit: 1 << 20)) {
            _ = try RMDocArchive(unpacking: zip, limits: RMDocReadLimits(maximumCompressedEntrySize: 1 << 20))
        }
        #expect(throws: RMDocReadError.compressedTotalSizeExceeded(name: pdfName, limit: 1 << 20)) {
            _ = try RMDocArchive(unpacking: zip, limits: RMDocReadLimits(maximumCompressedTotalSize: 1 << 20))
        }
        // Passed over, it is not weighed.
        let url = temporaryArchive("nothing-declared")
        defer { try? FileManager.default.removeItem(at: url) }
        try zip.write(to: url)
        var read: [String] = []
        try RMDocArchive.forEachFile(
            unpacking: url,
            limits: RMDocReadLimits(maximumCompressedTotalSize: 1 << 20),
            where: { $0.name == contentName },
            { read.append($0.name) }
        )
        #expect(read == [contentName])
    }

    @Test("A record comment ending in the ZIP64 locator's signature is a comment, not ZIP64")
    func locatorSignatureInsideACommentIsNotZip64() throws {
        var entry = ZipBuilder.Entry.stored(contentName, Data("{}".utf8))
        // Twenty bytes, the locator's length, so the signature lands exactly
        // twenty bytes before the end record — inside the directory.
        entry.centralComment = Data([0x50, 0x4B, 0x06, 0x07]) + Data(count: 16)
        let archive = try RMDocArchive(unpacking: ZipBuilder([entry]).build())
        #expect(archive.files.map(\.name) == [contentName])
    }

    @Test("The descriptor flag must agree between the directory and the local header, both ways")
    func descriptorFlagMustAgree() {
        let entries: [ZipBuilder.Entry] = [
            .stored(contentName, Data("{\"formatVersion\":2}".utf8)),
            .deflated(contentName, Data(repeating: 0x41, count: 20_000)),
        ]
        for honest in entries {
            // The directory promises a descriptor the local header does not.
            var directoryOnly = honest
            directoryOnly.flags = 0x0008
            directoryOnly.localFlags = 0
            // The local header promises one the directory does not — and
            // there is one, agreeing with everything.
            var localOnly = honest
            localOnly.localFlags = 0x0008
            var descriptor = Data()
            descriptor.le32(0x0807_4B50)
            descriptor.le32(honest.crc)
            descriptor.le32(honest.compressedSize)
            descriptor.le32(honest.uncompressedSize)
            localOnly.trailer = descriptor
            for lie in [directoryOnly, localOnly] {
                #expect(throws: RMDocError.malformedArchive("local header disagrees with the directory: \(contentName)")) {
                    _ = try RMDocArchive.entries(in: ZipBuilder([lie]).build())
                }
            }
        }
    }

    @Test("The entry count is weighed over the whole archive, even when nothing is chosen")
    func entryCountIgnoresTheChooser() throws {
        let url = temporaryArchive("count")
        defer { try? FileManager.default.removeItem(at: url) }
        try sampleArchive().packed().write(to: url)

        var asked = 0
        #expect(throws: RMDocReadError.tooManyEntries(count: 4, limit: 3)) {
            try RMDocArchive.forEachFile(
                unpacking: url,
                limits: RMDocReadLimits(maximumEntryCount: 3),
                where: { _ in asked += 1; return false },
                { _ in }
            )
        }
        #expect(asked == 0)
    }

    @Test("A local extra block that runs past its field is refused, not skipped")
    func malformedLocalExtraIsRefused() {
        // A block claiming eight bytes with four behind it — and a ZIP64
        // block hidden in what it claims. Giving up on the first would
        // miss the second.
        var extra = Data()
        extra.le16(0x5455)
        extra.le16(8)
        extra.le16(0x0001)
        extra.le16(0)
        var entry = ZipBuilder.Entry.stored(contentName, Data("{}".utf8))
        entry.localExtra = extra
        #expect(throws: RMDocError.malformedArchive("extra field runs past its record")) {
            _ = try RMDocArchive.entries(in: ZipBuilder([entry]).build())
        }
    }
}
