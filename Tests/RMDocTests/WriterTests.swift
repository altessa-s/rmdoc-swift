// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMDoc
import Testing

@Suite("The streaming writer")
struct WriterTests {
    @Test("The streaming writer and packed() spell the same bytes")
    func writerMatchesPacked() throws {
        let archive = try sampleArchive()
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out)
        for file in archive.files {
            try writer.add(name: file.name, data: file.data)
        }
        try writer.finish()
        #expect(try Data(contentsOf: out) == archive.packed())
    }

    @Test("A file source streams into the same bytes as its data would")
    func fileSourceMatchesDataSource() throws {
        // The sample plus an empty attachment: a zero-byte source never
        // enters the read loop, so its header is patched with zeros — the
        // one payload path the others cannot reach.
        let archive = try RMDocArchive(
            files: sampleArchive().files + [
                RMDocFile(name: "\(documentID).pdf", data: Data()),
            ]
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appending(path: "out.rmdoc")
        let writer = try RMDocWriter(to: out)
        for (index, file) in archive.files.enumerated() {
            let source = directory.appending(path: "source-\(index)")
            try file.data.write(to: source)
            try writer.add(name: file.name, contentsOf: source)
        }
        try writer.finish()
        // The patched headers must spell exactly what a direct write would
        // have: one format, two producers, no drift.
        #expect(try Data(contentsOf: out) == archive.packed())
    }

    @Test("The writer refuses a second entry under one name")
    func writerRefusesDuplicateNames() throws {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-dup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out)
        try writer.add(name: "\(documentID).content", data: Data())
        #expect(throws: RMDocError.duplicateName("\(documentID).content")) {
            try writer.add(name: "\(documentID).content", data: Data())
        }
    }

    @Test("A writer finished empty is refused")
    func writerRefusesEmptyFinish() throws {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out)
        #expect(throws: RMDocError.emptyArchive) {
            try writer.finish()
        }
    }

    @Test("The writer refuses a hostile name before touching the source")
    func writerRefusesHostileNames() throws {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-hostile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out)
        // The source does not exist: if the name check came second, this
        // would fail on the file instead of on the name.
        #expect(throws: RMDocError.invalidName("../evil")) {
            try writer.add(
                name: "../evil",
                contentsOf: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
            )
        }
    }

    @Test("A per-entry override stores one file inside a deflated archive")
    func perEntryCompressionIsHonoured() throws {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-mimetype-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out, compression: .deflate, layout: .package)
        // The EPUB spec's one rule about `mimetype`: stored, whatever the
        // rest of the container does.
        try writer.add(name: "mimetype", data: Data("application/epub+zip".utf8), compression: .store)
        try writer.add(name: "META-INF/container.xml", data: Data(repeating: 0x20, count: 4096))
        try writer.finish()
        // Offset 8 of the first local header is the method, little endian.
        let bytes = try Data(contentsOf: out)
        #expect(bytes[8] == 0 && bytes[9] == 0)
    }

    // Q1: `add(name:contentsOf:)` reads a megabyte at a time and carries a
    // running checksum across chunks. Every other test here uses files small
    // enough that the loop runs once, so nothing held the carry.

    @Test("A source larger than the read chunk streams to the same bytes as its data")
    func multiChunkSourceMatchesDataSource() throws {
        // Two and a bit chunks, and a length no multiple of eight, so the
        // checksum crosses chunk boundaries and still finishes on its tail.
        var payload = Data(count: (2 << 20) + 100_003)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for index in payload.indices {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            payload[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let archive = try RMDocArchive(files: [RMDocFile(name: "\(documentID).pdf", data: payload)])

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source")
        try payload.write(to: source)
        let out = directory.appending(path: "out.rmdoc")
        let writer = try RMDocWriter(to: out)
        try writer.add(name: "\(documentID).pdf", contentsOf: source)
        try writer.finish()

        // Byte parity with the in-memory producer is the strong form: the
        // patched checksum has to equal the one computed in a single pass.
        #expect(try Data(contentsOf: out) == archive.packed())
        #expect(try RMDocArchive(unpacking: out) == archive)
    }

    // Q2: misuse of the writer is a refusal the host can catch, not a trap
    // that takes the process with it.

    @Test("A finished writer refuses more entries and a second finish")
    func finishedWriterRefusesFurtherUse() throws {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-finished-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out)
        try writer.add(name: "\(documentID).content", data: Data("x".utf8))
        try writer.finish()
        #expect(throws: RMDocError.archiveFinished) {
            try writer.add(name: "\(documentID).metadata", data: Data())
        }
        #expect(throws: RMDocError.archiveFinished) {
            try writer.finish()
        }
        // And what it already wrote is still a whole archive.
        #expect(try RMDocArchive(unpacking: out).files.count == 1)
    }
}
