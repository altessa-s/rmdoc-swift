# RMDoc

The `.rmdoc` container: the file a reMarkable tablet and the reMarkable apps
export and import a document as. Packing and unpacking, nothing else — what
the files inside *mean* is the caller's business. It is **not sync v3** and
shares nothing with it: no `docSchema`, no hashes, none of the cloud's code.

A standalone package with no dependencies at all. It began inside the Slate
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

Nothing. Foundation for `Data` and nothing else — no package of anyone's, not
even a logger. An archive that will not open says so by throwing
`RMDocError`, and what a host does about that is the host's business.

That is what makes this package testable against bytes and nothing else, and
what let it leave the application it was written in.

## Design

**Measured, not guessed.** The subset of zip implemented is the subset a
live export actually is: one directory level, no zip64, no encryption, no
data descriptors; entries stored or deflated, read and written either way.
Any other compression method is a named refusal (`unsupportedCompression`,
with the method), not a guess at unpacking it — a sample first, code second.
The writer stores by default and deflates on request
(`RMDocWriter.Compression`), and every export the product makes asks for
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
measured export uses and our own reader refuses; patching keeps the subset
exact, and stored entries come out byte-identical to `packed()`'s.

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

**Its own CRC-32.** The zip flavour: IEEE polynomial, reflected. Not the
CRC-32C the cloud's blob storage demands — same name, different polynomial —
so each implementation lives beside its own format.

## Types

| Type | What it is |
|---|---|
| `RMDocFile` | One file, named the way the device lays it out. The name is validated on construction; `documentID` answers which document it belongs to — the folder for a page file, the stem for a root file. |
| `RMDocArchive` | The container in memory: files in packing order. `init(files:)` starts an export, `init(unpacking:)` reads an import, `packed()` is the bytes to write as `<name>.rmdoc`, `documentIDs` the documents inside in order of first appearance — a folder sent whole arrives as several. |
| `RMDocWriter` | The container onto disk as it is gathered: entries as bytes or streamed files, stored or deflated — per entry too, for an EPUB's `mimetype` that must be stored whatever the rest does — headers patched once a payload's checksum is known. Its `.package` layout takes any relative name a zip specification lays out — nested, dotted — with the zip-slip guard alone, for the EPUB and Word writers that borrow it. |
| `RMDocError` | One vocabulary for both directions, and the cases name the file at fault. |

Reading has the same two shapes as writing: `RMDocArchive(unpacking:)` for a
container small enough to hold, `RMDocArchive.forEachFile(unpacking:)` for one
that is not — it maps the file and hands over each entry as it is verified,
so the peak is one payload rather than all of them.

## Using this package

**As a source dependency:**

```swift
dependencies: [
    .package(path: "../rmdoc-swift"),
    // or .package(url: "…/rmdoc-swift.git", from: "1.0.0")
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

**As a binary** — what Slate Drive does. `Scripts/build-xcframework.sh`
produces `RMDoc.xcframework`, and the consumer names it as a binary target:

```swift
targets: [
    .binaryTarget(name: "RMDoc", path: "RMDoc.xcframework"),
]
```

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
a deflated entry claiming more than deflate could have produced. The bytes are synthetic, and what
they cannot say is whether the tablet accepts a packed archive — only the
tablet can, the same way it is the judge of a rendering.

## Building the framework

```sh
Scripts/build-xcframework.sh                              # -> build/RMDoc.xcframework
Scripts/build-xcframework.sh ../slitedrive-internal/ThirdParty/RMDoc
```

`Package.swift` is the real project; `project.yml` beside it declares the same
sources once more as a framework target, because SwiftPM cannot produce a
framework — archiving its library product leaves a bare `.o`. The script
generates that project with XcodeGen, archives it for macOS (arm64 and
x86_64), checks that what came out is a dynamic framework of both slices, and
wraps it.
