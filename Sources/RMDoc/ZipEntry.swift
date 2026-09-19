// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// One file inside an `.rmdoc`: what a pack is given and what an unpack
/// hands back.
///
/// The container both halves speak is a subset of zip: one directory level,
/// no zip64, no encryption, no data descriptors; entries stored or deflated,
/// read and written either way. Official exports are inconsistent about which
/// they use — the current desktop app deflates — and a live tablet, handed a
/// large stored container, imports it and then dies of "Low memory" opening
/// it. Deflate is not a nicety, and a reader that refused it could not open
/// what this package itself writes.
struct ZipEntry {
    let name: String
    let data: Data
}
