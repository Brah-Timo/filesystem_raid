# Release Notes & Changelog

Developer-focused notes complementing the top-level `CHANGELOG.md`.

---

## 1.0.0 (2026-05-31)

### New features

- **RAID 0** — pure striping across N disks (`RaidType.raid0`).
- **RAID 1** — full mirroring to all disks (`RaidType.raid1`).
- **RAID 5** — distributed parity striping (`RaidType.raid5`).
- **XOR parity** — fast GF(2) XOR for RAID 5 (`ParityAlgorithm.xor`).
- **Reed-Solomon parity** — GF(2^8) codec for stronger error correction
  (`ParityAlgorithm.reedSolomon`).
- **DEFLATE compression** — per-chunk DEFLATE using the `archive` package,
  with a magic-header skip for incompressible data.
- **AES-256-CBC encryption** — per-chunk encryption with random IV using the
  `encrypt` package.
- **SHA-256 checksums** — every chunk is checksummed on write and verified on
  read.
- **Optional write-verification** — re-reads every chunk immediately after
  writing to detect bad writes.
- **Background health monitoring** — configurable `Timer.periodic` probing of
  all disk directories.
- **Fluent builder** — `FilesystemRaidBuilder` for ergonomic configuration.
- **Structured logging** — `RaidLogger` wraps the `logging` package with ANSI
  coloured console output.
- **Comprehensive test suite** — unit tests for parity, compression, splitter,
  disk manager, and all three RAID levels.

### Bug fixes

- Fixed `ZLibEncoder` API call (removed non-existent `level` constructor
  parameter; wrapped result in `Uint8List.fromList()`).
- Fixed `print()` calls in `example/recovery_example.dart` that were missing
  their required positional argument.
- Removed unused imports (`dart:math` in `chunk_handler.dart`,
  `package:collection/collection.dart` in `disk_manager.dart`).
- Removed unused `stat` variable in `disk_manager.dart`.
- Removed unused private methods `div` and `add` in `reed_solomon.dart`.
- Moved factory constructors before non-constructor members in `logger.dart`
  to satisfy `sort_constructors_first` lint rule.
- Sorted `pubspec.yaml` dependencies alphabetically to satisfy
  `sort_pub_dependencies` lint rule.
- Removed `@visibleForTesting` from `simulateDiskFailure` and
  `simulateDiskRestore` — these are legitimately public demo/test helpers.

### Breaking changes

None — this is the initial release.

---

## Upgrade guide

### From pre-release to 1.0.0

No migration required — 1.0.0 is the first stable release.

---

## Known limitations

- **Single parity shard** — the current RAID 5 implementation uses exactly
  one parity shard per stripe, tolerating at most one simultaneous disk
  failure.  Multi-parity RAID 6 is not yet supported.

- **No online resizing** — adding or removing disks from a live array is not
  supported.  Create a new array and migrate data manually.

- **No file metadata** — the library stores raw `Uint8List` data only.
  File timestamps, permissions, and POSIX attributes are not preserved.

- **No partial writes** — writing a file is atomic at the stripe level; there
  is no journaling or crash-recovery for in-flight writes.

- **POSIX disk-space measurement** — `_diskSpace()` in `DiskManager` uses the
  `df` command.  On non-POSIX platforms (Windows) it falls back to reporting
  1 TiB total / 512 GiB free.

---

## Roadmap

| Feature | Priority |
|---------|---------|
| RAID 6 (dual parity) | Medium |
| Online disk addition / removal | Medium |
| Streaming read/write API | Low |
| Windows `df` equivalent | Low |
| Pluggable storage backend interface | Low |
