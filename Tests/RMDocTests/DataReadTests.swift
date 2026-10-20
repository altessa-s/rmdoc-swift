// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMDoc
import Testing

/// The sample document with two large repetitive payloads beside it, written
/// by the library's own streaming writer, deflated.
private func deflatedArchive() throws -> URL {
    let url = temporaryArchive("data-read")
    let writer = try RMDocWriter(to: url, compression: .deflate)
    for file in try sampleArchive().files {
        try writer.add(name: file.name, data: file.data)
    }
    try writer.add(name: "\(documentID).pdf", data: Data(repeating: 0x41, count: 200_000))
    try writer.add(name: "\(documentID).epub", data: Data(repeating: 0x42, count: 120_000))
    try writer.finish()
    return url
}

/// Every file a read hands over, in order.
private func collect(_ read: ((RMDocFile) throws -> Void) throws -> Void) throws -> [RMDocFile] {
    var out: [RMDocFile] = []
    try read { out.append($0) }
    return out
}

@Suite("Reading out of bytes the caller already holds")
struct DataReadTests {
    @Test("From Data or from a URL, the same files in the same order")
    func dataMatchesURL() throws {
        let deflated = try deflatedArchive()
        let stored = temporaryArchive("data-read-stored")
        defer {
            try? FileManager.default.removeItem(at: deflated)
            try? FileManager.default.removeItem(at: stored)
        }
        try sampleArchive().packed().write(to: stored)

        for url in [deflated, stored] {
            let data = try Data(contentsOf: url)
            let fromURL = try collect { try RMDocArchive.forEachFile(unpacking: url, $0) }
            #expect(try collect { try RMDocArchive.forEachFile(unpacking: data, $0) } == fromURL)
            #expect(try collect { try RMDocArchive.forEachFile(unpacking: data, limits: .format, $0) } == fromURL)
            #expect(try collect { try RMDocArchive.forEachFile(unpacking: data, where: { _ in true }, $0) } == fromURL)
            #expect(try RMDocArchive(unpacking: data).files == fromURL)

            // Choosing is the same choice either way.
            let chosen: (RMDocEntry) -> Bool = { !$0.name.hasSuffix(".pdf") }
            let chosenFromURL = try collect { try RMDocArchive.forEachFile(unpacking: url, where: chosen, $0) }
            #expect(try collect { try RMDocArchive.forEachFile(unpacking: data, where: chosen, $0) } == chosenFromURL)
            #expect(chosenFromURL.count == fromURL.count - (url == deflated ? 1 : 0))
        }
    }

    @Test("A slice of a larger buffer reads as the archive it holds")
    func sliceReadsLikeTheWhole() throws {
        let url = try deflatedArchive()
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Data(contentsOf: url)
        let padded = Data(repeating: 0xEE, count: 37) + archive + Data(repeating: 0xEE, count: 11)
        let slice = padded[37 ..< 37 + archive.count]
        #expect(slice.startIndex == 37)

        var read: [RMDocFile] = []
        try RMDocArchive.forEachFile(unpacking: slice) { read.append($0) }
        #expect(try read == RMDocArchive(unpacking: archive).files)
        #expect(try RMDocArchive.entries(in: slice) == RMDocArchive.entries(in: archive))
    }

    @Test("The refusals are the URL's, in the same order")
    func refusalsMatchURL() throws {
        let hostile = try hostileArchiveOnDisk()
        let deflated = try deflatedArchive()
        defer {
            try? FileManager.default.removeItem(at: hostile)
            try? FileManager.default.removeItem(at: deflated)
        }

        var reached = 0
        #expect(throws: RMDocError.invalidName("../evil")) {
            try RMDocArchive.forEachFile(unpacking: Data(contentsOf: hostile)) { _ in reached += 1 }
        }
        #expect(throws: RMDocError.invalidName("../evil")) {
            try RMDocArchive.forEachFile(unpacking: hostile) { _ in reached += 1 }
        }

        let limits = RMDocReadLimits(maximumEntrySize: 100_000)
        let error = RMDocReadError.entryTooLarge(name: "\(documentID).pdf", size: 200_000, limit: 100_000)
        #expect(throws: error) {
            try RMDocArchive.forEachFile(unpacking: Data(contentsOf: deflated), limits: limits) { _ in reached += 1 }
        }
        #expect(throws: error) {
            try RMDocArchive.forEachFile(unpacking: deflated, limits: limits) { _ in reached += 1 }
        }
        #expect(reached == 0)
    }

    @Test("A deflated payload is inflated out of the caller's own bytes, never a copy of them")
    func inflationReadsTheCallersBytes() throws {
        let url = try deflatedArchive()
        defer { try? FileManager.default.removeItem(at: url) }

        // In memory and mapped: the two kinds of Data a host hands over.
        for data in [try Data(contentsOf: url), try Data(contentsOf: url, options: .alwaysMapped)] {
            let archive = data.withUnsafeBytes { buffer in
                let start = UInt(bitPattern: buffer.baseAddress)
                return start ..< start + UInt(buffer.count)
            }
            var sources: [Range<UInt>] = []
            var handed = 0
            try ZipReader.forEachEntry(
                in: data,
                inflatingFrom: { payload in
                    let start = UInt(bitPattern: payload.baseAddress)
                    sources.append(start ..< start + UInt(payload.count))
                },
                { _ in handed += 1 }
            )
            let deflated = try RMDocArchive.entries(in: data).filter(\.isCompressed)
            #expect(handed == 6)
            #expect(deflated.count >= 2)
            #expect(sources.count == deflated.count)
            #expect(sources.map(\.count) == deflated.map(\.compressedSize))
            // Every byte the decoder read lay inside the caller's buffer.
            #expect(sources.allSatisfy { archive.contains($0.lowerBound) && $0.upperBound <= archive.upperBound })
        }
    }
}
