// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// A document container as the tablet exports and imports it: a plain zip
/// of the document's files in the device layout.
///
/// This is not sync v3 and shares nothing with it. There is no `docSchema`
/// inside — the zip's own table of contents is the list of files — and no
/// hashes: content addressing exists only in the cloud. What the files
/// *mean* is the caller's business; this type keeps the container honest —
/// safe names, no duplicates, checksums that match — and the bytes
/// untouched.
public struct RMDocArchive: Sendable, Equatable {
    /// In the order given, and packed in that order: packing is
    /// deterministic, so one document packs into one sequence of bytes.
    public let files: [RMDocFile]

    /// Export begins here: gather the document's files and pack.
    public init(files: [RMDocFile]) throws {
        guard !files.isEmpty else { throw RMDocError.emptyArchive }
        var seen: Set<String> = []
        for file in files where !seen.insert(file.name).inserted {
            throw RMDocError.duplicateName(file.name)
        }
        self.files = files
    }

    /// Import: read a container somebody handed us. Every name passes the
    /// same validation as a file built by hand, so a hostile archive cannot
    /// name its way out of the directory it will be unpacked into.
    public init(unpacking data: Data) throws {
        let entries = try ZipReader.unpack(data)
        try self.init(files: entries.map { try RMDocFile(name: $0.name, data: $0.data) })
    }

    /// Import from a file rather than from bytes already in memory. The
    /// archive is mapped, not read, so its own bytes cost pages the kernel
    /// can drop rather than heap the process must hold — what remains on
    /// the heap is the files themselves.
    public init(unpacking url: URL) throws {
        try self.init(unpacking: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Every file in turn, and never the archive whole.
    ///
    /// `RMDocWriter` exists because `packed()` is twice the document for a
    /// book with ink; reading had the same cost and no answer to it, since
    /// `init(unpacking:)` holds the container and every payload out of it
    /// at once. This is the reading half: the container is mapped, each
    /// file is verified and handed over, and a caller that writes it
    /// straight to disk holds one at a time.
    ///
    /// The refusals are the initialiser's, in the same order: a hostile
    /// name, a name used twice, an archive with nothing in it.
    public static func forEachFile(unpacking url: URL, _ body: (RMDocFile) throws -> Void) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var seen: Set<String> = []
        try ZipReader.forEachEntry(in: data) { entry in
            let file = try RMDocFile(name: entry.name, data: entry.data)
            guard seen.insert(file.name).inserted else {
                throw RMDocError.duplicateName(file.name)
            }
            try body(file)
        }
        guard !seen.isEmpty else { throw RMDocError.emptyArchive }
    }

    /// The container as bytes, ready to be written as `<name>.rmdoc`.
    public func packed() throws -> Data {
        guard files.count <= 0xFFFF else { throw RMDocError.archiveTooLarge }
        // A conservative ceiling: payloads, both headers per file, the end
        // record. The store method has 32-bit offsets and no zip64 follows
        // it here — see `RMDocError.archiveTooLarge`.
        let total = files.reduce(22) { sum, file in
            sum + file.data.count + 2 * (46 + file.name.utf8.count)
        }
        guard total <= 0xFFFF_FFFF else { throw RMDocError.archiveTooLarge }
        return ZipWriter.pack(files.map { ZipEntry(name: $0.name, data: $0.data) })
    }

    /// The documents inside, in order of first appearance. One archive is
    /// usually one document; a folder sent whole arrives as several.
    public var documentIDs: [String] {
        var seen: Set<String> = []
        return files.compactMap { file in
            let id = file.documentID
            return seen.insert(id).inserted ? id : nil
        }
    }
}
