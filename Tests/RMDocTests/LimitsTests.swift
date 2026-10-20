// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMDoc
import Testing

/// Three root files of a thousand bytes each, stored.
private func threeFiles() throws -> URL {
    let url = temporaryArchive("three")
    try RMDocArchive(files: [
        RMDocFile(name: "\(documentID).content", data: Data(repeating: 0x31, count: 1000)),
        RMDocFile(name: "\(documentID).metadata", data: Data(repeating: 0x32, count: 1000)),
        RMDocFile(name: "\(documentID).pagedata", data: Data(repeating: 0x33, count: 1000)),
    ]).packed().write(to: url)
    return url
}

@Suite("The caller's limits, weighed before anything is inflated")
struct LimitsTests {
    @Test("A real deflate bomb is refused on its ratio before it is inflated")
    func realDeflateBombIsRefused() throws {
        // Sixteen megabytes of one byte: deflate packs it at close to its
        // 1032:1 ceiling, so the claim is physically possible and only the
        // ratio limit stands between it and the allocation.
        let size = 16 << 20
        let url = temporaryArchive("bomb")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RMDocWriter(to: url, compression: .deflate)
        try writer.add(name: "\(documentID).content", data: Data("{}".utf8))
        try writer.add(name: "\(documentID).pdf", data: Data(count: size))
        try writer.finish()

        let bomb = try #require(try RMDocArchive.entries(in: url).first { $0.name == "\(documentID).pdf" })
        #expect(bomb.uncompressedSize == size)
        #expect(bomb.compressedSize * 200 < size)

        var inflated = 0
        var handed = 0
        let error = RMDocReadError.compressionRatioExceeded(
            name: "\(documentID).pdf", compressedSize: bomb.compressedSize, uncompressedSize: size, limit: 200
        )
        #expect(throws: error) {
            try ZipReader.forEachEntry(
                in: Data(contentsOf: url), didInflate: { _ in inflated += 1 }, { _ in handed += 1 }
            )
        }
        // Refused up front: not even the harmless entry before it was read.
        #expect(inflated == 0)
        #expect(handed == 0)
        #expect(throws: error) { _ = try RMDocArchive(unpacking: url) }

        // The format's own ceiling lets it through, and it inflates to the
        // byte — the bomb is honest about its size, merely absurd.
        let archive = try RMDocArchive(unpacking: url, limits: .format)
        #expect(archive.files.last?.data.count == size)
        // Passed over, it costs nothing and refuses nothing.
        var read: [String] = []
        try RMDocArchive.forEachFile(unpacking: url, where: { !$0.name.hasSuffix(".pdf") }, { read.append($0.name) })
        #expect(read == ["\(documentID).content"])
    }

    @Test("The ratio ceiling is the caller's, and small entries are exempt by default")
    func ratioCeilingIsConfigurable() throws {
        let data = Data(repeating: 0x41, count: 100_000)
        let zip = ZipBuilder([.deflated("\(documentID).content", data)]).build()
        let entry = try #require(try RMDocArchive.entries(in: zip).first)

        // A hundred kilobytes is under the default threshold: let be.
        #expect(try RMDocArchive(unpacking: zip).files.first?.data == data)

        let strict = RMDocReadLimits(maximumCompressionRatio: 10, compressionRatioThreshold: 0)
        #expect(throws: RMDocReadError.compressionRatioExceeded(
            name: entry.name, compressedSize: entry.compressedSize, uncompressedSize: data.count, limit: 10
        )) {
            _ = try RMDocArchive(unpacking: zip, limits: strict)
        }
    }

    @Test("An entry declaring more than the per-entry ceiling is refused, named, before any is read")
    func entryTooLargeIsRefused() throws {
        let url = try threeFiles()
        defer { try? FileManager.default.removeItem(at: url) }

        var handed = 0
        let limits = RMDocReadLimits(maximumEntrySize: 999)
        #expect(throws: RMDocReadError.entryTooLarge(name: "\(documentID).content", size: 1000, limit: 999)) {
            try RMDocArchive.forEachFile(unpacking: url, limits: limits) { _ in handed += 1 }
        }
        #expect(handed == 0)
        // Exactly at the ceiling is within it.
        #expect(try RMDocArchive(unpacking: url, limits: RMDocReadLimits(maximumEntrySize: 1000)).files.count == 3)
    }

    @Test("The pass's total is weighed over every chosen entry before the first is read")
    func totalBudgetIsWeighedUpFront() throws {
        let url = try threeFiles()
        defer { try? FileManager.default.removeItem(at: url) }

        var handed = 0
        let limits = RMDocReadLimits(maximumTotalSize: 2500)
        #expect(throws: RMDocReadError.totalSizeExceeded(name: "\(documentID).pagedata", limit: 2500)) {
            try RMDocArchive.forEachFile(unpacking: url, limits: limits) { _ in handed += 1 }
        }
        // The third entry crossed the line, and the first two were never
        // handed over: a refusal does not come after half a pass.
        #expect(handed == 0)

        // Leave one out and the rest fit: what is passed over is not weighed.
        var read: [String] = []
        try RMDocArchive.forEachFile(
            unpacking: url, limits: limits, where: { !$0.name.hasSuffix(".metadata") }, { read.append($0.name) }
        )
        #expect(read == ["\(documentID).content", "\(documentID).pagedata"])
    }

    @Test("More entries than the caller allows is refused before the directory is walked")
    func tooManyEntriesIsRefused() throws {
        let url = try threeFiles()
        defer { try? FileManager.default.removeItem(at: url) }

        let limits = RMDocReadLimits(maximumEntryCount: 2)
        #expect(throws: RMDocReadError.tooManyEntries(count: 3, limit: 2)) {
            _ = try RMDocArchive.entries(in: url, limits: limits)
        }
        #expect(throws: RMDocReadError.tooManyEntries(count: 3, limit: 2)) {
            try RMDocArchive.forEachFile(unpacking: url, limits: limits) { _ in }
        }
    }

    @Test("The listing weighs the directory's limits alone; the sizes are what it is for")
    func listingIgnoresSizeLimits() throws {
        let url = try threeFiles()
        defer { try? FileManager.default.removeItem(at: url) }

        let tight = RMDocReadLimits(maximumEntrySize: 1, maximumTotalSize: 1)
        #expect(try RMDocArchive.entries(in: url, limits: tight).count == 3)
    }

    @Test("Inflation stops at the promise: a stream with more to say is refused, not finished")
    func inflationNeverRunsPastTheDeclaredLength() {
        // Sixteen megabytes squeezed to a few kilobytes, declared as a
        // hundred bytes: the decoder is handed room for a hundred and one,
        // and the one is what refuses it.
        let squeezed = Deflate.compress(Data(count: 16 << 20))
        #expect(Deflate.decompress(squeezed, count: 100) == nil)
        #expect(Deflate.decompress(squeezed, count: (16 << 20) - 1) == nil)
        #expect(Deflate.decompress(squeezed, count: 16 << 20) == Data(count: 16 << 20))
    }

    @Test("The defaults are the format's ceilings on size, 200:1 past a megabyte")
    func defaultsAreDocumented() {
        let limits = RMDocReadLimits.default
        #expect(limits.maximumEntryCount == 0xFFFF)
        #expect(limits.maximumEntrySize == 0xFFFF_FFFF)
        #expect(limits.maximumTotalSize == .max)
        #expect(limits.maximumCompressedEntrySize == 0xFFFF_FFFF)
        #expect(limits.maximumCompressedTotalSize == .max)
        #expect(limits.maximumCompressionRatio == 200)
        #expect(limits.compressionRatioThreshold == 1 << 20)
        #expect(limits.maximumDirectorySize == .max)
        #expect(limits.maximumNameLength == 0xFFFF)
        #expect(RMDocReadLimits.format.maximumCompressionRatio == Deflate.maximumRatio)
        #expect(RMDocReadLimits.format.compressionRatioThreshold == 0)
    }
}
