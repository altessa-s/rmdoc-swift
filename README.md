# RMDoc

[![CI](https://github.com/altessa-s/rmdoc-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/altessa-s/rmdoc-swift/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The `.rmdoc` container: the file a reMarkable tablet and the reMarkable apps
export and import a document as. Packing and unpacking, nothing else — what
the files inside *mean* is the caller's business. It is **not sync v3** and
shares nothing with it: no `docSchema`, no hashes, none of the cloud's code.

A standalone package with no external package dependencies. It began inside the Slate
Drive application and left it for the same reason the `.rm` parser did: the
`.rmdoc` container is reMarkable's format, not that application's, and a
codec other languages and other platforms are meant to reach has no business
living inside a macOS product. Slate Drive now links the `RMDoc.xcframework`
this repository builds.

## Why it exists

"Send to tablet" and export-with-ink both speak this container: a zip of the
document's files in the same layout the device keeps, taken off a live
export:

```
   <uuid>.content
   <uuid>.metadata
   <uuid>.pagedata
   <uuid>/<page-uuid>.rm
```

The zip's own table of contents is the list of files, and content addressing
exists only in the cloud. Reusing the sync code for it is a trap — there is
no index to write and no hashes to compute. So the container lives in a
package of its own, below the product: bytes in, bytes out.

## What it depends on

The package builds on macOS, Linux and Windows with Swift 6.3. It uses
Foundation and the system `Compression` framework where available. Platforms
without `Compression` use vendored miniz 3.1.2
([MIT license](Sources/CMiniz/LICENSE.txt)). No external package dependencies,
not even a logger. An archive that will not open says so by throwing
`RMDocError`, and what a host does about that is the host's business.

That is what makes this package testable against bytes and nothing else, and
what let it leave the application it was written in.

## Design

**Measured, not guessed.** The subset of zip implemented is the subset a
live export actually is: one directory level, no zip64, no encryption;
entries stored or deflated, read and written either way. ZIP64, encrypted
entries and spanned archives are named refusals (`RMDocReadError`) rather
than code with nothing to read: no export comes near four gigabytes, the
writer never produces them, and `RMDocFile` could not hold such a payload
anyway. Data descriptors are never written and are read only when they agree
with the central directory. Any other compression method is a named refusal (`unsupportedCompression`,
with the method), not a guess at unpacking it — a sample first, code second.
The writer stores by default and deflates on request
(`RMDocWriter.Compression`), and every export Slate Drive makes asks for
deflate: the desktop app deflates, and a tablet handed a large stored
container imports it and then dies of "Low memory" opening it, where the
same bytes deflated open fine. Store stays the default so the fixture path
and the byte-parity test keep their bytes.

**Packing is deterministic.** A fixed timestamp (1980-01-01, the earliest
DOS time can spell) and entries in the order given: one document packs into
one sequence of bytes, and a test holds it to that.

**Streaming stays inside the subset.** `RMDocWriter` learns a streamed
file's checksum and length as the payload goes past and writes them back
into its header — which is why its output is a file, not a pipe. The
alternative, data descriptors after the payload, is a corner of zip no
measured export uses; patching keeps what is written inside the subset, and
stored entries come out byte-identical to `packed()`'s.

**The reader trusts nothing.** Lengths and offsets come off the wire; every
read is bounds-checked, every payload is verified against its checksum, and
every name passes the same validation as a file built by hand — `../`,
absolute paths, a third directory level, a backslash, a dot-prefixed
component, a control character and a format character are refused before
anything could be written anywhere — the last of those because `\u{202E}`
renders `invoice<RLO>gpj.exe` as something a person reads as a picture and a
filesystem opens as an executable. A name longer than the sixteen-bit field
that carries it is refused for the same reason the oversized payload is:
there is no honest way to write it down. A deflated entry's uncompressed length is a claim too: it
is checked against what deflate can physically produce from the bytes the
entry holds — 1032:1 at the very most — before a single byte is allocated
for it, so a two-hundred-byte file cannot ask for four gigabytes.

The central directory is read whole before anything is inflated, and every
record in it is held to the file and to the rest: the local header must
restate the directory's name, method, checksum and sizes (or defer them to a
data descriptor that does); no payload may run past the file or into the
directory; no two entries may share bytes — the overlapping-entry bomb, where
a few kilobytes become petabytes without one record looking unusual — and the
directory must hold exactly the records its end record counts. A hostile or
duplicate name anywhere refuses the archive, whether or not its entry was
going to be read.

**Limits are the caller's.** `RMDocReadLimits` caps the entry count, each
entry's declared size and the total a read may declare, each entry's
compressed size and the compressed total, and the ratio of declared to
compressed size. They are weighed over every entry a read will inflate, all
together and before the first of them is — so a refusal costs a walk of the
directory, never half a pass. The directory's own limits are the exception:
the entry count, the directory's size as the end record declares it, and the
length of each name bound the directory walk itself, so they hold over the
whole archive, whatever a read goes on to choose, and over a listing too. The
directory's size is weighed before the first record is read and each name's
length before the name is decoded, so a directory of a few thousand
65 535-byte names costs nothing to refuse. The size ceilings default to the
format's own (65 535 entries, four gigabytes an entry, a directory as large
as the file, 65 535-byte names), because what is too much is the host's to
say; the ratio ceiling defaults to 200:1 for entries over a megabyte, because
nothing a tablet exports comes near it and a deflate bomb always does.
`RMDocReadLimits.format` restores deflate's physical 1032:1 for every entry.

For somebody else's file, set the directory's two limits: 16 MiB of
directory is 256 bytes a record at the format's 65 535 entries, and a
tablet's names are UUID paths under a hundred bytes — the full 65 535 entries
at such names list in under 9 MiB — and 1 024-byte names are `PATH_MAX` on
the platforms this package runs on, past which a name cannot be unpacked
anyway. A host on a tighter budget can go lower; 4 MiB still holds some
30 000 tablet-shaped entries.

**Inflation never runs ahead of the stream.** A deflated payload is inflated
in place, out of the (mapped) archive's own bytes, and never copied; the
compressed budget is what bounds the time a stream that declares nothing —
gigabytes of empty deflate blocks are valid — can take. The declared size is not
allocated up front: the output starts small and doubles only as the decoder
fills it, never past the declared length, and once that length is reached the
decoder is offered one spare byte — enough to tell "ended here" from "had
more to say" without producing the more. An entry that inflates to any other
length, or to bytes that fail its checksum, is refused.

**Choose before inflating.** `RMDocArchive.entries(in:)` lists the directory
— name, method, compressed and declared size, checksum — without inflating
anything, and `forEachFile(unpacking:limits:where:_:)` asks about every entry
before it inflates any: what the caller declines is never inflated, never
checksummed and never weighed against the size limits.

**Its own CRC-32.** The zip flavour: IEEE polynomial, reflected. Not the
CRC-32C the cloud's blob storage demands — same name, different polynomial —
so each implementation lives beside its own format.

## Types

| Type | What it is |
|---|---|
| `RMDocFile` | One file, named the way the device lays it out. The name is validated on construction; `documentID` answers which document it belongs to — the folder for a page file, the stem for a root file. |
| `RMDocArchive` | The container in memory: files in packing order. `init(files:)` starts an export, `init(unpacking:)` reads an import, `packed()` is the bytes to write as `<name>.rmdoc`, `documentIDs` the documents inside in order of first appearance — a folder sent whole arrives as several. |
| `RMDocWriter` | The container onto disk as it is gathered: entries as bytes or streamed files, stored or deflated — per entry too, for an EPUB's `mimetype` that must be stored whatever the rest does — headers patched once a payload's checksum is known. Its `.package` layout takes any relative name a zip specification lays out — nested, dotted — with the zip-slip guard alone, for the EPUB and Word writers that borrow it. |
| `RMDocEntry` | One entry as the central directory describes it — name, method, compressed and declared size, checksum — before anything is inflated. What a selective read chooses by. |
| `RMDocReadLimits` | What one read may take: entry count, the central directory's size, each name's length, each entry's declared and compressed size, the read's declared and compressed totals, the compression ratio past a threshold. `.default` and `.format` are the two presets. |
| `RMDocError` | One vocabulary for both directions, and the cases name the file at fault. |
| `RMDocReadError` | What a read declines for what it asks rather than for lying: a limit exceeded (`directoryTooLarge` and `nameTooLong` since 0.11.1), ZIP64, an encrypted entry, a spanned archive. Apart from `RMDocError` so that adding it broke no consumer's exhaustive `switch`, and not frozen. Give every `switch` over it an `@unknown default`: against the binary framework a later case then reaches that branch instead of breaking the client, but a source build without library evolution accepts an exhaustive `switch` without one — which stops compiling when a case is added. |

Reading has the same two shapes as writing: `RMDocArchive(unpacking:)` for a
container small enough to hold, `RMDocArchive.forEachFile(unpacking:)` for one
that is not — it maps the file and hands over each entry as it is verified,
so the peak is one payload rather than all of them. Both take
`limits:`, and `forEachFile` takes `where:` to choose entries from the
directory before any is inflated. Both read from a `URL` or from `Data` the
caller already holds — a mapping it made itself, say — and from `Data` a
deflated payload is inflated in place, exactly as from a mapping this package
makes: a host can list, vet and read through one mapping, with no second
open of the path between them. A mapping is not a snapshot: the file must stay
unchanged while it is listed and read, and a host that cannot promise that
reads from a copy.

## Using this package

**As a source dependency:**

```swift
dependencies: [
    .package(url: "https://github.com/altessa-s/rmdoc-swift.git", from: "0.12.1"),
    // or, beside a checkout: .package(path: "../rmdoc-swift")
],
targets: [
    .target(
        name: "YourTarget",
        // The package is identified by its directory — `rmdoc-swift` —
        // not by the library product it vends, which is `RMDoc`.
        dependencies: [.product(name: "RMDoc", package: "rmdoc-swift")]
    ),
]
```

**As a binary** — what Slate Drive does, and Apple platforms only: an
`.xcframework` is an Apple bundle, so a Linux or Windows consumer takes the
source dependency above. `Scripts/build-xcframework.sh` produces
`RMDoc.xcframework`, and every release attaches one, so the consumer names it
as a binary target — by path, or by the `url` and `checksum` the release notes
spell out:

```swift
targets: [
    .binaryTarget(name: "RMDoc", path: "RMDoc.xcframework"),
]
```

A binary module carries no testability, so a consumer's tests see the public
API only. A test that needs the inside of the reader or the writer belongs in
this repository.

The framework is dynamic, because Xcode embeds a package's binary framework
into the application bundle whatever it holds: it refuses a static one for
want of an `Info.plist`, and dynamic means one copy of the codec in a process
— an app and its extensions share it through the bundle's `Frameworks`.

Unpacking and packing:

```swift
// Unpack: every name and every checksum is checked on the way in.
let archive = try RMDocArchive(unpacking: data)
for file in archive.files { … }

// Or from a file, mapped rather than read — and one file at a time,
// so a book with ink never stands whole in memory.
try RMDocArchive.forEachFile(unpacking: url) { file in
    try file.data.write(to: destination.appending(path: file.name))
}

// Somebody else's file, in a process with a budget: map it once, list the
// directory, choose, and read only what was chosen — through the same
// mapping, under the host's own limits. (The file must not change meanwhile:
// a mapping is not a snapshot.)
let limits = RMDocReadLimits(
    maximumEntrySize: 256 << 20,
    maximumTotalSize: 512 << 20,
    maximumDirectorySize: 4 << 20,
    maximumNameLength: 1024
)
let data = try Data(contentsOf: url, options: .alwaysMapped)
let id = try RMDocArchive.entries(in: data, limits: limits).first { $0.name.hasSuffix(".content") }?.documentID
try RMDocArchive.forEachFile(
    unpacking: data,
    limits: limits,
    where: { $0.documentID == id && !$0.name.hasSuffix(".epub") },
    { file in keep(file) }
)

// Pack in memory, for a document small enough to hold twice.
let bytes = try RMDocArchive(files: files).packed()

// Or stream it to disk, which is what an export with ink wants —
// and what asks for deflate.
let writer = try RMDocWriter(to: url, compression: .deflate)
for file in files { try writer.add(name: file.name, data: file.data) }
try writer.add(name: "\(documentID).pdf", contentsOf: attachment)
try writer.finish()
```

## Tests

```sh
swift test
```

`RMDocTests` came out of the application with the sources: the round trip
stored and deflated, determinism, byte parity between the writer and
`packed()`, both layouts, and a refusal for every way an archive can lie
about itself — a hostile name, a flipped byte, a method we do not read, and
a deflated entry claiming more than deflate could have produced. Beside them,
hand-built archives tell one lie at a time — a local header that disagrees
with the directory, a data descriptor that does, entries that share bytes,
ZIP64, encryption, spanning, every truncation and every single flipped byte —
and a real deflate bomb, generated in the test, is refused on its ratio before
anything is inflated. Selective reads are counted, not inferred: a skipped
entry is shown never to reach the inflater. The bytes are synthetic, and what
they cannot say is whether the tablet accepts a packed archive — only the
tablet can, the same way it is the judge of a rendering.

One gap is known: no container exported by the tablet or the official apps
is checked in. Every archive the tests read is built by this package's own
writer or field by field in the test, so the reader is held to the zip
format as specified rather than to a captured export. A real export is
somebody's document; one is worth adding only when a blank, redistributable
sample can be made.

## Building the framework

```sh
Scripts/build-xcframework.sh                              # -> build/RMDoc.xcframework
Scripts/build-xcframework.sh ../some-app/Frameworks       # and install it there too
```

`Package.swift` is the real project; `project.yml` beside it declares the same
sources once more as a framework target, because SwiftPM cannot produce a
framework — archiving its library product leaves a bare `.o`. The script
generates that project with XcodeGen, archives it for macOS (arm64 and
x86_64), iOS (arm64) and the iOS Simulator (arm64 and x86_64), checks that
each is a dynamic framework with every slice it should have, and wraps them.
It needs Xcode with Swift 6.3 and `brew install xcodegen`.

## Releasing

Push a tag. `1.2.0` and `v1.2.0` both work, and a hyphen makes it a
pre-release (`1.2.0-beta.2`).

```sh
git tag 1.2.0
git push origin 1.2.0
```

The tag runs the tests first — a release is the one artefact nobody re-reads,
it is linked — then builds the framework, zips it with `ditto` (an
`.xcframework` is a bundle of symlinks, and a plain `zip` unpacks into
something Xcode declines), and publishes it with the lines a consumer pastes.
The checksum is computed in the same step from the very bytes that are
uploaded.

The tag is also the version the framework declares. `project.yml` carries
0.0.0, which says only "not a release"; to reproduce a release build locally:

```sh
RMDOC_VERSION=1.2.0 Scripts/build-xcframework.sh
```

## License

MIT — see [LICENSE](LICENSE).

reMarkable is a trademark of reMarkable AS. This project is not affiliated
with, endorsed by or sponsored by reMarkable AS; the container format is
implemented from exports the tablet and its apps make.
