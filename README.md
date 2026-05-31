# filesystem_raid

[![Pub Version](https://img.shields.io/badge/pub-1.0.0-blue)](https://pub.dev/packages/filesystem_raid)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.0.0-brightgreen)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![Coverage](https://img.shields.io/badge/coverage-95%25-success)](test/)

> **Software RAID 0 / 1 / 5 for Dart — no kernel modules, no special hardware.**

`filesystem_raid` distributes data across ordinary filesystem directories
(one per disk), adds XOR / Reed-Solomon parity, and transparently
reconstructs missing chunks when a disk fails — all in pure Dart.

---

## Table of Contents

1. [Features](#features)
2. [Installation](#installation)
3. [Quick Start](#quick-start)
4. [RAID Levels](#raid-levels)
5. [Configuration Reference](#configuration-reference)
6. [API Reference](#api-reference)
7. [Recovery](#recovery)
8. [Security](#security)
9. [Architecture](#architecture)
10. [Testing](#testing)
11. [Performance Tips](#performance-tips)
12. [Comparison](#comparison)
13. [Contributing](#contributing)

---

## Features

| Feature | Details |
|---------|---------|
| **RAID 0** | Pure striping — max throughput, zero overhead |
| **RAID 1** | Full mirroring — `N-1` disk fault tolerance |
| **RAID 5** | Distributed parity — single-disk fault tolerance, (N-1)/N efficiency |
| **XOR parity** | Fast, standard RAID 5 single-chunk recovery |
| **Reed-Solomon** | GF(2⁸) multi-disk error correction via `ReedSolomonCodec` |
| **DEFLATE compression** | Transparent chunk compression (ZLIB) |
| **AES-256-CBC encryption** | Per-chunk encryption with random IV |
| **SHA-256 checksums** | Integrity verification on every read |
| **Write-back verification** | Optional post-write read-back for paranoid safety |
| **Structured logging** | Levelled ANSI-colour console + `logging` package |
| **Health monitoring** | Periodic background disk probing with latency stats |
| **Fluent builder** | `FilesystemRaidBuilder` for ergonomic configuration |
| **Pure Dart** | Runs on Linux, macOS, Windows — no FFI, no `dart:ffi` |

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  filesystem_raid: ^1.0.0
```

Then run:

```bash
dart pub get
```

---

## Quick Start

```dart
import 'dart:typed_data';
import 'package:filesystem_raid/filesystem_raid.dart';

Future<void> main() async {
  // Enable coloured console output (optional)
  RaidLogger.attachConsole();

  // Create a RAID 5 array across 3 local directories
  final raid = FilesystemRaid(
    diskPaths: ['/mnt/disk1', '/mnt/disk2', '/mnt/disk3'],
    config: const RaidConfig(
      type: RaidType.raid5,
      diskCount: 3,
      enableCompression: true,   // optional DEFLATE
      writeVerification: true,   // re-read every chunk after writing
      logLevel: RaidLogLevel.info,
    ),
  );

  await raid.initialize();

  // Write a file
  final data = await File('backup.tar.gz').readAsBytes();
  await raid.write('backup.tar.gz', data);

  // Read it back (auto-recovers if one disk is missing)
  final restored = await raid.read('backup.tar.gz');

  // Check health
  final statuses = await raid.checkDiskHealth();
  for (final s in statuses) print(s);

  // Rebuild after disk replacement
  final report = await raid.recover();
  print(report.summary());

  await raid.dispose();
}
```

### Fluent Builder

```dart
final raid = FilesystemRaidBuilder()
    .disks(['/mnt/d1', '/mnt/d2', '/mnt/d3'])
    .type(RaidType.raid5)
    .compress()
    .encrypt(myKey32Bytes)              // AES-256
    .chunkSize(8 * 1024 * 1024)        // 8 MiB stripes
    .parity(ParityAlgorithm.reedSolomon)
    .healthInterval(const Duration(hours: 12))
    .retries(5)
    .logLevel(RaidLogLevel.debug)
    .build();
```

---

## RAID Levels

### RAID 0 — Striping

```
Disk 0 │ Disk 1 │ Disk 2
───────┼────────┼───────
 D0   │  D1    │  D2
```

- **Fault tolerance**: 0 (any disk failure = all data lost)
- **Efficiency**: 100 %
- **Best for**: temp files, caches, non-critical high-speed I/O

```dart
RaidConfig(type: RaidType.raid0, diskCount: 3)
```

---

### RAID 1 — Mirroring

```
Disk 0 │ Disk 1 │ Disk 2
───────┼────────┼───────
 Full  │  Full  │  Full   ← same data on every disk
```

- **Fault tolerance**: N-1 disks (all but one may fail)
- **Efficiency**: 1/N  (33 % for 3 disks)
- **Best for**: OS drives, critical small files, maximum redundancy

```dart
RaidConfig(type: RaidType.raid1, diskCount: 3)
```

---

### RAID 5 — Striping with Distributed Parity

```
Stripe│ Disk 0 │ Disk 1 │ Disk 2
──────┼────────┼────────┼───────
  0   │  D0    │  D1    │  P0     ← parity rotates
  1   │  D0    │  P1    │  D1
  2   │  P2    │  D0    │  D1
```

- **Fault tolerance**: 1 disk
- **Efficiency**: (N-1)/N  (67 % for 3 disks, 75 % for 4 disks)
- **Best for**: NAS arrays, home servers, balanced workloads

```dart
RaidConfig(
  type: RaidType.raid5,
  diskCount: 3,
  parityAlgorithm: ParityAlgorithm.xor,  // or reedSolomon
)
```

---

## Configuration Reference

```dart
const config = RaidConfig(
  type: RaidType.raid5,          // raid0 | raid1 | raid5
  diskCount: 3,                  // must match diskPaths.length
  enableCompression: false,      // DEFLATE (default: false)
  enableEncryption: false,       // AES-256-CBC (default: false)
  encryptionKey: null,           // List<int> of length 32 (required if encrypt)
  chunkSize: 4 * 1024 * 1024,   // bytes per stripe (default: 4 MiB)
  healthCheckInterval: Duration(hours: 24), // 0 = disabled
  parityAlgorithm: ParityAlgorithm.xor,    // xor | reedSolomon
  maxRetries: 3,                 // I/O retry count (default: 3)
  writeVerification: true,       // re-read after write (default: true)
  logLevel: RaidLogLevel.info,   // none | error | warning | info | debug
);
```

| Property | Default | Notes |
|---|---|---|
| `type` | — | **required** |
| `diskCount` | — | **required** |
| `chunkSize` | 4 MiB | Increase for large sequential files |
| `enableCompression` | `false` | Best for text, JSON, logs |
| `enableEncryption` | `false` | Requires 32-byte `encryptionKey` |
| `parityAlgorithm` | `xor` | Use `reedSolomon` for stronger recovery |
| `writeVerification` | `true` | Disable for maximum write throughput |
| `maxRetries` | 3 | Helps on flaky / USB disks |

---

## API Reference

### `FilesystemRaid`

```dart
// Lifecycle
await raid.initialize();   // Must call first
await raid.dispose();      // Cancel health timer, release resources

// I/O
await raid.write(filename, Uint8List data);
Uint8List data = await raid.read(filename);
await raid.delete(filename);
Set<String> files = await raid.listFiles();
bool exists = await raid.fileExists(filename);

// Health & stats
List<DiskStatus> statuses = await raid.checkDiskHealth();
StorageInfo info = raid.storageInfo();

// Recovery
RecoveryReport report = await raid.recover();
print(report.summary());

// Testing helpers
raid.simulateDiskFailure(int diskIndex);
await raid.simulateDiskRestore(int diskIndex);
```

### `RecoveryReport`

```dart
report.status             // success | partial | notRequired | failed
report.isFullySuccessful  // bool
report.recoveredDiskIndexes  // List<int>
report.failedDiskIndexes     // List<int>
report.recoveredFiles        // List<RecoveredFile>
report.totalBytesRecovered   // int
report.duration              // Duration
report.successRate           // double (0–100 %)
report.summary()             // formatted multi-line string
```

### `DiskStatus`

```dart
status.health               // healthy | degraded | failed | unknown
status.isFailed             // bool
status.isReadable           // bool
status.utilizationPercentage  // double
status.readLatencyMs        // double?
status.writeLatencyMs       // double?
```

---

## Recovery

### Automatic (transparent)

When a disk is failed or a chunk is missing, `raid.read()` automatically
reconstructs the data using parity — no code change required.

```dart
// Disk 1 dies — reads still work transparently:
raid.simulateDiskFailure(1);
final data = await raid.read('important.db'); // ✓ recovered via parity
```

### Manual (after disk replacement)

After replacing a failed disk, call `recover()` to rebuild:

```dart
await raid.simulateDiskRestore(1);   // or: mark the new physical disk ready
final report = await raid.recover();
print(report.summary());
// ═══════════════════════════════════════
//   RAID Recovery Report
// ═══════════════════════════════════════
//   Status   : RecoveryStatus.success
//   Duration : 4s
//   Disks OK : 1
//   Disks KO : 0
//   Files    : 3
//   Bytes    : 12.50 MiB
//   Success% : 100.0%
// ═══════════════════════════════════════
```

---

## Security

### Encryption

Enable per-chunk AES-256-CBC with a random 16-byte IV:

```dart
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

// Derive a 32-byte key from a passphrase (example using SHA-256):
final key = sha256.convert(utf8.encode('my-passphrase')).bytes;

final raid = FilesystemRaidBuilder()
    .disks(diskPaths)
    .type(RaidType.raid5)
    .encrypt(key)    // AES-256-CBC, IV per chunk
    .build();
```

### Checksums

Every chunk is SHA-256 hashed before writing.  On read, the checksum is
re-computed and compared.  Mismatches raise `CorruptedDataException`.

---

## Architecture

```
filesystem_raid/
├── lib/
│   ├── filesystem_raid.dart        ← public barrel export
│   ├── src/
│   │   ├── raid_manager.dart       ← FilesystemRaid + FilesystemRaidBuilder
│   │   ├── raid_types/
│   │   │   ├── raid_strategy.dart  ← RaidStrategy interface
│   │   │   ├── raid_0.dart         ← RAID 0 implementation
│   │   │   ├── raid_1.dart         ← RAID 1 implementation
│   │   │   └── raid_5.dart         ← RAID 5 implementation
│   │   ├── storage/
│   │   │   ├── disk_manager.dart   ← low-level I/O, health probing
│   │   │   ├── chunk_handler.dart  ← compress/encrypt/checksum pipeline
│   │   │   └── storage_info.dart   ← aggregate capacity stats
│   │   ├── parity/
│   │   │   ├── parity_calculator.dart  ← XOR parity + stripe recovery
│   │   │   ├── reed_solomon.dart       ← GF(2⁸) RS codec
│   │   │   └── parity_recovery.dart    ← high-level recovery coordinator
│   │   ├── utils/
│   │   │   ├── chunk_splitter.dart ← split / merge / pad
│   │   │   ├── file_hasher.dart    ← SHA-256, MD5, constant-time compare
│   │   │   ├── compression.dart    ← DEFLATE with magic header
│   │   │   └── logger.dart         ← RaidLogger + OperationLogger
│   │   └── exceptions/
│   │       └── raid_exceptions.dart ← typed exception hierarchy
│   └── models/
│       ├── raid_config.dart        ← RaidConfig, RaidType, ParityAlgorithm
│       ├── disk_status.dart        ← DiskStatus, DiskHealth
│       ├── chunk_metadata.dart     ← per-chunk JSON metadata
│       └── recovery_report.dart    ← RecoveryReport, RecoveredFile
├── test/
│   ├── parity_test.dart
│   ├── reed_solomon_test.dart
│   ├── chunk_splitter_test.dart
│   ├── disk_manager_test.dart
│   ├── raid_0_test.dart
│   ├── raid_1_test.dart
│   ├── raid_5_test.dart
│   └── integration_test.dart
└── example/
    ├── basic_usage.dart
    ├── nas_setup.dart
    └── recovery_example.dart
```

### Write Path

```
caller.write(filename, data)
  └─ FilesystemRaid.write()
       └─ RaidStrategy.write()  [Raid0 / Raid1 / Raid5]
            ├─ ChunkSplitter.split(data, diskCount)
            ├─ ParityRecovery.computeParity(chunks)      ← RAID 5 only
            └─ DiskManager.writeChunk() × N  [parallel]
                  └─ ChunkHandler.encode(raw)
                        ├─ RaidCompression.compress()    ← if enabled
                        ├─ ChunkHandler.encryptChunk()   ← if enabled
                        ├─ FileHasher.sha256Hex()
                        └─ File.writeAsBytes()
```

### Read Path (with recovery)

```
caller.read(filename)
  └─ FilesystemRaid.read()
       └─ RaidStrategy.read()
            ├─ DiskManager.readChunk() × N  [parallel]
            │     └─ ChunkHandler.decode(payload, checksum, …)
            ├─ [RAID 5] ParityRecovery.recoverChunks()  ← if any null
            └─ ChunkSplitter.merge(chunks, originalLength)
```

---

## Testing

```bash
# Run all tests
dart test

# Run with coverage
dart pub global activate coverage
dart test --coverage=coverage/
dart pub global run coverage:format_coverage \
    --lcov --in=coverage --out=coverage/lcov.info --packages=.dart_tool/package_config.json
```

---

## Performance Tips

| Tip | Effect |
|-----|--------|
| Increase `chunkSize` to 8–16 MiB for large sequential files | ↑ throughput |
| Set `writeVerification: false` for batch imports | ↑ write speed |
| Use RAID 0 for temporary scratch space | Maximum speed |
| Enable compression for text/JSON/log workloads | ↓ disk usage |
| Use 4+ disks with RAID 5 for better parallelism | ↑ throughput |
| Use SSDs for the parity disk | ↓ write latency |

---

## Comparison

| Feature | **filesystem_raid** | ZFS | Btrfs | RAID HW card |
|---------|---------------------|-----|-------|--------------|
| Cost | Free (MIT) | Free | Free | $100–$1,000+ |
| Platform | Any Dart platform | Linux/macOS | Linux | Vendor-locked |
| RAID 5 | ✅ | ✅ | ✅ | ✅ |
| Reed-Solomon | ✅ | ✅ | ✗ | ✅ (some) |
| Encryption | ✅ (AES-256) | ✅ | ✅ | ✅ (some) |
| Compression | ✅ (DEFLATE) | ✅ (LZ4/gzip) | ✅ (zstd) | ✗ |
| Install complexity | Minimal | High | Moderate | High (driver) |
| Dart integration | Native | FFI/subprocess | FFI/subprocess | FFI/subprocess |
| Hot spare | Roadmap | ✅ | ✅ | ✅ |
| RAID 6 | Roadmap | ✅ | ✅ | ✅ |

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Write tests for new behaviour
4. Ensure `dart test` passes
5. Open a pull request

Please follow the [Dart style guide](https://dart.dev/guides/language/effective-dart/style)
and document all public APIs with `///` doc comments.

---

## License

[MIT](LICENSE) © 2026 filesystem_raid contributors
