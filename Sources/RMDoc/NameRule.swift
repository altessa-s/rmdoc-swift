// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// What a name inside the container may be.
///
/// Two layouts ask for different things and share the part neither gives
/// up, so both live here rather than one on the file and one on the
/// writer: the guard that matters is the shared one, and two copies of it
/// on two types is how they drift apart.
enum NameRule {
    /// The device layout: `<uuid>.<ext>` at the root, or `<uuid>/<file>`
    /// one folder down for the pages. No third level, and no component
    /// that begins with a dot.
    static func device(_ name: String) throws {
        try validate(name) { components in
            (1 ... 2).contains(components.count)
                && components.allSatisfy { !$0.hasPrefix(".") }
        }
    }

    /// A package's layout — an EPUB, a Word file — is any zip, nested and
    /// dotted as its own specification lays it out. The one guard left is
    /// the zip-slip one: no component may be a parent reference.
    static func package(_ name: String) throws {
        try validate(name) { components in
            components.allSatisfy { $0 != ".." }
        }
    }

    /// The document a name belongs to: the folder for a page file, the stem
    /// for a root file. One spelling for `RMDocFile` and `RMDocEntry` both,
    /// so a file and the directory entry it came from answer alike.
    static func documentID(of name: String) -> String {
        if let slash = name.firstIndex(of: "/") {
            return String(name[..<slash])
        }
        if let dot = name.firstIndex(of: ".") {
            return String(name[..<dot])
        }
        return name
    }

    /// The longest name a zip can spell. The field that carries it is
    /// sixteen bits wide, in the local header and in the central directory
    /// both, so a longer name has no representation in the container — and
    /// the place to say so is here, where every other thing a name may not
    /// be is already said. Refused rather than truncated, and refused
    /// rather than left to trap on the conversion in `ZipWriter`.
    static let maximumLength = 0xFFFF

    /// What both layouts refuse: a name too long for the field that carries
    /// it, an empty component — which is also an absolute path and a
    /// trailing slash — a backslash, a control character, and a format
    /// character. A name off the wire must not be able to leave the
    /// directory it is unpacked into, nor to spell something a filesystem
    /// or a terminal reads as more than a name.
    private static func validate(_ name: String, _ layout: ([Substring]) -> Bool) throws {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard name.utf8.count <= maximumLength,
              components.allSatisfy({ !$0.isEmpty }),
              !name.contains("\\"),
              name.unicodeScalars.allSatisfy(isSafe),
              layout(components)
        else {
            throw RMDocError.invalidName(name)
        }
    }

    /// C0 below the space, DEL, and the C1 block above it — `>= 0x20` alone
    /// would let `\u{7F}` and `\u{85}` through, and both are control
    /// characters however little they look like one.
    ///
    /// And the format characters with them, the bidirectional overrides
    /// above all: `\u{202E}` turns `invoice<RLO>gpj.exe` into something a
    /// person reads as `invoice.jpg` and a filesystem opens as an
    /// executable. These names arrive off the wire and are written to a
    /// disk somebody then looks at, which is the whole of the argument.
    private static func isSafe(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value >= 0x20, !(0x7F ... 0x9F).contains(scalar.value) else { return false }
        return scalar.properties.generalCategory != .format
    }
}
