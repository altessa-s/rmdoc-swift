// swift-tools-version: 6.3
// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// The `.rmdoc` container: the file the tablet and the reMarkable apps export
// and import a document as. Packing and unpacking only — a plain zip of the
// document's files in the device layout, stored uncompressed. It is not sync
// v3 and shares nothing with it: no docSchema, no hashes, none of the cloud's
// code.
//
// Depends on nothing, and that is not a boast but the reason this package can
// stand on its own: bytes in, bytes out. Not even a logger — an archive that
// will not open says so by throwing.
import PackageDescription

let package = Package(
    name: "RMDoc",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RMDoc", targets: ["RMDoc"]),
    ],
    targets: [
        .target(
            name: "RMDoc",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RMDocTests",
            dependencies: ["RMDoc"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
