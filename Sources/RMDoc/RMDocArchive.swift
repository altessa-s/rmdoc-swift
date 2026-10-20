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
    ///
    /// Under `RMDocReadLimits.default`; `init(unpacking:limits:)` takes the
    /// host's own.
    public init(unpacking data: Data) throws {
        try self.init(unpacking: data, limits: .default)
    }

    /// Import under the caller's limits, weighed over every entry before
    /// the first is inflated.
    public init(unpacking data: Data, limits: RMDocReadLimits) throws {
        let entries = try ZipReader.unpack(data, limits: limits)
        try self.init(files: entries.map { try RMDocFile(name: $0.name, data: $0.data) })
    }

    /// Import from a file rather than from bytes already in memory. The
    /// archive is mapped, not read, so its own bytes cost pages the kernel
    /// can drop rather than heap the process must hold — what remains on
    /// the heap is the files themselves.
    public init(unpacking url: URL) throws {
        try self.init(unpacking: url, limits: .default)
    }

    /// Import from a file under the caller's limits.
    public init(unpacking url: URL, limits: RMDocReadLimits) throws {
        try self.init(unpacking: Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
    }

    /// The container's table of contents, read from its central directory
    /// and nothing else: no entry is inflated, so listing a container costs
    /// the size of its directory whatever its entries declare.
    ///
    /// Every structural refusal a read makes is made here too — a hostile
    /// name, a name used twice, a payload outside the file, a local header
    /// that disagrees with the directory, entries that share bytes, a claim
    /// deflate could not keep — so what is listed is what a read would
    /// attempt. Of `limits`, only `maximumEntryCount` applies: the sizes are
    /// what a caller lists in order to weigh them, and are weighed when the
    /// entries are read.
    public static func entries(in data: Data, limits: RMDocReadLimits = .default) throws -> [RMDocEntry] {
        try ZipReader.directory(of: data, limits: limits).map(\.entry)
    }

    /// The table of contents of the container at `url`, which is mapped
    /// rather than read: the pages behind the entries are never touched.
    public static func entries(in url: URL, limits: RMDocReadLimits = .default) throws -> [RMDocEntry] {
        try entries(in: Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
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
    /// name, a name used twice, an archive with nothing in it. Under
    /// `RMDocReadLimits.default`.
    public static func forEachFile(unpacking url: URL, _ body: (RMDocFile) throws -> Void) throws {
        try forEachFile(unpacking: url, limits: .default, where: { _ in true }, body)
    }

    /// Every file in turn, under the caller's limits.
    public static func forEachFile(
        unpacking url: URL,
        limits: RMDocReadLimits,
        _ body: (RMDocFile) throws -> Void
    ) throws {
        try forEachFile(unpacking: url, limits: limits, where: { _ in true }, body)
    }

    /// The files a caller chooses, each chosen before anything is inflated.
    ///
    /// `include` is asked about every entry, in the order the directory
    /// lists them, with what the directory says about it — name, method,
    /// sizes, checksum — and before a byte of any entry is inflated. What it
    /// declines is never inflated, never checksummed and never weighed
    /// against the size limits; what it accepts is weighed all together, and
    /// only then read, one file at a time, in directory order.
    ///
    /// The whole directory is still checked first — a hostile name or a
    /// lying record anywhere refuses the archive, chosen or not — because an
    /// archive that lies about one entry is not trusted about the others.
    /// For the same reason `limits.maximumEntryCount` counts every entry of
    /// the archive, before `include` is asked about any: it bounds the walk
    /// that has to happen before there is anything to choose from.
    /// Choosing nothing reads nothing and is not a refusal.
    public static func forEachFile(
        unpacking url: URL,
        limits: RMDocReadLimits = .default,
        where include: (RMDocEntry) throws -> Bool,
        _ body: (RMDocFile) throws -> Void
    ) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try ZipReader.forEachEntry(in: data, limits: limits, where: include) { entry in
            try body(RMDocFile(name: entry.name, data: entry.data))
        }
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
