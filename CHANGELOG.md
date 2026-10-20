# Changelog

Releases are tagged and published from GitHub; this file records what each
one changes for a consumer. Earlier releases are described in their GitHub
release notes.

## Unreleased

### BREAKING (behaviour)

- **The entry points without a `limits:` argument now read under
  `RMDocReadLimits.default`, which refuses an entry declaring more than a
  megabyte at a compression ratio past 200:1.** Until now deflate's physical
  ceiling, 1032:1, was the only bound. Every signature still compiles, but an
  archive the previous release opened can now throw
  `RMDocReadError.compressionRatioExceeded` — including one this package's own
  `RMDocWriter` produced from highly repetitive data (sixteen megabytes of
  one byte deflate far past 200:1; the test suite holds exactly this case).

  **Migration:** to keep the previous behaviour, pass the format's own
  ceilings explicitly:

  ```swift
  RMDocArchive(unpacking: url, limits: .format)
  RMDocArchive.forEachFile(unpacking: url, limits: .format) { file in … }
  ```

  Better, pass limits sized for the host — see `RMDocReadLimits`.

### Added

- `RMDocArchive.entries(in:limits:)` (from `Data` or a file `URL`): the
  container's table of contents read from its central directory alone —
  name, method, compressed size, declared size, CRC-32 — as `RMDocEntry`
  values. Nothing is inflated.
- `RMDocArchive.forEachFile(unpacking:limits:where:_:)`: the chooser sees
  every entry before anything is inflated; entries it declines are never
  inflated, checksummed or weighed against the size limits. Choosing nothing
  reads nothing and is not an error.
- `RMDocReadLimits`: caller-supplied ceilings on entry count, each entry's
  declared and compressed size, the declared and compressed totals of a
  read, and the compression ratio past a size threshold. The size limits are
  checked over the chosen entries together, before the first is inflated.
  `maximumEntryCount` is the exception: it bounds the directory walk, so it
  counts every entry of the archive, chosen or not — an archive over the
  count is refused even when the chooser would take nothing. Presets:
  `.default` and `.format`.
- `RMDocArchive.init(unpacking:limits:)` (from `Data` or a `URL`) and
  `RMDocArchive.forEachFile(unpacking:limits:_:)`.
- `RMDocEntry`: one directory entry, with `isCompressed` and `documentID`.
- `RMDocReadError`: refusals for exceeded limits (`tooManyEntries`,
  `entryTooLarge`, `totalSizeExceeded`, `compressedEntryTooLarge`,
  `compressedTotalSizeExceeded`, `compressionRatioExceeded`) and for
  container features this package does not implement (`zip64Unsupported`,
  `encryptedEntry`, `spannedArchive`). A separate type so that no exhaustive
  `switch` over `RMDocError` breaks, and not `@frozen`. Give every `switch`
  over it an `@unknown default`. Against the binary framework (built with
  library evolution) the compiler insists on one, and a case added later
  reaches it at run time instead of breaking the client. Built from source
  without library evolution, an exhaustive `switch` with no
  `@unknown default` compiles — and stops compiling when a case is added.

### Changed

- Deflated entries inflate in place, out of the (mapped) archive, without
  copying the compressed payload, into a buffer that grows with the stream
  and never past the declared size — instead of one pre-allocated at the
  declared size. An entry that would inflate to more than it declared is
  refused after one spare byte rather than inflated further.
- The central directory is read and checked whole before anything is
  inflated, so a structural refusal never comes after some files were handed
  over. Duplicate and hostile names are refused while listing.
- Data descriptors (general-purpose flag bit 3) are accepted when both
  headers set the flag and the descriptor, signed or not, agrees with the
  central directory; they are still never written.

### Security

- Local headers are held to the central directory: name, method,
  encryption, the data-descriptor flag, CRC-32 and both sizes must agree (or
  be deferred to a matching data descriptor).
- Entries whose bytes overlap are refused, which defeats the
  overlapping-entry ("non-recursive") zip bomb.
- A central directory holding more records than its end record counts is
  refused, so two readers cannot disagree about what an archive holds.
- Every central-directory record is bounds-checked whole — name, extra
  field, comment — and extra-field blocks must fit their field; no payload
  may run into the central directory.
- A compressed payload's size is bounded by the caller
  (`maximumCompressedEntrySize`, `maximumCompressedTotalSize`): a valid
  deflate stream can be gigabytes of empty blocks that declare and inflate
  to nothing.
- ZIP64 (a locator after the central directory, or an extra-field block),
  encryption and multi-disk archives are refused by name instead of being
  misread. The locator's signature inside a record's comment is not
  mistaken for ZIP64.
