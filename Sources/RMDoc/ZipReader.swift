// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Reading the container.
///
/// Everything a file says about itself is a claim: the lengths and offsets
/// come off the wire, so every read below is bounds-checked before it
/// happens and no claim can reach past the file's own bytes. A deflated
/// entry's uncompressed length is a claim too, and is bounded against what
/// deflate can physically produce before anything is allocated for it.
///
/// In two passes. The first reads the central directory whole and inflates
/// nothing: every record is checked against the file, against its local
/// header and against every other record, and what survives is a list of
/// entries a caller can choose from. The second inflates the chosen entries
/// alone, once the caller's limits have weighed all of them together — so a
/// refusal never comes after half a pass, and an entry passed over is never
/// touched.
enum ZipReader {
    /// An entry, and where its payload sits in the file.
    struct Located {
        let entry: RMDocEntry
        let payload: Range<Int>
    }

    /// Every entry, inflated and verified, held at once.
    static func unpack(_ data: Data, limits: RMDocReadLimits = .default) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        try forEachEntry(in: data, limits: limits) { entries.append($0) }
        return entries
    }

    /// The same read, handing each entry over as it is verified instead of
    /// gathering them. What it buys is the payloads: a caller that writes
    /// each file out as it arrives never holds more than one of them, where
    /// `unpack` holds every one at once.
    ///
    /// `include` sees every entry, in directory order, before anything is
    /// inflated; `didInflate` is told each time a deflated payload is about
    /// to be — what a test counts to show a skipped entry never was — and
    /// `inflatingFrom` is shown the very bytes the decoder reads, which a
    /// test holds against the archive's own to show they were not copied.
    static func forEachEntry(
        in data: Data,
        limits: RMDocReadLimits = .default,
        where include: (RMDocEntry) throws -> Bool = { _ in true },
        didInflate: ((RMDocEntry) -> Void)? = nil,
        inflatingFrom: ((UnsafeRawBufferPointer) -> Void)? = nil,
        _ body: (ZipEntry) throws -> Void
    ) throws {
        let chosen = try directory(of: data, limits: limits).filter { try include($0.entry) }
        try limits.check(chosen.map(\.entry))
        for located in chosen {
            let bytes = try contents(of: located, in: data, didInflate: didInflate, inflatingFrom: inflatingFrom)
            try body(ZipEntry(name: located.entry.name, data: bytes))
        }
    }

    /// One entry's bytes, inflated if they were deflated, and verified
    /// against the checksum the directory carries for them.
    private static func contents(
        of located: Located,
        in data: Data,
        didInflate: ((RMDocEntry) -> Void)?,
        inflatingFrom: ((UnsafeRawBufferPointer) -> Void)?
    ) throws -> Data {
        let entry = located.entry
        let bytes: Data
        if entry.isCompressed {
            didInflate?(entry)
            // Inflated in place, out of the archive's own bytes — mapped or
            // already in memory, whichever the caller handed over: the
            // compressed payload is never copied, so its size costs reading
            // time rather than heap — and `maximumCompressedEntrySize` and
            // `maximumCompressedTotalSize` bound the time.
            let inflated = data.withUnsafeBytes { archive in
                let payload = UnsafeRawBufferPointer(rebasing: archive[located.payload])
                inflatingFrom?(payload)
                return Deflate.decompress(payload, count: entry.uncompressedSize)
            }
            guard let inflated else {
                throw RMDocError.malformedArchive("deflated entry does not inflate: \(entry.name)")
            }
            bytes = inflated
        } else {
            // A stored payload is the file itself, and its length is the
            // declared size the limits have already weighed.
            let base = data.startIndex
            bytes = data.subdata(in: base + located.payload.lowerBound ..< base + located.payload.upperBound)
        }
        // Over the entry's own bytes, which for a deflated entry is what
        // came out — the checksum a zip carries is of the payload, never
        // of its compressed form.
        guard CRC32.checksum(bytes) == entry.crc32 else {
            throw RMDocError.checksumMismatch(name: entry.name)
        }
        return bytes
    }

    /// The table of contents, every claim in it checked and nothing
    /// inflated.
    ///
    /// The order of the checks is part of the contract: each refusal names
    /// the first thing wrong, and the tests pin which that is.
    static func directory(of data: Data, limits: RMDocReadLimits = .default) throws -> [Located] {
        let bytes = Bytes(data: data)
        guard let end = findEndRecord(in: bytes) else {
            throw RMDocError.notAnArchive
        }
        let thisDisk = try bytes.u16(end + 4)
        let directoryDisk = try bytes.u16(end + 6)
        let entriesOnDisk = try bytes.u16(end + 8)
        let entryCount = try bytes.u16(end + 10)
        let directorySize = try bytes.u32(end + 12)
        let directoryOffset = try bytes.u32(end + 16)
        // ZIP64 announces itself with a locator right before the end record
        // — after the directory, not inside it: the last record's comment
        // may end in the same four bytes and is no locator. When the end
        // record's own fields are ZIP64's sentinels, the directory's end is
        // unknowable and the signature is taken at its word.
        let locator = end - 20
        if locator >= 0, try bytes.u32(locator) == 0x0706_4B50 {
            let sentinel = directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF
            if sentinel || locator >= directoryOffset + directorySize {
                throw RMDocReadError.zip64Unsupported
            }
        }
        guard thisDisk == 0, directoryDisk == 0, entriesOnDisk == entryCount else {
            throw RMDocReadError.spannedArchive
        }
        guard entryCount <= limits.maximumEntryCount else {
            throw RMDocReadError.tooManyEntries(count: entryCount, limit: limits.maximumEntryCount)
        }
        let directoryEnd = directoryOffset + directorySize
        guard directoryEnd <= end else {
            throw RMDocError.malformedArchive("central directory outside the file")
        }
        // After the structural check, so a size that lies is named as a lie;
        // before the walk, so a directory too large to list costs nothing.
        guard directorySize <= limits.maximumDirectorySize else {
            throw RMDocReadError.directoryTooLarge(size: directorySize, limit: limits.maximumDirectorySize)
        }

        var records: [Record] = []
        records.reserveCapacity(entryCount)
        var names: Set<String> = []
        var cursor = directoryOffset
        for _ in 0 ..< entryCount {
            let record = try record(
                at: cursor, in: bytes, directoryOffset: directoryOffset, directoryEnd: directoryEnd,
                maximumNameLength: limits.maximumNameLength
            )
            let name = record.located.entry.name
            guard names.insert(name).inserted else {
                throw RMDocError.duplicateName(name)
            }
            records.append(record)
            cursor = record.end
        }
        // A directory longer than its count hides entries from this reader
        // that another reader would see; two readers must not disagree about
        // what an archive holds.
        guard cursor == directoryEnd else {
            throw RMDocError.malformedArchive("central directory holds more than the end record counts")
        }
        guard !records.isEmpty else { throw RMDocError.emptyArchive }
        // Two records pointing into the same bytes is how a few kilobytes
        // become a petabyte of output without one entry looking unusual —
        // the overlapping-entry bomb. An honest archive lays its entries end
        // to end.
        let ordered = records.sorted { $0.region.lowerBound < $1.region.lowerBound }
        for (previous, next) in zip(ordered, ordered.dropFirst())
        where previous.region.upperBound > next.region.lowerBound {
            throw RMDocError.malformedArchive("entries overlap: \(next.located.entry.name)")
        }
        return records.map(\.located)
    }

    /// The end record is found from the tail: it is the one structure with a
    /// variable-length comment behind it, so the last 65557 bytes are the
    /// only place it can sit. A match must also account for every byte after
    /// itself, or the signature inside some entry's payload would pass.
    private static func findEndRecord(in bytes: Bytes) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var offset = bytes.count - 22
        while offset >= lowest {
            if (try? bytes.u32(offset)) == 0x0605_4B50,
               let comment = try? bytes.u16(offset + 20),
               offset + 22 + comment == bytes.count {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    /// Little-endian reads that refuse to leave the file. Every offset
    /// above is a sum of fields at most 32 bits wide, so none of the
    /// arithmetic can overflow an `Int`; the reads themselves are where a
    /// claim pointing past the bytes is caught.
    ///
    /// The incoming Data may be a slice with a non-zero start, so every
    /// absolute offset is taken from its own `startIndex`.
    struct Bytes {
        let data: Data
        var count: Int { data.count }

        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else {
                throw RMDocError.malformedArchive("a field runs past the file")
            }
            let base = data.startIndex + offset
            return Int(data[base]) | Int(data[base + 1]) << 8
        }

        func u32(_ offset: Int) throws -> Int {
            try u16(offset) | u16(offset + 2) << 16
        }

        func slice(_ offset: Int, _ length: Int) throws -> Data {
            guard offset >= 0, length >= 0, offset + length <= data.count else {
                throw RMDocError.malformedArchive("a field runs past the file")
            }
            let base = data.startIndex + offset
            return data.subdata(in: base ..< base + length)
        }
    }
}
