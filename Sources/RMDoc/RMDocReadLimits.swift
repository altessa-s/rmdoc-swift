// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// How much one read of a container may take, weighed against what its
/// central directory declares — before anything is inflated or allocated.
///
/// A container is somebody else's file, and its sizes are its own claims.
/// The structural checks keep those claims inside what the bytes can
/// physically hold; these keep them inside what the host is willing to
/// spend. They are checked over the entries a read will actually inflate —
/// every entry for `init(unpacking:)`, the chosen ones for a selective
/// `forEachFile` — all at once and before the first of them is inflated, so
/// a refusal costs a walk of the directory and nothing else. An entry a
/// caller passes over is never weighed and never inflated.
///
/// The exceptions are the directory's own limits — `maximumEntryCount`,
/// `maximumDirectorySize` and `maximumNameLength`. They bound the directory
/// walk itself, which happens before any entry can be chosen, so they hold
/// over every entry of the archive — chosen, passed over, or none chosen at
/// all — and over a listing too.
///
/// Two kinds of size are weighed. The declared, uncompressed sizes bound
/// what a read allocates. The compressed sizes bound what it reads: a
/// deflated payload is inflated in place, out of the archive's own bytes,
/// so it costs no heap — but a valid deflate stream can be gigabytes of
/// empty blocks that inflate to nothing, and declare nothing, and the
/// decoder must still walk every byte of it.
///
/// The size ceilings default to what the format itself can spell, because
/// what is too much is the host's to say: a Quick Look extension and a
/// desktop import want very different numbers. The ratio ceiling defaults to
/// something much tighter than the format, because a deflate bomb is never
/// a document — see `maximumCompressionRatio`. The directory's size and the
/// length of a name default to the format's too, so that no archive an
/// earlier release read is refused by a default; a host reading somebody
/// else's file should set both — see `maximumDirectorySize` and
/// `maximumNameLength` for the values worth starting from.
public struct RMDocReadLimits: Sendable, Equatable {
    /// The most entries the central directory may list. Checked against the
    /// end record's count before the directory is walked — so, unlike every
    /// other limit here, over the whole archive whatever a read chooses.
    public var maximumEntryCount: Int
    /// The largest uncompressed size one entry may declare.
    public var maximumEntrySize: Int
    /// The most the entries of one read may declare together — the whole
    /// archive for `init(unpacking:)`, the chosen entries for a selective
    /// `forEachFile`.
    public var maximumTotalSize: Int
    /// The highest ratio of declared to compressed size an entry larger than
    /// `compressionRatioThreshold` may claim.
    ///
    /// Deflate cannot expand anything by more than 1032:1, and a claim past
    /// that is refused whatever this says, as a malformed archive. Below it,
    /// a tablet's files are nowhere near: pages a few to one, a PDF's streams
    /// already compressed inside it. Past a megabyte, two hundred to one is
    /// a bomb rather than a document. A value below 1 is read as 1.
    public var maximumCompressionRatio: Int
    /// Entries that declare this much or less are exempt from the ratio
    /// ceiling: a `.content` of whitespace compresses absurdly and costs
    /// nothing to inflate.
    public var compressionRatioThreshold: Int
    /// The most one entry may occupy in the archive.
    public var maximumCompressedEntrySize: Int
    /// The most the entries of one read may occupy in the archive together.
    public var maximumCompressedTotalSize: Int
    /// The most bytes the central directory may span, as the end record
    /// declares it. Checked before the first record is read — so, like
    /// `maximumEntryCount`, over the whole archive whatever a read chooses,
    /// and for a listing too.
    ///
    /// The directory is where a listing's memory goes: every record becomes
    /// an `RMDocEntry` with its name materialised, and a name may be 65 535
    /// bytes, so the entry count alone lets a few thousand records ask for
    /// hundreds of megabytes before a caller has seen one of them.
    ///
    /// Unbounded by default, as before this limit existed. For untrusted
    /// input, 16 MiB refuses nothing a tablet makes: it is 256 bytes a
    /// record at the format's 65 535 entries, a record is 46 bytes and its
    /// name, and a tablet's names are UUID paths under a hundred bytes — the
    /// full 65 535 entries at such names list in under 9 MiB. A host with a
    /// tighter budget, such as a Quick Look extension, can go lower: 4 MiB
    /// still holds some 30 000 tablet-shaped entries.
    public var maximumDirectorySize: Int
    /// The longest name, in UTF-8 bytes, one directory record may carry.
    /// Checked as each record is read, before its name is decoded.
    ///
    /// The default is the format's 65 535, as before this limit existed. For
    /// untrusted input, 1 024 is the value worth setting: it is `PATH_MAX` on
    /// the platforms this package runs on, so a longer name cannot be opened
    /// as a path there even before the directory it is unpacked into is put
    /// in front of it, and a tablet's names are UUID paths —
    /// `<uuid>/<uuid>.rm`, `<uuid>.thumbnails/<uuid>.png` — under a hundred
    /// bytes.
    public var maximumNameLength: Int

    /// The limits as 0.11.0 spelled them; the directory's own take their
    /// defaults. Kept so that clients built against that release still link.
    public init(
        maximumEntryCount: Int = 0xFFFF,
        maximumEntrySize: Int = 0xFFFF_FFFF,
        maximumTotalSize: Int = .max,
        maximumCompressionRatio: Int = 200,
        compressionRatioThreshold: Int = 1 << 20,
        maximumCompressedEntrySize: Int = 0xFFFF_FFFF,
        maximumCompressedTotalSize: Int = .max
    ) {
        self.init(
            maximumEntryCount: maximumEntryCount,
            maximumEntrySize: maximumEntrySize,
            maximumTotalSize: maximumTotalSize,
            maximumCompressionRatio: maximumCompressionRatio,
            compressionRatioThreshold: compressionRatioThreshold,
            maximumCompressedEntrySize: maximumCompressedEntrySize,
            maximumCompressedTotalSize: maximumCompressedTotalSize,
            maximumDirectorySize: .max,
            maximumNameLength: 0xFFFF
        )
    }

    /// Every limit. A call that names none of the directory's own resolves
    /// to the initialiser above, with the same defaults — and so does an
    /// unapplied `RMDocReadLimits.init`, which named that one alone in
    /// 0.11.0: this one is disfavoured.
    @_disfavoredOverload
    public init(
        maximumEntryCount: Int = 0xFFFF,
        maximumEntrySize: Int = 0xFFFF_FFFF,
        maximumTotalSize: Int = .max,
        maximumCompressionRatio: Int = 200,
        compressionRatioThreshold: Int = 1 << 20,
        maximumCompressedEntrySize: Int = 0xFFFF_FFFF,
        maximumCompressedTotalSize: Int = .max,
        maximumDirectorySize: Int = .max,
        maximumNameLength: Int = 0xFFFF
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumEntrySize = maximumEntrySize
        self.maximumTotalSize = maximumTotalSize
        self.maximumCompressionRatio = maximumCompressionRatio
        self.compressionRatioThreshold = compressionRatioThreshold
        self.maximumCompressedEntrySize = maximumCompressedEntrySize
        self.maximumCompressedTotalSize = maximumCompressedTotalSize
        self.maximumDirectorySize = maximumDirectorySize
        self.maximumNameLength = maximumNameLength
    }

    /// What every read without limits of its own uses: the format's own
    /// ceilings on count, sizes, the directory and names, and 200:1 past a
    /// megabyte.
    public static let `default` = RMDocReadLimits()

    /// The format's ceilings and nothing tighter: 65 535 entries, four
    /// gigabytes an entry, 65 535-byte names in a directory as large as the
    /// file, and deflate's physical 1032:1 for every entry — what the reader
    /// accepted before limits existed.
    public static let format = RMDocReadLimits(
        maximumCompressionRatio: 1032,
        compressionRatioThreshold: 0
    )

    /// Every entry of one read weighed in order, and the first that does
    /// not fit named. The sizes are 32-bit and there are at most 65 535 of
    /// them, so the running total cannot overflow.
    func check(_ entries: [RMDocEntry]) throws {
        let ratio = max(maximumCompressionRatio, 1)
        var total = 0
        var compressedTotal = 0
        for entry in entries {
            guard entry.compressedSize <= maximumCompressedEntrySize else {
                throw RMDocReadError.compressedEntryTooLarge(
                    name: entry.name, size: entry.compressedSize, limit: maximumCompressedEntrySize
                )
            }
            compressedTotal += entry.compressedSize
            guard compressedTotal <= maximumCompressedTotalSize else {
                throw RMDocReadError.compressedTotalSizeExceeded(name: entry.name, limit: maximumCompressedTotalSize)
            }
            guard entry.uncompressedSize <= maximumEntrySize else {
                throw RMDocReadError.entryTooLarge(
                    name: entry.name, size: entry.uncompressedSize, limit: maximumEntrySize
                )
            }
            if entry.uncompressedSize > compressionRatioThreshold {
                let (allowed, overflow) = entry.compressedSize.multipliedReportingOverflow(by: ratio)
                if !overflow, entry.uncompressedSize > allowed {
                    throw RMDocReadError.compressionRatioExceeded(
                        name: entry.name,
                        compressedSize: entry.compressedSize,
                        uncompressedSize: entry.uncompressedSize,
                        limit: ratio
                    )
                }
            }
            total += entry.uncompressedSize
            guard total <= maximumTotalSize else {
                throw RMDocReadError.totalSizeExceeded(name: entry.name, limit: maximumTotalSize)
            }
        }
    }
}
