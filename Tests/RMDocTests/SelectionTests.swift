// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMDoc
import Testing

/// A second document beside the sample, as a folder exported whole has it.
private let otherID = "6c9a4bd0-0000-4000-8000-000000000009"

/// The sample document and a second one, written by the library's own
/// streaming writer, deflated.
private func twoDocumentArchive() throws -> (url: URL, files: [RMDocFile]) {
    let files = try sampleArchive().files + [
        RMDocFile(name: "\(documentID).pdf", data: Data(repeating: 0x41, count: 50_000)),
        RMDocFile(name: "\(otherID).content", data: Data("{\"formatVersion\":2}".utf8)),
        RMDocFile(name: "\(otherID).pdf", data: Data(repeating: 0x42, count: 80_000)),
    ]
    let url = temporaryArchive("two-documents")
    let writer = try RMDocWriter(to: url, compression: .deflate)
    for file in files {
        try writer.add(name: file.name, data: file.data)
    }
    try writer.finish()
    return (url, files)
}

@Suite("Choosing entries before anything is inflated")
struct SelectionTests {
    @Test("The listing is the directory: names, methods, sizes and checksums, as written")
    func listingMatchesWhatWasWritten() throws {
        let (url, files) = try twoDocumentArchive()
        defer { try? FileManager.default.removeItem(at: url) }

        let listed = try RMDocArchive.entries(in: url)
        #expect(listed.map(\.name) == files.map(\.name))
        #expect(listed.map(\.uncompressedSize) == files.map(\.data.count))
        #expect(listed.map(\.crc32) == files.map { CRC32.checksum($0.data) })
        #expect(listed.map(\.documentID) == files.map(\.documentID))
        // The big repetitive payloads went in deflated; the method says so,
        // and so does the size they occupy.
        let pdf = try #require(listed.first { $0.name == "\(otherID).pdf" })
        #expect(pdf.isCompressed)
        #expect(pdf.method == 8)
        #expect(pdf.compressedSize < pdf.uncompressedSize)
        // From a file or from bytes, the same answer.
        #expect(try RMDocArchive.entries(in: Data(contentsOf: url)) == listed)
    }

    @Test("Listing never inflates: an entry that would not inflate still lists")
    func listingInflatesNothing() throws {
        var broken = ZipBuilder.Entry.deflated("\(documentID).pdf", Data(repeating: 0x41, count: 10_000))
        // Garbage of the declared compressed length: every header agrees,
        // only inflating it could tell.
        broken.payload = Data(repeating: 0xFF, count: broken.payload.count)
        let zip = ZipBuilder([.stored("\(documentID).content", Data("{}".utf8)), broken]).build()

        let listed = try RMDocArchive.entries(in: zip)
        #expect(listed.map(\.name) == ["\(documentID).content", "\(documentID).pdf"])
        #expect(throws: RMDocError.malformedArchive("deflated entry does not inflate: \(documentID).pdf")) {
            _ = try RMDocArchive(unpacking: zip)
        }
    }

    @Test("Only the chosen files are handed over, in directory order")
    func onlyChosenFilesAreHandedOver() throws {
        let (url, files) = try twoDocumentArchive()
        defer { try? FileManager.default.removeItem(at: url) }

        var read: [RMDocFile] = []
        try RMDocArchive.forEachFile(unpacking: url, where: { $0.documentID == otherID }, { read.append($0) })
        #expect(read == files.filter { $0.documentID == otherID })
    }

    @Test("A skipped entry is never inflated — counted, not inferred")
    func skippedEntriesAreNeverInflated() throws {
        let (url, _) = try twoDocumentArchive()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)

        var inflated: [String] = []
        var handed: [String] = []
        try ZipReader.forEachEntry(
            in: data,
            where: { $0.name == "\(documentID).pdf" },
            didInflate: { inflated.append($0.name) },
            { handed.append($0.name) }
        )
        #expect(handed == ["\(documentID).pdf"])
        #expect(inflated == ["\(documentID).pdf"])

        // And reading everything inflates every deflated entry exactly once.
        inflated = []
        try ZipReader.forEachEntry(in: data, didInflate: { inflated.append($0.name) }, { _ in })
        let deflated = try RMDocArchive.entries(in: data).filter(\.isCompressed).map(\.name)
        #expect(inflated == deflated)
        #expect(deflated.count >= 2)
    }

    @Test("A skipped entry that would not inflate does not stop the read")
    func brokenSkippedEntryDoesNotStopTheRead() throws {
        var broken = ZipBuilder.Entry.deflated("\(otherID).pdf", Data(repeating: 0x41, count: 10_000))
        broken.payload = Data(repeating: 0xFF, count: broken.payload.count)
        let content = Data("{\"formatVersion\":2}".utf8)
        let url = temporaryArchive("skip-broken")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZipBuilder([.stored("\(documentID).content", content), broken]).build().write(to: url)

        var read: [RMDocFile] = []
        try RMDocArchive.forEachFile(unpacking: url, where: { !$0.name.hasSuffix(".pdf") }, { read.append($0) })
        #expect(read == [try RMDocFile(name: "\(documentID).content", data: content)])
    }

    @Test("Every entry is asked about before the first file is handed over")
    func everyEntryIsChosenBeforeAnyIsRead() throws {
        let (url, files) = try twoDocumentArchive()
        defer { try? FileManager.default.removeItem(at: url) }

        var events: [String] = []
        try RMDocArchive.forEachFile(unpacking: url, where: { entry in
            events.append("ask \(entry.name)")
            return true
        }, { file in
            events.append("read \(file.name)")
        })
        #expect(events == files.map { "ask \($0.name)" } + files.map { "read \($0.name)" })
    }

    @Test("Choosing nothing reads nothing, and is not a refusal")
    func choosingNothingIsNotARefusal() throws {
        let (url, _) = try twoDocumentArchive()
        defer { try? FileManager.default.removeItem(at: url) }

        var reached = 0
        try RMDocArchive.forEachFile(unpacking: url, where: { _ in false }, { _ in reached += 1 })
        #expect(reached == 0)
    }

    @Test("A refusal from the chooser stops the read before anything is inflated")
    func chooserRefusalPropagates() throws {
        struct Declined: Error {}
        let (url, _) = try twoDocumentArchive()
        defer { try? FileManager.default.removeItem(at: url) }

        var reached = 0
        #expect(throws: Declined.self) {
            try RMDocArchive.forEachFile(unpacking: url, where: { _ in throw Declined() }, { _ in reached += 1 })
        }
        #expect(reached == 0)
    }
}
