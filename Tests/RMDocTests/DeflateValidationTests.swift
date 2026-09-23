// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMDoc
import Testing

@Test("Deflate requires its exact output length and a complete stream")
func rejectsTruncatedInflation() {
    let full = Data(repeating: 65, count: 10000)
    let compressed = Deflate.compress(full)
    #expect(Deflate.decompress(compressed, count: 100) == nil)
    #expect(Deflate.decompress(compressed, count: 10001) == nil)
    #expect(Deflate.decompress(compressed.dropLast(), count: full.count) == nil)
    #expect(Deflate.decompress(compressed, count: full.count) == full)
    #expect(Deflate.decompress(Data([0xff]), count: 0) == nil)
    #expect(Deflate.decompress(Data(), count: 0) == nil)
    #expect(Deflate.decompress(Data([0x03, 0x00]), count: 0) == Data())
    #expect(Deflate.decompress(Data([0x03]), count: 0) == nil)
}

@Test func archiveRejectsTruncatedInflation() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "deflate-audit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try RMDocWriter(to: url, compression: .deflate)
    try writer.add(name: "document.content", data: Data(repeating: 65, count: 10000))
    try writer.finish()
    var bytes = try Data(contentsOf: url)
    let directory = try #require(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
    func patch(_ offset: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    let crc = CRC32.checksum(Data(repeating: 65, count: 100))
    patch(14, crc)
    patch(22, 100)
    patch(directory + 16, crc)
    patch(directory + 24, 100)
    #expect(throws: RMDocError.malformedArchive("deflated entry does not inflate: document.content")) {
        _ = try RMDocArchive(unpacking: bytes)
    }
}
