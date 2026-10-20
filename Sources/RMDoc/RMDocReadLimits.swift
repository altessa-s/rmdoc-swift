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
/// The one exception is `maximumEntryCount`: it bounds the directory walk
/// itself, which happens before any entry can be chosen, so it counts every
/// entry of the archive — chosen, passed over, or none chosen at all.
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
/// a document — see `maximumCompressionRatio`.
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

    public init(
        maximumEntryCount: Int = 0xFFFF,
        maximumEntrySize: Int = 0xFFFF_FFFF,
        maximumTotalSize: Int = .max,
        maximumCompressionRatio: Int = 200,
        compressionRatioThreshold: Int = 1 << 20,
        maximumCompressedEntrySize: Int = 0xFFFF_FFFF,
        maximumCompressedTotalSize: Int = .max
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumEntrySize = maximumEntrySize
        self.maximumTotalSize = maximumTotalSize
        self.maximumCompressionRatio = maximumCompressionRatio
        self.compressionRatioThreshold = compressionRatioThreshold
        self.maximumCompressedEntrySize = maximumCompressedEntrySize
        self.maximumCompressedTotalSize = maximumCompressedTotalSize
    }

    /// What every read without limits of its own uses: the format's own
    /// ceilings on count and sizes, and 200:1 past a megabyte.
    public static let `default` = RMDocReadLimits()

    /// The format's ceilings and nothing tighter: 65 535 entries, four
    /// gigabytes an entry, and deflate's physical 1032:1 for every entry —
    /// what the reader accepted before limits existed.
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
