// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// What can go wrong with an `.rmdoc` container, on either side of it.
///
/// One vocabulary for packing and unpacking: the caller that turns a case
/// into a sentence does not care which half refused, and the cases already
/// name the file at fault.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum RMDocError: Error, Equatable, Sendable {
    /// A file name the device layout has no place for: absolute, dotted,
    /// deeper than one folder, or empty. On import this is also the
    /// zip-slip guard — a name off the wire must not be able to reach
    /// outside the directory it is unpacked into.
    case invalidName(String)
    /// Two files under one name. A zip permits it; the layout does not.
    case duplicateName(String)
    /// An archive with no files is not a document.
    case emptyArchive
    /// Bigger than the store method can carry. There is no zip64 here on
    /// purpose: no export we have seen comes near four gigabytes, and a
    /// refusal that names the file beats a silently wrapped length.
    case fileTooLarge(name: String)
    case archiveTooLarge
    /// The bytes do not read as a zip at all.
    case notAnArchive
    /// A zip, but not one this reader can trust; the reason names the spot.
    case malformedArchive(String)
    /// The entry's compression method is one this reader does not implement.
    /// Stored and deflated are the two a measured export uses — some official
    /// exports store, the current desktop app deflates — and both are read.
    /// Anything else is news worth a sample, not a guess at unpacking it, so
    /// the method travels with the refusal.
    case unsupportedCompression(name: String, method: Int)
    /// The entry's bytes do not match the checksum the archive carries.
    case checksumMismatch(name: String)
    /// The writer has already written its directory. `finish()` happens
    /// once, and nothing goes into the archive after it.
    ///
    /// A refusal rather than a trap: this ships as a framework inside an
    /// application, where a throw is something the host can still recover
    /// from and a `precondition` is the whole process.
    case archiveFinished
}

// Equality spelled out rather than synthesised.
//
// `@frozen` lets a consumer compare two values directly, through the witness
// the compiler derives — and that witness is internal, so it is absent from
// this module's symbol table when RMDoc is linked as a binary framework. A
// generic comparison still goes through the exported protocol witness and is
// fine; a concrete one — `error == .notAnArchive`, with both types in view —
// resolves in a release build, where it is inlined, and fails to link in a
// debug one. Declaring `==` here puts the comparison behind an exported
// symbol, which costs nothing and keeps `@frozen`: a new case must still
// break a consumer's build rather than fall into an `@unknown default`.
extension RMDocError {
    public static func == (lhs: RMDocError, rhs: RMDocError) -> Bool {
        switch (lhs, rhs) {
        case (.emptyArchive, .emptyArchive),
             (.archiveTooLarge, .archiveTooLarge),
             (.notAnArchive, .notAnArchive),
             (.archiveFinished, .archiveFinished):
            true
        case let (.invalidName(left), .invalidName(right)): left == right
        case let (.duplicateName(left), .duplicateName(right)): left == right
        case let (.fileTooLarge(left), .fileTooLarge(right)): left == right
        case let (.malformedArchive(left), .malformedArchive(right)): left == right
        case let (.checksumMismatch(left), .checksumMismatch(right)): left == right
        case let (.unsupportedCompression(leftName, leftMethod), .unsupportedCompression(rightName, rightMethod)):
            leftName == rightName && leftMethod == rightMethod
        default: false
        }
    }
}
