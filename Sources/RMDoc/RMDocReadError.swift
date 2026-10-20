// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// A container the reader declines not because it lies but because of what
/// it asks for: more than the caller's `RMDocReadLimits` allow, or a corner
/// of zip this package deliberately does not implement.
///
/// Apart from `RMDocError` on purpose. That enum is frozen so that a
/// consumer's exhaustive `switch` breaks on a new case; these refusals
/// arrived after consumers had written that switch, and a separate type
/// adds them without breaking a single build. A read can throw either.
///
/// Not frozen, unlike `RMDocError`. Under library evolution a frozen enum's
/// cases are part of its ABI for good — a case added later breaks clients
/// already built, and the attribute cannot be taken back without breaking
/// them either. Limits and refused features are the kind of list that grows,
/// so a consumer switching over this type should always write an
/// `@unknown default`. Against the binary framework the compiler demands it,
/// and a new case reaches it as a refusal rather than a broken link; built
/// from source without library evolution, an exhaustive `switch` without one
/// compiles today and fails to compile once a case is added.
public enum RMDocReadError: Error, Equatable, Sendable {
    /// The end record counts more entries than `maximumEntryCount`.
    case tooManyEntries(count: Int, limit: Int)
    /// One entry declares more than `maximumEntrySize`.
    case entryTooLarge(name: String, size: Int, limit: Int)
    /// The entries of one read together declare more than
    /// `maximumTotalSize`; `name` is the entry that crossed it.
    case totalSizeExceeded(name: String, limit: Int)
    /// A deflated entry claims more per compressed byte than
    /// `maximumCompressionRatio` allows.
    case compressionRatioExceeded(name: String, compressedSize: Int, uncompressedSize: Int, limit: Int)
    /// One entry occupies more of the archive than
    /// `maximumCompressedEntrySize`.
    case compressedEntryTooLarge(name: String, size: Int, limit: Int)
    /// The entries of one read together occupy more of the archive than
    /// `maximumCompressedTotalSize`; `name` is the entry that crossed it.
    case compressedTotalSizeExceeded(name: String, limit: Int)
    /// The archive uses ZIP64. Refused rather than read: no export comes
    /// near the four gigabytes that need it, the writer never produces it,
    /// and `RMDocFile` cannot hold a payload that large anyway — a reader
    /// for it would be code with nothing to read.
    case zip64Unsupported
    /// The entry is encrypted. No export is, and there is no key to ask for.
    case encryptedEntry(name: String)
    /// The archive claims to span several disks. A spanned zip is a set of
    /// files, and an `.rmdoc` is one.
    case spannedArchive
}

// Spelled out for the reason `RMDocError`'s is: a concrete comparison in a
// consumer must go through an exported symbol when this module is linked as
// a binary framework.
extension RMDocReadError {
    public static func == (lhs: RMDocReadError, rhs: RMDocReadError) -> Bool {
        switch (lhs, rhs) {
        case (.zip64Unsupported, .zip64Unsupported),
             (.spannedArchive, .spannedArchive):
            true
        case let (.tooManyEntries(leftCount, leftLimit), .tooManyEntries(rightCount, rightLimit)):
            leftCount == rightCount && leftLimit == rightLimit
        case let (.entryTooLarge(leftName, leftSize, leftLimit), .entryTooLarge(rightName, rightSize, rightLimit)):
            leftName == rightName && leftSize == rightSize && leftLimit == rightLimit
        case let (.totalSizeExceeded(leftName, leftLimit), .totalSizeExceeded(rightName, rightLimit)):
            leftName == rightName && leftLimit == rightLimit
        case let (
            .compressionRatioExceeded(leftName, leftCompressed, leftUncompressed, leftLimit),
            .compressionRatioExceeded(rightName, rightCompressed, rightUncompressed, rightLimit)
        ):
            leftName == rightName && leftCompressed == rightCompressed
                && leftUncompressed == rightUncompressed && leftLimit == rightLimit
        case let (
            .compressedEntryTooLarge(leftName, leftSize, leftLimit),
            .compressedEntryTooLarge(rightName, rightSize, rightLimit)
        ):
            leftName == rightName && leftSize == rightSize && leftLimit == rightLimit
        case let (.compressedTotalSizeExceeded(leftName, leftLimit), .compressedTotalSizeExceeded(rightName, rightLimit)):
            leftName == rightName && leftLimit == rightLimit
        case let (.encryptedEntry(left), .encryptedEntry(right)):
            left == right
        default:
            false
        }
    }
}
