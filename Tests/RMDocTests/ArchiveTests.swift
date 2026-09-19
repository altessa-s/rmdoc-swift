// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMDoc
import Testing

@Suite("The archive: round trip, determinism, and what it is made of")
struct ArchiveTests {
    @Test("A packed archive unpacks into the same files")
    func packedArchiveRoundTrips() throws {
        let archive = try sampleArchive()
        let unpacked = try RMDocArchive(unpacking: archive.packed())
        #expect(unpacked == archive)
        #expect(unpacked.documentIDs == [documentID])
    }

    @Test("Packing is deterministic: one document, one sequence of bytes")
    func packingIsDeterministic() throws {
        let archive = try sampleArchive()
        let first = try archive.packed()
        let second = try archive.packed()
        #expect(first == second)
    }

    @Test("The checksum is the standard CRC-32, not merely one we agree with ourselves")
    func checksumMatchesTheKnownAnswer() throws {
        // "123456789" is the check value every CRC-32 specification carries,
        // and 0xCBF43926 is what the zip flavour must produce for it. The
        // round-trip tests cannot catch a wrong checksum — both halves would
        // agree on it — so this is the one test that pins the polynomial.
        let archive = try RMDocArchive(files: [
            RMDocFile(name: "\(documentID).content", data: Data("123456789".utf8)),
        ])
        let bytes = try archive.packed()
        // The local header's checksum field: four bytes at offset 14, little
        // endian.
        let crc = bytes[14 ..< 18].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(crc == 0xCBF4_3926)
    }

    @Test("The container is a zip of stored entries")
    func packedBytesAreAStoredZip() throws {
        let data = try sampleArchive().packed()
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        // The method field of the first local header: offset 8, little
        // endian, and zero means store.
        #expect(data[8] == 0 && data[9] == 0)
    }

    @Test("An archive groups its files by document, in order of appearance")
    func documentIDsGroupFiles() throws {
        let other = "bbbbbbbb-0000-4000-8000-000000000003"
        let archive = try RMDocArchive(files: [
            RMDocFile(name: "\(documentID).content", data: Data()),
            RMDocFile(name: "\(other).content", data: Data()),
            RMDocFile(name: "\(documentID).metadata", data: Data()),
        ])
        #expect(archive.documentIDs == [documentID, other])
    }

    @Test("Two files under one name are refused")
    func duplicateNamesAreRefused() throws {
        let file = try RMDocFile(name: "\(documentID).content", data: Data())
        #expect(throws: RMDocError.duplicateName("\(documentID).content")) {
            _ = try RMDocArchive(files: [file, file])
        }
    }

    @Test("An archive with no files is refused")
    func emptyArchiveIsRefused() {
        #expect(throws: RMDocError.emptyArchive) {
            _ = try RMDocArchive(files: [])
        }
    }
}
