// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMDoc
import Testing

// Shared by the suites beside this file: the sample document every
// round-trip test packs, and the hand-built archive the reader tests need
// because the packer will not produce a hostile name.

let documentID = "6c9a4bd0-0000-4000-8000-000000000001"
let pageID = "aaaaaaaa-0000-4000-8000-000000000002"

func sampleArchive() throws -> RMDocArchive {
    try RMDocArchive(files: [
        RMDocFile(name: "\(documentID).content", data: Data("{\"formatVersion\":2}".utf8)),
        RMDocFile(name: "\(documentID).metadata", data: Data("{\"type\":\"DocumentType\"}".utf8)),
        RMDocFile(name: "\(documentID).pagedata", data: Data("Blank\n".utf8)),
        RMDocFile(name: "\(documentID)/\(pageID).rm", data: Data([0x72, 0x4D, 0x00, 0x01, 0x7F])),
    ])
}

/// One stored entry named `../evil`, written out. Built by hand because the
/// packer refuses such a name long before it reaches the bytes.
func hostileArchiveOnDisk() throws -> URL {
    let name = Data("../evil".utf8)
    var zip = Data()
    func le16(_ value: UInt16) {
        zip.append(UInt8(value & 0xFF))
        zip.append(UInt8(value >> 8))
    }
    func le32(_ value: UInt32) {
        le16(UInt16(value & 0xFFFF))
        le16(UInt16(value >> 16))
    }
    le32(0x0403_4B50)
    le16(10); le16(0); le16(0)
    le16(0); le16(0x0021)
    le32(0); le32(0); le32(0)
    le16(UInt16(name.count)); le16(0)
    zip.append(name)
    let directoryOffset = UInt32(zip.count)
    le32(0x0201_4B50)
    le16(20); le16(10); le16(0); le16(0)
    le16(0); le16(0x0021)
    le32(0); le32(0); le32(0)
    le16(UInt16(name.count))
    le16(0); le16(0); le16(0); le16(0)
    le32(0)
    le32(0)
    zip.append(name)
    let directorySize = UInt32(zip.count) - directoryOffset
    le32(0x0605_4B50)
    le16(0); le16(0); le16(1); le16(1)
    le32(directorySize); le32(directoryOffset)
    le16(0)
    let url = FileManager.default.temporaryDirectory
        .appending(path: "rmdoc-hostile-\(UUID().uuidString)")
    try zip.write(to: url)
    return url
}
