// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// One entry of a container as its central directory describes it, before
/// a byte of it is inflated.
///
/// What a caller chooses by. `RMDocArchive.entries(in:)` lists them, and
/// `RMDocArchive.forEachFile(unpacking:limits:where:_:)` asks about each one
/// before deciding whether to inflate it — so a document beside the one
/// wanted, a thumbnail, or an entry whose declared size is out of proportion
/// costs a look at the directory and nothing more.
///
/// The sizes are the archive's own claims. By the time an entry is listed
/// they have passed the structural checks — the payload lies inside the
/// file, the local header agrees with the directory, a deflated entry claims
/// no more than deflate can physically produce from the bytes it holds — but
/// `uncompressedSize` is still a promise that inflation keeps or refuses: an
/// entry that inflates to any other length, or to bytes that fail the
/// checksum, is refused when it is read.
public struct RMDocEntry: Sendable, Equatable, Hashable {
    /// The entry's name, already validated against the device layout — the
    /// same rule `RMDocFile` applies — so a listing never holds a name that
    /// could leave the directory it is unpacked into.
    public let name: String
    /// The zip compression method: 0 stored, 8 deflated. Any other method is
    /// refused while the directory is read, so these are the only two values.
    public let method: Int
    /// What the entry occupies in the archive.
    public let compressedSize: Int
    /// What the entry declares it will inflate to.
    public let uncompressedSize: Int
    /// The CRC-32 the directory carries for the entry's uncompressed bytes.
    public let crc32: UInt32

    /// The entry is deflated rather than stored.
    public var isCompressed: Bool { method == 8 }

    /// The document the entry belongs to — the folder for a page file, the
    /// stem for a root file, as `RMDocFile.documentID` answers it.
    public var documentID: String { NameRule.documentID(of: name) }
}
