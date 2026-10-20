// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMDoc
import Testing

// Compiled as a client compiles: a plain import, no testability. These
// lines are the test — a new overload that makes any of them ambiguous
// fails the build, before a single test runs.

/// Takes only the 0.11.0 `URL` reader's exact type.
private func urlReader(_ read: (URL, (RMDocFile) throws -> Void) throws -> Void) -> Bool { true }

@Suite("What compiled against 0.11.0 still compiles, and means the same")
struct SourceCompatibilityTests {
    @Test("Unapplied references still name the 0.11.0 declarations")
    func unappliedReferencesAreUnambiguous() throws {
        // Inferred, with no contextual type: exactly what a client wrote.
        let read = RMDocArchive.forEachFile(unpacking:_:)
        let make = RMDocReadLimits.init
        #expect(urlReader(read))

        // `make` is the seven-argument 0.11.0 initialiser: the directory's
        // limits come out at their defaults.
        let limits = make(0xFFFF, 0xFFFF_FFFF, .max, 200, 1 << 20, 0xFFFF_FFFF, .max)
        #expect(limits == .default)

        let url = temporaryArchive("source-compatibility")
        defer { try? FileManager.default.removeItem(at: url) }
        try sampleArchive().packed().write(to: url)
        var names: [String] = []
        try read(url) { names.append($0.name) }
        #expect(try names == sampleArchive().files.map(\.name))
    }

    @Test("Calls with Data and with the new labels still reach the new declarations")
    func directCallsReachTheNewOverloads() throws {
        let data = try sampleArchive().packed()
        let expected = try sampleArchive().files
        var read: [RMDocFile] = []
        try RMDocArchive.forEachFile(unpacking: data) { read.append($0) }
        try RMDocArchive.forEachFile(unpacking: data, limits: .default) { read.append($0) }
        try RMDocArchive.forEachFile(unpacking: data, where: { _ in true }, { read.append($0) })
        #expect(read == expected + expected + expected)

        // A reference typed for `Data` picks the `Data` overload.
        let fromData: (Data, (RMDocFile) throws -> Void) throws -> Void = RMDocArchive.forEachFile(unpacking:_:)
        var again: [RMDocFile] = []
        try fromData(data) { again.append($0) }
        #expect(again == expected)

        let tight = RMDocReadLimits(maximumDirectorySize: 1)
        #expect(tight.maximumDirectorySize == 1)
        #expect(RMDocReadLimits(maximumEntrySize: 1, maximumNameLength: 2).maximumNameLength == 2)
        #expect(throws: RMDocReadError.directoryTooLarge(size: 46 * 4 + expected.map(\.name.utf8.count).reduce(0, +), limit: 1)) {
            try RMDocArchive.forEachFile(unpacking: data, limits: tight) { _ in }
        }
    }
}
