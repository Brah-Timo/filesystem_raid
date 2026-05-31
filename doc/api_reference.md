# API Reference

Complete reference for every public class, enum, and method in the
**filesystem_raid** package.

---

## Table of Contents

1. [FilesystemRaid](#filesystemraid)
2. [FilesystemRaidBuilder](#filesystemraidbuilder)
3. [RaidConfig](#raidconfig)
4. [RaidType](#raidtype)
5. [ParityAlgorithm](#parityalgorithm)
6. [RaidLogLevel](#raidloglevel)
7. [DiskStatus](#diskstatus)
8. [DiskHealth](#diskhealth)
9. [StorageInfo](#storageinfo)
10. [ChunkMetadata](#chunkmetadata)
11. [RecoveryReport](#recoveryreport)
12. [RecoveryStatus](#recoverystatus)
13. [RecoveredFile](#recoveredfile)
14. [ParityCalculator](#paritycalculator)
15. [ReedSolomonCodec](#reedsolomoncodec)
16. [ParityRecovery](#parityrecovery)
17. [RaidCompression](#raidcompression)
18. [CompressionResult](#compressionresult)
19. [FileHasher](#filehasher)
20. [ChunkSplitter](#chunksplitter)
21. [RaidLogger](#raidlogger)
22. [OperationLogger](#operationlogger)
23. [Exceptions](#exceptions)

---

## FilesystemRaid

Top-level entry point. Manages an entire RAID array.

```dart
class FilesystemRaid
```

### Constructor

```dart
FilesystemRaid({
  required List<String> diskPaths,
  required RaidConfig config,
})
```

Throws `RaidConfigurationException` if `diskPaths.length != config.diskCount`
or if RAID 5 has fewer than 3 disks.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `config` | `RaidConfig` | The configuration this instance was built with |
| `diskPaths` | `List<String>` | Ordered list of disk root paths |
| `diskCount` | `int` | Number of disks |
| `isInitialised` | `bool` | `true` after `initialize()` succeeds |

### Methods

#### `initialize()`
```dart
Future<void> initialize()
```
Creates disk directories (if missing), scans health, builds the RAID
strategy, and starts the background health timer.
Must be called **once** before any other method.

#### `write()`
```dart
Future<void> write(String filename, Uint8List data)
```
Writes `data` as logical file `filename` into the array.
Idempotent — writing the same name again overwrites the previous version.

#### `read()`
```dart
Future<Uint8List> read(String filename)
```
Reads `filename` back. Transparently reconstructs data from parity when a
disk has failed (RAID 5 / RAID 1).
Throws `RaidFileNotFoundException` if the file does not exist.

#### `delete()`
```dart
Future<void> delete(String filename)
```
Removes all on-disk chunks for `filename` from every disk.

#### `listFiles()`
```dart
Future<Set<String>> listFiles()
```
Returns the set of all logical filenames stored in the array.

#### `fileExists()`
```dart
Future<bool> fileExists(String filename)
```
Returns `true` when `filename` exists in the array.

#### `checkDiskHealth()`
```dart
Future<List<DiskStatus>> checkDiskHealth()
```
Re-probes every disk and returns fresh `DiskStatus` snapshots.

#### `storageInfo()`
```dart
StorageInfo storageInfo()
```
Returns aggregated capacity statistics (synchronous — uses cached disk data).

#### `recover()`
```dart
Future<RecoveryReport> recover()
```
Scans for failed disks and attempts to rebuild them.
- **RAID 0** — throws `RaidNotRecoverableException`.
- **RAID 1** — copies data from any healthy mirror.
- **RAID 5** — reconstructs missing chunks using XOR / Reed-Solomon parity.

#### `simulateDiskFailure()`
```dart
void simulateDiskFailure(int index)
```
Marks disk `index` as failed without touching the filesystem.
Useful for testing and demo scenarios.

#### `simulateDiskRestore()`
```dart
Future<void> simulateDiskRestore(int index)
```
Re-probes disk `index` and marks it healthy.
Call before `recover()` to simulate a disk replacement.

#### `dispose()`
```dart
Future<void> dispose()
```
Cancels the background health timer and resets internal state.

---

## FilesystemRaidBuilder

Fluent builder for `FilesystemRaid`.

```dart
class FilesystemRaidBuilder
```

### Methods (all return `this`)

| Method | Equivalent RaidConfig field |
|--------|-----------------------------|
| `disks(List<String> paths)` | `diskPaths`, `diskCount` |
| `type(RaidType t)` | `type` |
| `compress({bool enabled = true})` | `enableCompression` |
| `encrypt(List<int> key)` | `enableEncryption`, `encryptionKey` |
| `chunkSize(int bytes)` | `chunkSize` |
| `healthInterval(Duration d)` | `healthCheckInterval` |
| `parity(ParityAlgorithm algo)` | `parityAlgorithm` |
| `retries(int n)` | `maxRetries` |
| `skipVerification()` | `writeVerification = false` |
| `logLevel(RaidLogLevel l)` | `logLevel` |

#### `build()`
```dart
FilesystemRaid build()
```
Creates and returns the `FilesystemRaid` instance.
Throws `ArgumentError` if `disks()` was not called.

---

## RaidConfig

Immutable configuration for a `FilesystemRaid` instance.
See [Configuration Reference](configuration.md) for full details.

```dart
@immutable
class RaidConfig {
  const RaidConfig({required type, required diskCount, …})
}
```

---

## RaidType

```dart
enum RaidType { raid0, raid1, raid5 }
```

---

## ParityAlgorithm

```dart
enum ParityAlgorithm { xor, reedSolomon }
```

---

## RaidLogLevel

```dart
enum RaidLogLevel { none, error, warning, info, debug }
```

---

## DiskStatus

An immutable snapshot of one disk's state at a point in time.

```dart
@immutable
class DiskStatus { … }
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `path` | `String` | Directory path of this disk |
| `diskIndex` | `int` | Zero-based index in the array |
| `health` | `DiskHealth` | Current health classification |
| `totalBytes` | `int` | Total disk capacity |
| `availableBytes` | `int` | Free disk capacity |
| `usedBytes` | `int` | `totalBytes - availableBytes` |
| `utilizationFraction` | `double` | 0.0 – 1.0 |
| `utilizationPercentage` | `double` | 0 – 100 |
| `readLatencyMs` | `double?` | Measured read latency (ms) |
| `writeLatencyMs` | `double?` | Measured write latency (ms) |
| `lastChecked` | `DateTime` | Timestamp of last probe |
| `errorLogs` | `List<String>` | Recent I/O error messages |
| `isFailed` | `bool` | `health == DiskHealth.failed` |
| `isReadable` | `bool` | `healthy` or `degraded` |

---

## DiskHealth

```dart
enum DiskHealth { healthy, degraded, failed, unknown }
```

---

## StorageInfo

Aggregated capacity statistics across the whole array.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `raidType` | `RaidType` | Array level |
| `diskCount` | `int` | Total configured disks |
| `activeDiskCount` | `int` | Healthy + degraded |
| `failedDiskCount` | `int` | Failed disks |
| `totalRawBytes` | `int` | Sum of all disk totals |
| `availableRawBytes` | `int` | Sum of all disk free |
| `usableBytes` | `int` | Effective capacity (after RAID efficiency) |
| `availableUsableBytes` | `int` | Effective free space |
| `usedUsableBytes` | `int` | `usableBytes - availableUsableBytes` |
| `utilizationFraction` | `double` | 0.0 – 1.0 |
| `utilizationPercentage` | `double` | 0 – 100 |
| `isDegraded` | `bool` | At least one disk failed |

---

## ChunkMetadata

Persisted alongside every `.raid` chunk file as a companion `.raid.meta` JSON.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `filename` | `String` | Logical filename |
| `chunkIndex` | `int` | Zero-based index within the stripe |
| `totalChunks` | `int` | Total data chunks (excludes parity) |
| `diskIndex` | `int` | Physical disk index |
| `originalSize` | `int` | Un-padded byte length of raw chunk data |
| `checksum` | `String` | SHA-256 hex of the stored payload |
| `isParityChunk` | `bool` | `true` for parity chunks |
| `compressed` | `bool` | Was DEFLATE applied? |
| `encrypted` | `bool` | Was AES-256 applied? |
| `raidType` | `String` | e.g. `'raid5'` |
| `createdAt` | `DateTime` | First write timestamp |

---

## RecoveryReport

Report returned by `FilesystemRaid.recover()`.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `startedAt` | `DateTime` | Recovery start time |
| `completedAt` | `DateTime?` | Recovery end time |
| `status` | `RecoveryStatus` | High-level outcome |
| `recoveredDiskIndexes` | `List<int>` | Disks successfully rebuilt |
| `failedDiskIndexes` | `List<int>` | Disks that could not be rebuilt |
| `recoveredFiles` | `List<RecoveredFile>` | Per-file recovery details |
| `errors` | `Map<String, String>` | Error messages keyed by `disk_N` or `file_<name>` |
| `duration` | `Duration` | Elapsed recovery time |
| `isFullySuccessful` | `bool` | `status == RecoveryStatus.success` |
| `hasAnyRecovery` | `bool` | At least one disk was rebuilt |
| `totalBytesRecovered` | `int` | Sum of bytes written during rebuild |
| `successRate` | `double` | Percentage of recovered disks |

#### `summary()`
```dart
String summary()
```
Returns a formatted multi-line summary string suitable for printing.

---

## RecoveryStatus

```dart
enum RecoveryStatus { success, partial, notRequired, failed }
```

---

## RecoveredFile

Immutable detail record for one file recovered during a rebuild.

| Property | Type | Description |
|----------|------|-------------|
| `filename` | `String` | Logical filename |
| `fromDiskIndex` | `int` | Source (donor) disk |
| `toDiskIndex` | `int` | Destination (rebuilt) disk |
| `bytesRecovered` | `int` | Bytes written |
| `verified` | `bool` | Passed write-verification checksum |

---

## ParityCalculator

XOR-based parity over GF(2) — exposed for advanced usage.

```dart
@immutable
class ParityCalculator { const ParityCalculator(); }
```

### Methods

#### `calculate(chunks)`
```dart
Uint8List calculate(List<Uint8List> chunks)
```
XOR all `chunks` byte-by-byte (zero-padded to equal length). Returns parity.

#### `verify(dataChunks, storedParity)`
```dart
bool verify(List<Uint8List> dataChunks, Uint8List storedParity)
```
Returns `true` when `calculate(dataChunks) == storedParity`.

#### `recoverSingleChunk(availableChunks, parity)`
```dart
Uint8List recoverSingleChunk({
  required List<Uint8List> availableChunks,
  required Uint8List parity,
})
```
Recovers the single missing chunk from all known chunks + parity.

#### `recoverStripe(chunks, parity)`
```dart
List<Uint8List> recoverStripe({
  required List<Uint8List?> chunks,
  required Uint8List parity,
})
```
Rebuilds a full stripe where at most one entry in `chunks` is `null`.
Throws `TooManyDiskFailuresException` if more than one is missing.

#### `static parityDiskIndex(stripeIndex, diskCount)`
```dart
static int parityDiskIndex(int stripeIndex, int diskCount)
```
Returns the disk index that holds the parity block for a given stripe
(left-symmetric rotation).

---

## ReedSolomonCodec

Systematic Reed-Solomon codec over GF(2^8).

```dart
class ReedSolomonCodec {
  ReedSolomonCodec({required int dataCount, required int parityCount});
}
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `dataCount` | `int` | Number of data shards |
| `parityCount` | `int` | Number of parity shards |
| `totalCount` | `int` | `dataCount + parityCount` |

### Methods

#### `encode(dataShards)`
```dart
List<Uint8List> encode(List<Uint8List> dataShards)
```
Returns `totalCount` shards. The first `dataCount` are identical to input
(systematic code).

#### `decode(shards)`
```dart
List<Uint8List> decode(List<Uint8List?> shards)
```
Recovers missing shards (null entries). Requires at least `dataCount`
non-null shards.
Throws `TooManyDiskFailuresException` if fewer shards are present.

---

## ParityRecovery

High-level parity coordinator that selects XOR or Reed-Solomon.

```dart
@immutable
class ParityRecovery { const ParityRecovery({required RaidConfig config}); }
```

### Methods

#### `recoverChunks(chunks, parity)`
```dart
List<Uint8List> recoverChunks({
  required List<Uint8List?> chunks,
  required Uint8List parity,
})
```
Recovers missing chunks using the configured algorithm.

#### `computeParity(dataChunks)`
```dart
Uint8List computeParity(List<Uint8List> dataChunks)
```
Computes the parity block from `dataChunks`.

#### `verifyParity(dataChunks, storedParity)`
```dart
bool verifyParity(List<Uint8List> dataChunks, Uint8List storedParity)
```

---

## RaidCompression

DEFLATE-based compression for chunk payloads.

```dart
class RaidCompression { const RaidCompression._(); }
```

### Static methods

#### `compress(data, {int level = 6})`
```dart
static CompressionResult compress(Uint8List data, {int level = 6})
```
Compresses `data`. Returns original unmodified if compressed form is larger.
Prepends a 4-byte magic header `52 41 5A 43` ("RAZC").

#### `decompress(data)`
```dart
static Uint8List decompress(Uint8List data)
```
Decompresses if the magic header is present; otherwise returns `data`
unchanged.

#### `isCompressed(data)`
```dart
static bool isCompressed(Uint8List data)
```
Returns `true` when `data` starts with the RAZC magic bytes.

---

## CompressionResult

```dart
@immutable
class CompressionResult {
  final Uint8List data;
  final int originalSize;
  final int compressedSize;
  double get ratio;         // compressedSize / originalSize
  double get savedPercent;  // (1 - ratio) * 100
}
```

---

## FileHasher

SHA-256 / MD5 hashing utilities.

```dart
class FileHasher { const FileHasher._(); }
```

### Static methods

| Method | Returns | Description |
|--------|---------|-------------|
| `sha256Hex(data)` | `String` | 64-char lowercase hex |
| `md5Hex(data)` | `String` | 32-char lowercase hex |
| `sha256Bytes(data)` | `Uint8List` | Raw 32-byte digest |
| `sha256HexOfFile(path)` | `Future<String>` | Streaming file hash |
| `constantTimeEquals(a, b)` | `bool` | Constant-time string compare |
| `verify(data, expectedHex)` | `bool` | Hash and compare |
| `hexToBytes(hex)` | `Uint8List` | Hex string → bytes |
| `bytesToHex(bytes)` | `String` | Bytes → hex string |

---

## ChunkSplitter

Byte-buffer splitting and merging utilities.

```dart
class ChunkSplitter { const ChunkSplitter._(); }
```

### Static methods

| Method | Description |
|--------|-------------|
| `split(data, diskCount)` | Split into exactly `diskCount` equal chunks |
| `splitBySize(data, chunkSize, {targetCount})` | Split by max size |
| `merge(chunks, {originalLength})` | Concatenate and optionally trim |
| `zeroPad(chunk, targetLength)` | Right-pad with zeros |
| `equaliseLength(chunks)` | Pad all chunks to the longest |
| `areEqualLength(chunks)` | Returns `true` when all same length |
| `totalBytes(chunks)` | Sum of all chunk lengths |

---

## RaidLogger

Thin wrapper around the `logging` package.

```dart
class RaidLogger {
  RaidLogger(RaidLogLevel level);
  factory RaidLogger.info();
  factory RaidLogger.debug();
  factory RaidLogger.silent();
}
```

### Static methods

#### `attachConsole()`
```dart
static void attachConsole()
```
Registers a coloured ANSI console listener on `Logger.root.onRecord`.
Call once at application startup.

### Instance methods

| Method | Level mapped |
|--------|-------------|
| `debug(message, [error, stackTrace])` | `Level.FINE` |
| `info(message, [error, stackTrace])` | `Level.INFO` |
| `warning(message, [error, stackTrace])` | `Level.WARNING` |
| `error(message, [error, stackTrace])` | `Level.SEVERE` |

---

## OperationLogger

Scoped timing helper.

```dart
@immutable
class OperationLogger {
  OperationLogger(RaidLogger log, String operationName);
  void done({String? extra});
  void failed(Object error);
}
```

---

## Exceptions

All exceptions extend `RaidException` which implements `Exception`.

```dart
abstract class RaidException implements Exception {
  final String message;
  final Object? cause;
}
```

| Class | When thrown |
|-------|-------------|
| `RaidConfigurationException` | Invalid `RaidConfig` or constructor args |
| `DiskFailedException` | I/O attempted on a failed disk |
| `ChunkNotFoundException` | Expected chunk file not found |
| `RaidFileNotFoundException` | `read()` called for a file not in the array |
| `InsufficientSpaceException` | Not enough free space on a disk |
| `CorruptedDataException` | SHA-256 mismatch on read or write-verify |
| `RaidNotRecoverableException` | `recover()` called on RAID 0 |
| `TooManyDiskFailuresException` | More failures than the level can tolerate |
| `RaidRecoveryException` | Recovery logic reached an unrecoverable state |
| `MetadataException` | Chunk metadata missing or malformed |
| `ParityException` | Parity calculation in an invalid state |
