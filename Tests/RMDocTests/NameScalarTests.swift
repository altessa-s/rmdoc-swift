// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMDoc
import Testing

@Suite("Path syntax is independent of grapheme boundaries")
struct NameScalarTests {
    @Test(
        "Combining marks cannot hide a device path component or leading dot",
        arguments: [".\u{301}hidden", "doc/.\u{301}hidden", "a/\u{301}b/c", "a/\u{301}../b"]
    )
    func deviceNamesAreRefused(name: String) throws {
        #expect(throws: RMDocError.invalidName(name)) {
            _ = try RMDocFile(name: name, data: Data())
        }
        let output = temporaryArchive("scalar-device")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try RMDocWriter(to: output)
        #expect(throws: RMDocError.invalidName(name)) {
            try writer.add(name: name, data: Data())
        }
        // A ZIP received from elsewhere must pass the same rule, even if
        // the caller intends to skip every payload.
        let packed = ZipBuilder([.stored(name, Data())]).build()
        #expect(throws: RMDocError.invalidName(name)) {
            _ = try RMDocArchive.entries(in: packed)
        }
        #expect(throws: RMDocError.invalidName(name)) {
            try RMDocArchive.forEachFile(unpacking: packed, where: { _ in false }, { _ in
                Issue.record("A refused archive must not deliver a file")
            })
        }
    }

    @Test(
        "Combining marks cannot hide absolute paths, empty components or backslashes",
        arguments: ["/\u{301}root", "a/\u{301}/", "a//\u{301}b", "a\\\u{301}b"]
    )
    func bothLayoutsRefuseHiddenSyntax(name: String) throws {
        #expect(throws: RMDocError.invalidName(name)) {
            _ = try RMDocFile(name: name, data: Data())
        }
        let output = temporaryArchive("scalar-package")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try RMDocWriter(to: output, layout: .package)
        #expect(throws: RMDocError.invalidName(name)) {
            try writer.add(name: name, data: Data())
        }
        #expect(throws: RMDocError.invalidName(name)) {
            try writer.add(name: name, contentsOf: output.appending(path: "missing"))
        }
    }

    @Test(
        "Document IDs split at scalar separators while retaining Unicode spelling",
        arguments: [
            ("doc/\u{301}page.rm", "doc"),
            ("doc.\u{301}content", "doc"),
            ("doc.part/\u{301}page.rm", "doc.part"),
            ("e\u{301}.content", "e\u{301}"),
            ("e\u{301}/page.rm", "e\u{301}"),
        ]
    )
    func documentIDsUseScalarSeparators(name: String, expected: String) throws {
        let file = try RMDocFile(name: name, data: Data("ink".utf8))
        #expect(file.documentID == expected)
        let packed = try RMDocArchive(files: [file]).packed()
        let entry = try #require(RMDocArchive.entries(in: packed).first)
        #expect(entry.documentID == expected)
        let archive = try RMDocArchive(unpacking: packed)
        #expect(archive.documentIDs == [expected])
        #expect(Array(try #require(archive.files.first).name.utf8) == Array(name.utf8))
    }

    @Test("Package names still allow dotted components and combining marks")
    func packageNamesRetainTheirLayout() throws {
        let output = temporaryArchive("scalar-valid-package")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try RMDocWriter(to: output, layout: .package)
        for name in [".\u{301}hidden", "a/\u{301}b/c", "a/./file", "a/..\u{301}/file"] {
            try writer.add(name: name, data: Data())
        }
        try writer.finish()
    }
}
