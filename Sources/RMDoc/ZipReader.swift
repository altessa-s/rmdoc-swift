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
enum ZipReader {
    /// Every read below is bounds-checked before it happens: the lengths and
    /// offsets come off the wire, and the file's word alone must not be able
    /// to reach past its own bytes.
    static func unpack(_ data: Data) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        try forEachEntry(in: data) { entries.append($0) }
        return entries
    }

    /// The same read, handing each entry over as it is verified instead of
    /// gathering them. What it buys is the payloads: a caller that writes
    /// each file out as it arrives never holds more than one of them, where
    /// `unpack` holds every one at once.
    static func forEachEntry(in data: Data, _ body: (ZipEntry) throws -> Void) throws {
        guard let endRecord = findEndRecord(in: data) else {
            throw RMDocError.notAnArchive
        }
        let entryCount = Int(readU16(data, at: endRecord + 10))
        let directorySize = Int(readU32(data, at: endRecord + 12))
        let directoryOffset = Int(readU32(data, at: endRecord + 16))
        let directoryEnd = directoryOffset + directorySize
        guard directoryEnd <= endRecord else {
            throw RMDocError.malformedArchive("central directory outside the file")
        }

        var cursor = directoryOffset
        for _ in 0 ..< entryCount {
            guard cursor + 46 <= directoryEnd,
                  readU32(data, at: cursor) == 0x0201_4B50 else {
                throw RMDocError.malformedArchive("directory entry does not start where the last one ended")
            }
            let method = Int(readU16(data, at: cursor + 10))
            let crc = readU32(data, at: cursor + 16)
            let compressed = Int(readU32(data, at: cursor + 20))
            let uncompressed = Int(readU32(data, at: cursor + 24))
            let nameLength = Int(readU16(data, at: cursor + 28))
            let extraLength = Int(readU16(data, at: cursor + 30))
            let commentLength = Int(readU16(data, at: cursor + 32))
            let localOffset = Int(readU32(data, at: cursor + 42))
            guard cursor + 46 + nameLength <= directoryEnd else {
                throw RMDocError.malformedArchive("entry name runs past the directory")
            }
            guard let name = String(data: slice(data, cursor + 46, nameLength), encoding: .utf8) else {
                throw RMDocError.malformedArchive("entry name is not UTF-8")
            }
            // Stored and deflated, the two shapes a measured export uses:
            // some official exports store, the current desktop app deflates.
            // Anything else is news worth a sample, not a guess at unpacking
            // it — and it is refused with its method named.
            guard method == 0 || method == 8 else {
                throw RMDocError.unsupportedCompression(name: name, method: method)
            }
            if method == 0, compressed != uncompressed {
                throw RMDocError.malformedArchive("stored entry sizes disagree: \(name)")
            }
            // Checked before the allocation, not after: the uncompressed
            // length is the file's word, and deflate cannot have produced
            // more than `maximumRatio` times what it holds.
            if method == 8, uncompressed > compressed * Deflate.maximumRatio {
                throw RMDocError.malformedArchive("deflated entry claims more than deflate can produce: \(name)")
            }
            // The local header restates the name and may carry extra fields
            // of its own; its lengths, not the directory's, say where the
            // payload begins.
            guard localOffset + 30 <= data.count,
                  readU32(data, at: localOffset) == 0x0403_4B50 else {
                throw RMDocError.malformedArchive("local header missing: \(name)")
            }
            let localNameLength = Int(readU16(data, at: localOffset + 26))
            let localExtraLength = Int(readU16(data, at: localOffset + 28))
            let payloadStart = localOffset + 30 + localNameLength + localExtraLength
            guard payloadStart + compressed <= data.count else {
                throw RMDocError.malformedArchive("entry data runs past the file: \(name)")
            }
            let payload = slice(data, payloadStart, compressed)
            let bytes: Data
            if method == 8 {
                guard let inflated = Deflate.decompress(payload, count: uncompressed) else {
                    throw RMDocError.malformedArchive("deflated entry does not inflate: \(name)")
                }
                bytes = inflated
            } else {
                bytes = payload
            }
            // Over the entry's own bytes, which for a deflated entry is what
            // came out — the checksum a zip carries is of the payload, never
            // of its compressed form.
            guard CRC32.checksum(bytes) == crc else {
                throw RMDocError.checksumMismatch(name: name)
            }
            try body(ZipEntry(name: name, data: bytes))
            cursor += 46 + nameLength + extraLength + commentLength
        }
    }

    /// The end record is found from the tail: it is the one structure with a
    /// variable-length comment behind it, so the last 65557 bytes are the
    /// only place it can sit. A match must also account for every byte after
    /// itself, or the signature inside some entry's payload would pass.
    private static func findEndRecord(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var offset = data.count - 22
        while offset >= lowest {
            if readU32(data, at: offset) == 0x0605_4B50,
               offset + 22 + Int(readU16(data, at: offset + 20)) == data.count {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    // The incoming Data may be a slice with a non-zero start, so every
    // absolute offset is taken from its own `startIndex`.

    private static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(readU16(data, at: offset)) | UInt32(readU16(data, at: offset + 2)) << 16
    }

    private static func slice(_ data: Data, _ offset: Int, _ count: Int) -> Data {
        let base = data.startIndex + offset
        return data.subdata(in: base ..< base + count)
    }
}
