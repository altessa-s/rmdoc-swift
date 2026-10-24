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

@Test("The compiled deflate codec requires an exact length and no trailing input")
func compiledDeflateContract() throws {
    let payload = Data((0..<(Deflate.initialCapacity * 3 + 17)).map { UInt8(truncatingIfNeeded: $0) })
    let compressed = Deflate.compress(payload)
    try #require(compressed.count < payload.count)
    #expect(Deflate.decompress(compressed, count: payload.count) == payload)
    #expect(Deflate.decompress(compressed, count: payload.count + 1) == nil)
    #expect(Deflate.decompress(compressed, count: payload.count - 1) == nil)
    // Exceed Compression's read-ahead so trailing input remains visible to either codec.
    #expect(Deflate.decompress(compressed + Data(repeating: 0xa5, count: 64 * 1024), count: payload.count) == nil)
    #if !canImport(Compression)
    // Compression reads ahead into trailing input; miniz must reject even one extra byte.
    #expect(Deflate.decompress(compressed + Data([0]), count: payload.count) == nil)
    #endif
}
