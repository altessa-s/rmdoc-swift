// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMDoc
import Testing

/// What the end record of `zip` says the central directory spans.
private func declaredDirectorySize(_ zip: Data) throws -> Int {
    let bytes = ZipReader.Bytes(data: zip)
    return try bytes.u32(zip.count - 22 + 12)
}

/// A name in the device layout exactly `length` UTF-8 bytes long.
private func deviceName(length: Int, in document: String = documentID) -> String {
    "\(document)/" + String(repeating: "p", count: length - document.utf8.count - 1)
}

/// The values the documentation recommends for somebody else's file.
private let untrusted = RMDocReadLimits(maximumDirectorySize: 16 << 20, maximumNameLength: 1024)

/// Every read this package offers, each made to throw what it throws.
private func everyRead(of zip: Data, limits: RMDocReadLimits) -> [() throws -> Void] {
    let url = temporaryArchive("directory-limits")
    return [
        { _ = try RMDocArchive.entries(in: zip, limits: limits) },
        { _ = try RMDocArchive(unpacking: zip, limits: limits) },
        { try RMDocArchive.forEachFile(unpacking: zip, limits: limits) { _ in } },
        { try RMDocArchive.forEachFile(unpacking: zip, limits: limits, where: { _ in false }, { _ in }) },
        {
            try zip.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            try RMDocArchive.forEachFile(unpacking: url, limits: limits) { _ in }
        },
    ]
}

@Suite("The directory's own limits, weighed before it is listed")
struct DirectoryLimitsTests {
    @Test("A directory over the limit is refused before its first record is read")
    func directoryTooLargeIsRefusedFirst() throws {
        // The one record is hostile: reading it at all would refuse the
        // archive for its name. That the size is what refuses it shows no
        // record was read.
        let zip = ZipBuilder([.stored("../evil", Data("x".utf8))]).build()
        let size = try declaredDirectorySize(zip)
        let tight = RMDocReadLimits(maximumDirectorySize: size - 1)
        for read in everyRead(of: zip, limits: tight) {
            #expect(throws: RMDocReadError.directoryTooLarge(size: size, limit: size - 1), performing: read)
        }
        // At the limit the walk begins, and the record is what refuses.
        for read in everyRead(of: zip, limits: RMDocReadLimits(maximumDirectorySize: size)) {
            #expect(throws: RMDocError.invalidName("../evil"), performing: read)
        }
    }

    @Test("A directory that claims to run past the file is malformed, not merely too large")
    func lyingDirectoryIsNamedAsALie() throws {
        var zip = ZipBuilder([.stored("\(documentID).content", Data("{}".utf8))]).build()
        // The end record's directory size, raised past the file.
        let field = zip.count - 22 + 12
        zip.replaceSubrange(field ..< field + 4, with: [0xF0, 0xFF, 0xFF, 0x0F])
        #expect(throws: RMDocError.malformedArchive("central directory outside the file")) {
            _ = try RMDocArchive.entries(in: zip, limits: RMDocReadLimits(maximumDirectorySize: 1))
        }
    }

    @Test("A name over the limit is refused on its length, before it is decoded")
    func nameTooLongIsRefusedBeforeDecoding() throws {
        // Hostile as well as long: decoded and validated, it would be
        // refused as an invalid name instead.
        let long = "../" + String(repeating: "a", count: 1022)
        #expect(long.utf8.count == 1025)
        let zip = ZipBuilder([.stored(long, Data("x".utf8))]).build()
        for read in everyRead(of: zip, limits: untrusted) {
            #expect(throws: RMDocReadError.nameTooLong(length: 1025, limit: 1024), performing: read)
        }

        // A legitimate name one byte over is refused the same way, and one
        // at the limit is read.
        let over = ZipBuilder([.stored(deviceName(length: 1025), Data("x".utf8))]).build()
        #expect(throws: RMDocReadError.nameTooLong(length: 1025, limit: 1024)) {
            _ = try RMDocArchive.entries(in: over, limits: untrusted)
        }
        let atLimit = ZipBuilder([.stored(deviceName(length: 1024), Data("x".utf8))]).build()
        #expect(try RMDocArchive(unpacking: atLimit, limits: untrusted).files.first?.name.utf8.count == 1024)
        // The default is the format's, as in 0.11.0: the long name reads.
        #expect(try RMDocArchive.entries(in: over).count == 1)
    }

    @Test("A name that is not UTF-8 is refused on its length first, and as not UTF-8 within it")
    func lengthIsWeighedBeforeTheNameIsDecoded() throws {
        // 1 025 bytes that no decoder accepts: had the name been decoded
        // before its length was weighed, the refusal would name the encoding.
        let zip = notUTF8(length: 1025)
        for read in everyRead(of: zip, limits: untrusted) {
            #expect(throws: RMDocReadError.nameTooLong(length: 1025, limit: 1024), performing: read)
        }
        // With room for it, the same name reaches the decoder and fails there.
        let roomy = RMDocReadLimits(maximumNameLength: 1025)
        for read in everyRead(of: zip, limits: roomy) {
            #expect(throws: RMDocError.malformedArchive("entry name is not UTF-8"), performing: read)
        }
    }

    @Test("A directory of huge names is refused when the host asks, and listed by default")
    func hugeNamesNeedTheFormatPreset() throws {
        // Three hundred names of sixty thousand bytes: an 18 MB directory,
        // the shape that made a listing cost hundreds of megabytes.
        let entries = (0 ..< 300).map { index in
            ZipBuilder.Entry.stored(
                deviceName(length: 60000, in: String(format: "6c9a4bd0-0000-4000-8000-%012d", index)), Data()
            )
        }
        let zip = ZipBuilder(entries).build()
        let size = try declaredDirectorySize(zip)
        #expect(size > 16 << 20)

        #expect(throws: RMDocReadError.directoryTooLarge(size: size, limit: 16 << 20)) {
            _ = try RMDocArchive.entries(in: zip, limits: untrusted)
        }
        // Raising the directory alone still leaves the names over theirs.
        #expect(throws: RMDocReadError.nameTooLong(length: 60000, limit: 1024)) {
            _ = try RMDocArchive.entries(in: zip, limits: RMDocReadLimits(maximumNameLength: 1024))
        }
        // The default and `.format` are what 0.11.0 accepted, and still accept it.
        #expect(try RMDocArchive.entries(in: zip).count == 300)
        #expect(try RMDocArchive.entries(in: zip, limits: .format).count == 300)
    }

    @Test("The recommended limits accept a tablet-shaped archive at the format's full entry count")
    func defaultsAcceptARealisticMaximum() throws {
        // 65 535 entries named the way a notebook's are — pages, their
        // metadata and their thumbnails — packed by the library itself: the
        // most entries any archive may hold, at real names.
        var files = [try RMDocFile(name: "\(documentID).content", data: Data("{}".utf8))]
        var page = 0
        while files.count < 0xFFFF {
            let pageID = String(format: "aaaaaaaa-0000-4000-8000-%012d", page)
            let names = [
                "\(documentID)/\(pageID).rm",
                "\(documentID)/\(pageID)-metadata.json",
                "\(documentID).thumbnails/\(pageID).png",
            ]
            for name in names.prefix(0xFFFF - files.count) {
                files.append(try RMDocFile(name: name, data: Data()))
            }
            page += 1
        }
        let data = try RMDocArchive(files: files).packed()
        let size = try declaredDirectorySize(data)
        // Comfortably inside: 16 MiB leaves room for names longer than a
        // tablet's.
        #expect(size < 9 << 20)
        #expect(try RMDocArchive.entries(in: data, limits: untrusted).count == 0xFFFF)
        var read = 0
        try RMDocArchive.forEachFile(unpacking: data, limits: untrusted) { _ in read += 1 }
        #expect(read == 0xFFFF)
    }

    @Test("The directory's limits are opt-in: both presets keep 0.11.0's, the format's own")
    func presetsAndInitialisers() {
        #expect(RMDocReadLimits.default.maximumDirectorySize == .max)
        #expect(RMDocReadLimits.default.maximumNameLength == NameRule.maximumLength)
        #expect(RMDocReadLimits.format.maximumDirectorySize == .max)
        #expect(RMDocReadLimits.format.maximumNameLength == NameRule.maximumLength)
        // A call that names none of them takes the defaults.
        let older = RMDocReadLimits(maximumEntrySize: 1)
        #expect(older.maximumDirectorySize == RMDocReadLimits.default.maximumDirectorySize)
        #expect(older.maximumNameLength == RMDocReadLimits.default.maximumNameLength)
        #expect(RMDocReadLimits() == .default)
        // Every other limit of `.format` is what it was.
        #expect(RMDocReadLimits.format.maximumEntryCount == 0xFFFF)
        #expect(RMDocReadLimits.format.maximumEntrySize == 0xFFFF_FFFF)
        #expect(RMDocReadLimits.format.maximumCompressionRatio == Deflate.maximumRatio)
    }
}

/// One stored entry whose name is `length` bytes beginning with 0xFF, which
/// is never valid UTF-8 — in the directory and the local header alike, so
/// the two still agree. Spelled in ASCII and patched, because `ZipBuilder`
/// takes names as strings.
private func notUTF8(length: Int) -> Data {
    let placeholder = String(repeating: "Q", count: length)
    var zip = ZipBuilder([.stored(placeholder, Data("x".utf8))]).build()
    var from = zip.startIndex
    while let found = zip.range(of: Data(placeholder.utf8), in: from ..< zip.endIndex) {
        zip[found.lowerBound] = 0xFF
        from = found.upperBound
    }
    return zip
}
