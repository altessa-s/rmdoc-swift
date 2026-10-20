// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// One central-directory record and the local header it points at.
///
/// Apart from the directory walk because this is where the format's fields
/// are: every one of them a claim, checked against the file, against the
/// local header that restates it, and against what deflate can produce. The
/// walk in `ZipReader.directory(of:limits:)` then checks the records against
/// each other — names used twice, bytes shared.
extension ZipReader {
    /// A record that survived its checks.
    struct Record {
        let located: Located
        /// The bytes the entry occupies before the directory: local header,
        /// payload, and data descriptor if there is one.
        let region: Range<Int>
        /// Where the next directory record begins.
        let end: Int
    }

    /// The general-purpose flags that mean the payload is encrypted:
    /// traditional encryption, strong encryption, and a masked local header.
    private static let encryptionFlags = 0x0001 | 0x0040 | 0x2000
    /// The payload's checksum and sizes follow it, in a data descriptor,
    /// rather than standing in its local header.
    private static let descriptorFlag = 0x0008

    /// What the directory says the payload is, for the descriptor to agree
    /// with.
    private struct Claim {
        let crc: Int
        let compressed: Int
        let uncompressed: Int
    }

    /// One directory record and the local header it points at, each claim
    /// checked against the file and against the other.
    static func record(
        at cursor: Int, in bytes: Bytes, directoryOffset: Int, directoryEnd: Int
    ) throws -> Record {
        guard cursor + 46 <= directoryEnd, try bytes.u32(cursor) == 0x0201_4B50 else {
            throw RMDocError.malformedArchive("directory entry does not start where the last one ended")
        }
        let flags = try bytes.u16(cursor + 8)
        let method = try bytes.u16(cursor + 10)
        let claim = try Claim(
            crc: bytes.u32(cursor + 16),
            compressed: bytes.u32(cursor + 20),
            uncompressed: bytes.u32(cursor + 24)
        )
        let nameLength = try bytes.u16(cursor + 28)
        let extraLength = try bytes.u16(cursor + 30)
        let commentLength = try bytes.u16(cursor + 32)
        let startDisk = try bytes.u16(cursor + 34)
        let localOffset = try bytes.u32(cursor + 42)
        let recordEnd = cursor + 46 + nameLength + extraLength + commentLength
        guard recordEnd <= directoryEnd else {
            throw RMDocError.malformedArchive("directory entry runs past the directory")
        }
        let nameBytes = try bytes.slice(cursor + 46, nameLength)
        guard let name = String(data: nameBytes, encoding: .utf8) else {
            throw RMDocError.malformedArchive("entry name is not UTF-8")
        }
        // The zip-slip guard, here rather than only on `RMDocFile`: a
        // listing must not hand a caller a name it could not unpack.
        try NameRule.device(name)
        if try hasZip64Field(bytes, at: cursor + 46 + nameLength, length: extraLength, strict: true) {
            throw RMDocReadError.zip64Unsupported
        }
        guard startDisk == 0 else {
            throw RMDocReadError.spannedArchive
        }
        guard flags & encryptionFlags == 0 else {
            throw RMDocReadError.encryptedEntry(name: name)
        }
        // Stored and deflated, the two shapes a measured export uses:
        // some official exports store, the current desktop app deflates.
        // Anything else is news worth a sample, not a guess at unpacking
        // it — and it is refused with its method named.
        guard method == 0 || method == 8 else {
            throw RMDocError.unsupportedCompression(name: name, method: method)
        }
        if method == 0, claim.compressed != claim.uncompressed {
            throw RMDocError.malformedArchive("stored entry sizes disagree: \(name)")
        }
        // Checked before the allocation, not after: the uncompressed
        // length is the file's word, and deflate cannot have produced
        // more than `maximumRatio` times what it holds.
        if method == 8, claim.uncompressed > claim.compressed * Deflate.maximumRatio {
            throw RMDocError.malformedArchive("deflated entry claims more than deflate can produce: \(name)")
        }

        // The local header restates the name and may carry extra fields
        // of its own; its lengths, not the directory's, say where the
        // payload begins — and everything it restates must agree.
        guard localOffset + 30 <= bytes.count,
              try bytes.u32(localOffset) == 0x0403_4B50 else {
            throw RMDocError.malformedArchive("local header missing: \(name)")
        }
        let localFlags = try bytes.u16(localOffset + 6)
        let localMethod = try bytes.u16(localOffset + 8)
        let local = try Claim(
            crc: bytes.u32(localOffset + 14),
            compressed: bytes.u32(localOffset + 18),
            uncompressed: bytes.u32(localOffset + 22)
        )
        let localNameLength = try bytes.u16(localOffset + 26)
        let localExtraLength = try bytes.u16(localOffset + 28)
        let payloadStart = localOffset + 30 + localNameLength + localExtraLength
        let payloadEnd = payloadStart + claim.compressed
        guard payloadEnd <= bytes.count else {
            throw RMDocError.malformedArchive("entry data runs past the file: \(name)")
        }
        guard payloadEnd <= directoryOffset else {
            throw RMDocError.malformedArchive("entry data runs into the central directory: \(name)")
        }
        guard try bytes.slice(localOffset + 30, localNameLength) == nameBytes else {
            throw RMDocError.malformedArchive("local header names another file: \(name)")
        }
        // The descriptor flag too: a directory that promises a descriptor
        // the local header does not, or the other way round, describes two
        // different layouts of the same bytes.
        guard localMethod == method, localFlags & encryptionFlags == 0,
              localFlags & descriptorFlag == flags & descriptorFlag else {
            throw RMDocError.malformedArchive("local header disagrees with the directory: \(name)")
        }
        let localExtra = localOffset + 30 + localNameLength
        if try hasZip64Field(bytes, at: localExtra, length: localExtraLength, strict: false) {
            throw RMDocReadError.zip64Unsupported
        }
        var regionEnd = payloadEnd
        if localFlags & descriptorFlag != 0 {
            // The header may leave the fields zero and defer to the
            // descriptor; what it does say must still be true, and so
            // must the descriptor.
            guard local.crc == 0 || local.crc == claim.crc,
                  local.compressed == 0 || local.compressed == claim.compressed,
                  local.uncompressed == 0 || local.uncompressed == claim.uncompressed else {
                throw RMDocError.malformedArchive("local header disagrees with the directory: \(name)")
            }
            guard let descriptorEnd = try descriptorEnd(bytes, at: payloadEnd, before: directoryOffset, claim) else {
                throw RMDocError.malformedArchive("data descriptor disagrees with the directory: \(name)")
            }
            regionEnd = descriptorEnd
        } else {
            guard local.crc == claim.crc,
                  local.compressed == claim.compressed,
                  local.uncompressed == claim.uncompressed else {
                throw RMDocError.malformedArchive("local header disagrees with the directory: \(name)")
            }
        }

        let entry = RMDocEntry(
            name: name, method: method,
            compressedSize: claim.compressed, uncompressedSize: claim.uncompressed, crc32: UInt32(claim.crc)
        )
        return Record(
            located: Located(entry: entry, payload: payloadStart ..< payloadEnd),
            region: localOffset ..< regionEnd,
            end: recordEnd
        )
    }

    /// Whether an extra-field block carries a ZIP64 record (header 0x0001).
    ///
    /// Every block must fit inside the field: one that claims to run past
    /// it is refused, never skipped, because a scan that gave up there could
    /// miss a ZIP64 block behind it. The only slack is in a local header,
    /// which may end in fewer than four bytes of padding — too short to be a
    /// block at all, as some aligning tools leave it. The directory's blocks
    /// must tile their field exactly.
    private static func hasZip64Field(_ bytes: Bytes, at start: Int, length: Int, strict: Bool) throws -> Bool {
        var cursor = start
        let end = start + length
        while cursor + 4 <= end {
            let identifier = try bytes.u16(cursor)
            let size = try bytes.u16(cursor + 2)
            guard cursor + 4 + size <= end else {
                throw RMDocError.malformedArchive("extra field runs past its record")
            }
            if identifier == 0x0001 { return true }
            cursor += 4 + size
        }
        if strict, cursor != end {
            throw RMDocError.malformedArchive("extra field runs past its record")
        }
        return false
    }

    /// Where a data descriptor that agrees with the directory ends, or `nil`
    /// when there is none. The signature is optional in the format, and a
    /// checksum can happen to spell it, so both readings are tried.
    private static func descriptorEnd(_ bytes: Bytes, at start: Int, before limit: Int, _ claim: Claim) throws -> Int? {
        func matches(_ offset: Int) throws -> Bool {
            guard offset + 12 <= limit else { return false }
            return try bytes.u32(offset) == claim.crc
                && bytes.u32(offset + 4) == claim.compressed
                && bytes.u32(offset + 8) == claim.uncompressed
        }
        if start + 4 <= limit, try bytes.u32(start) == 0x0807_4B50, try matches(start + 4) {
            return start + 16
        }
        return try matches(start) ? start + 12 : nil
    }
}
