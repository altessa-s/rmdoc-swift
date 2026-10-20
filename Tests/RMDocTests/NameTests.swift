// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMDoc
import Testing

@Suite("Names: what the two layouts accept and what they refuse")
struct NameTests {
    @Test("Root and page files answer the same document")
    func filesAgreeOnTheDocument() throws {
        let root = try RMDocFile(name: "\(documentID).content", data: Data())
        let page = try RMDocFile(name: "\(documentID)/\(pageID).rm", data: Data())
        #expect(root.documentID == documentID)
        #expect(page.documentID == documentID)
    }

    @Test(
        "Names that could leave the unpack directory are refused",
        arguments: ["../evil", "/etc/x", "a/b/c.rm", "", "a//b", ".hidden", "..", "a/../b", "a\\b"]
    )
    func hostileNamesAreRefused(name: String) {
        #expect(throws: RMDocError.invalidName(name)) {
            _ = try RMDocFile(name: name, data: Data())
        }
    }

    @Test("The package layout takes a nested name the device layout refuses")
    func packageLayoutTakesNestedNames() throws {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-package-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out, layout: .package)
        try writer.add(name: "OEBPS/text/chapter1.xhtml", data: Data("<p/>".utf8))
        try writer.finish()
        // The same name through the device layout is a third level and a
        // refusal — the two layouts are not the same rule.
        #expect(throws: RMDocError.invalidName("OEBPS/text/chapter1.xhtml")) {
            _ = try RMDocFile(name: "OEBPS/text/chapter1.xhtml", data: Data())
        }
    }

    @Test(
        "A name that escapes the unpack directory is refused whatever the layout",
        arguments: ["../evil", "/etc/x", "", "a//b", "a/../b", "a\\b", "a/\u{7F}b"]
    )
    func hostilePackageNamesAreRefused(name: String) throws {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-pkg-hostile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out, layout: .package)
        #expect(throws: RMDocError.invalidName(name)) {
            try writer.add(name: name, data: Data())
        }
    }

    @Test(
        "Control characters are refused, DEL and the C1 block included",
        arguments: ["doc\u{00}.content", "doc\u{1F}.content", "doc\u{7F}.content", "doc\u{85}.content"]
    )
    func controlCharactersAreRefused(name: String) {
        #expect(throws: RMDocError.invalidName(name)) {
            _ = try RMDocFile(name: name, data: Data())
        }
    }

    // S1: the name field is sixteen bits, and a longer name used to trap on
    // the conversion rather than be refused by the rule that refuses every
    // other thing a name may not be.

    @Test("A name at the sixteen-bit ceiling packs; one byte past it is refused")
    func nameLengthCeilingIsEnforced() throws {
        let atLimit = String(repeating: "a", count: 0xFFFF)
        let overLimit = String(repeating: "a", count: 0x1_0000)
        // The ceiling itself is a legal name and must still pack.
        let packed = try RMDocArchive(files: [RMDocFile(name: atLimit, data: Data("x".utf8))]).packed()
        #expect(try RMDocArchive(unpacking: packed).files.first?.name == atLimit)
        // A host that sets the name ceiling for untrusted input refuses it.
        #expect(throws: RMDocReadError.nameTooLong(length: 0xFFFF, limit: 1024)) {
            _ = try RMDocArchive(unpacking: packed, limits: RMDocReadLimits(maximumNameLength: 1024))
        }
        // One byte past it has no representation in the container.
        #expect(throws: RMDocError.invalidName(overLimit)) {
            _ = try RMDocFile(name: overLimit, data: Data())
        }
        // And the streaming writer refuses it by the same rule, rather than
        // trapping once the name reaches the header.
        let out = FileManager.default.temporaryDirectory
            .appending(path: "rmdoc-longname-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try RMDocWriter(to: out)
        #expect(throws: RMDocError.invalidName(overLimit)) {
            try writer.add(name: overLimit, data: Data())
        }
    }

    @Test(
        "Format characters are refused: a name must read as what it opens as",
        arguments: ["invoice\u{202E}gpj.exe", "doc\u{200F}.content", "doc\u{FEFF}.content"]
    )
    func formatCharactersAreRefused(name: String) {
        #expect(throws: RMDocError.invalidName(name)) {
            _ = try RMDocFile(name: name, data: Data())
        }
    }
}
