// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// One file of a document, named the way the device lays it out:
/// `<uuid>.<ext>` at the root, or `<uuid>/<file>` one folder down for
/// the pages.
///
/// The name is validated on construction, and unpacking builds its files
/// through this initialiser — so a hostile name inside a downloaded
/// archive (`../`, an absolute path, a third level) is refused before
/// anything could be written anywhere.
public struct RMDocFile: Sendable, Equatable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) throws {
        try NameRule.device(name)
        // The store method carries a 32-bit length; see `RMDocError`.
        guard data.count <= 0xFFFF_FFFF else {
            throw RMDocError.fileTooLarge(name: name)
        }
        self.name = name
        self.data = data
    }

    /// The document this file belongs to: the folder for a page file, the
    /// stem for a root file — `<uuid>.content` and `<uuid>/<page>.rm`
    /// answer the same identifier.
    public var documentID: String {
        if let slash = name.firstIndex(of: "/") {
            return String(name[..<slash])
        }
        if let dot = name.firstIndex(of: ".") {
            return String(name[..<dot])
        }
        return name
    }
}
