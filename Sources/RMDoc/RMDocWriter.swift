// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The container onto disk as it is gathered, instead of in memory twice.
///
/// `RMDocArchive.packed()` holds every payload and then the whole zip
/// beside them — fine for tests and small documents, twice the document
/// for a book with ink. This writer streams: an entry arrives as bytes or
/// as a file, goes to the output in chunks, and the archive never stands
/// whole in memory. In `.store` — the default — the bytes are identical to
/// `packed()`'s for the same entries, and a test holds them equal.
/// `packed()` has no deflate of its own: in memory the size is already
/// paid, so compression is the streaming writer's question.
///
/// A streamed file's checksum and length are learned as the payload goes
/// past and then written back into its header, which is why the output is
/// a file and not a pipe: the alternative — data descriptors after the
/// payload — is a corner of zip that official exports do not use, and that
/// our own reader accepts only by checking it against the directory.
/// Patching keeps what is written inside the subset.
///
/// A throw from any method leaves a half-written file behind; the caller
/// who staged the output throws it away. Not `Sendable` on purpose: one
/// writer, one file, one caller.
///
/// `finish()` is not optional. Without it the file ends after the last
/// payload with no central directory behind it, which is not a zip and
/// which nothing here can report — `deinit` closes the handle and has no
/// way to throw. A caller that may leave by an error path should stage the
/// output and promote it only after `finish()` returns.
public final class RMDocWriter {
    /// How entries go into the file. Store is the shape some official
    /// exports use; the current desktop app deflates, and a live tablet,
    /// handed a large stored container, imports it and then dies of "Low
    /// memory" opening it — the same bytes deflated open fine. Store stays
    /// the default so the fixture path and the byte-parity test keep their
    /// bytes.
    ///
    /// Frozen: this framework ships in lockstep with what links it, so there is
    /// no ABI to protect — and an exhaustive `switch` over these cases in a
    /// consumer is the point. A new case must break its build, not fall into an
    /// `@unknown default`.
    @frozen
    public enum Compression: Sendable {
        case store
        case deflate
    }

    /// Whose names the archive takes. The device's layout is the rule of
    /// an `.rmdoc`; a package — an EPUB, a Word file — is any zip, nested
    /// and dotted as its own specification lays it out, and the one guard
    /// left is the zip-slip one.
    ///
    /// Frozen: this framework ships in lockstep with what links it, so there is
    /// no ABI to protect — and an exhaustive `switch` over these cases in a
    /// consumer is the point. A new case must break its build, not fall into an
    /// `@unknown default`.
    @frozen
    public enum Layout: Sendable {
        case device
        case package
    }

    private let handle: FileHandle
    private let compression: Compression
    private let layout: Layout
    private var records: [ZipWriter.Record] = []
    private var names: Set<String> = []
    private var offset: UInt64 = 0
    private var finished = false

    /// Opens — and truncates — the file the archive will stream into.
    public init(to url: URL, compression: Compression = .store, layout: Layout = .device) throws {
        // Creating it first is what truncates a file already there. The
        // result is deliberately dropped rather than checked: whatever made
        // it fail is what the next line throws, and that error says which
        // path and why where a bare `false` would not.
        _ = FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.compression = compression
        self.layout = layout
    }

    deinit {
        try? handle.close()
    }

    /// An entry whose bytes are already in memory. `compression`
    /// overrides the writer's mode for this one entry — the EPUB spec
    /// wants its `mimetype` stored whatever the rest of the container
    /// does.
    public func add(name: String, data: Data, compression perEntry: Compression? = nil) throws {
        try claim(name)
        guard data.count <= 0xFFFF_FFFF else {
            throw RMDocError.fileTooLarge(name: name)
        }
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let size = UInt32(data.count)
        var payload = data
        var method: UInt16 = 0
        if (perEntry ?? compression) == .deflate {
            let squeezed = Deflate.compress(data)
            // A payload the squeeze made bigger goes in stored: smaller
            // file, and every entry still honest about its method.
            if squeezed.count < data.count {
                payload = squeezed
                method = 8
            }
        }
        let headerOffset = try fits(offset)
        try append(ZipWriter.localHeader(
            name: nameData, crc: crc,
            compressedSize: UInt32(payload.count), uncompressedSize: size, method: method
        ))
        try append(payload)
        records.append(.init(
            name: nameData, crc: crc, size: size,
            compressedSize: UInt32(payload.count), method: method, offset: headerOffset
        ))
    }

    /// An entry streamed out of a file, a chunk at a time. Streams stay
    /// stored whatever the writer's mode: the checksum patch was designed
    /// for a store header, and a compressed length is unknowable before
    /// the payload has gone past.
    public func add(name: String, contentsOf source: URL) throws {
        try claim(name)
        let nameData = Data(name.utf8)
        let headerOffset = try fits(offset)
        // Zeros where the checksum and the length go: they are known only
        // once the payload has streamed past, and are patched in below.
        try append(ZipWriter.localHeader(name: nameData, crc: 0, size: 0))

        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        var crc = CRC32.start
        var size: UInt64 = 0
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            crc = CRC32.adding(chunk, to: crc)
            size += UInt64(chunk.count)
            guard size <= 0xFFFF_FFFF else {
                throw RMDocError.fileTooLarge(name: name)
            }
            try append(chunk)
        }

        let checksum = CRC32.finished(crc)
        try handle.seek(toOffset: UInt64(headerOffset) + UInt64(ZipWriter.patchOffset))
        try handle.write(contentsOf: ZipWriter.patch(crc: checksum, size: UInt32(size)))
        try handle.seek(toOffset: offset)
        records.append(.init(
            name: nameData, crc: checksum, size: UInt32(size),
            compressedSize: UInt32(size), method: 0, offset: headerOffset
        ))
    }

    /// The central directory and the end record, and the file is closed.
    public func finish() throws {
        guard !finished else { throw RMDocError.archiveFinished }
        guard !records.isEmpty else { throw RMDocError.emptyArchive }
        guard records.count <= 0xFFFF else { throw RMDocError.archiveTooLarge }
        let directoryOffset = try fits(offset)
        // Set before the writes, not after. The guards above are refusals a
        // caller can still act on; past this point a throw leaves a file no
        // second `finish()` could rescue, and the precondition must catch
        // that call rather than let it append a second directory.
        finished = true
        try handle.write(contentsOf: ZipWriter.closing(records: records, directoryOffset: directoryOffset))
        try handle.close()
    }

    /// One name, once, and only the layout's kind — the same refusals an
    /// `RMDocFile` makes, so an entry cannot dodge them by arriving as a
    /// file.
    private func claim(_ name: String) throws {
        guard !finished else { throw RMDocError.archiveFinished }
        switch layout {
        case .device: try NameRule.device(name)
        case .package: try NameRule.package(name)
        }
        guard names.insert(name).inserted else {
            throw RMDocError.duplicateName(name)
        }
    }

    private func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private func fits(_ value: UInt64) throws -> UInt32 {
        guard value <= 0xFFFF_FFFF else { throw RMDocError.archiveTooLarge }
        return UInt32(value)
    }
}
