# Configuration Reference

All behaviour of a **filesystem_raid** array is controlled through a single
`RaidConfig` object that is passed to `FilesystemRaid` (or
`FilesystemRaidBuilder`) at construction time.

---

## Table of Contents

1. [RaidConfig constructor](#raidconfig-constructor)
2. [Field reference](#field-reference)
   - [type](#type)
   - [diskCount](#diskcount)
   - [enableCompression](#enablecompression)
   - [enableEncryption / encryptionKey](#enableencryption--encryptionkey)
   - [chunkSize](#chunksize)
   - [healthCheckInterval](#healthcheckinterval)
   - [parityAlgorithm](#parityalgorithm)
   - [maxRetries](#maxretries)
   - [writeVerification](#writeverification)
   - [logLevel](#loglevel)
3. [Derived read-only properties](#derived-read-only-properties)
4. [FilesystemRaidBuilder equivalents](#filesystemraidbuilder-equivalents)
5. [Common presets](#common-presets)

---

## RaidConfig constructor

```dart
const RaidConfig({
  required RaidType type,
  required int diskCount,
  bool enableCompression       = false,
  bool enableEncryption        = false,
  List<int>? encryptionKey,
  int chunkSize                = 4 * 1024 * 1024,  // 4 MiB
  Duration healthCheckInterval = const Duration(hours: 24),
  ParityAlgorithm parityAlgorithm = ParityAlgorithm.xor,
  int maxRetries               = 3,
  bool writeVerification       = true,
  RaidLogLevel logLevel        = RaidLogLevel.info,
})
```

`RaidConfig` is **`@immutable`** — create a new instance if you need
different settings.

---

## Field reference

### `type`

```dart
final RaidType type;
```

The RAID level. Choose from:

| Value | Description |
|-------|-------------|
| `RaidType.raid0` | Striping — speed, zero redundancy |
| `RaidType.raid1` | Mirroring — maximum redundancy |
| `RaidType.raid5` | Striping with distributed parity — balanced |

**Constraint**: `type == RaidType.raid5` requires `diskCount >= 3`.

---

### `diskCount`

```dart
final int diskCount;
```

The number of physical (or virtual) disk directories in the array.
**Must equal** the length of the `diskPaths` list passed to `FilesystemRaid`.

Minimum: `2` for RAID 0/1, `3` for RAID 5.

---

### `enableCompression`

```dart
final bool enableCompression; // default: false
```

When `true`, each chunk is DEFLATE-compressed with `archive`'s `ZLibEncoder`
before being written to disk. The library automatically skips compression
when the compressed form would be larger than the original (incompressible
data such as already-compressed media files).

**Trade-off**: CPU time vs. I/O bandwidth and disk space.

---

### `enableEncryption` / `encryptionKey`

```dart
final bool enableEncryption;   // default: false
final List<int>? encryptionKey; // required when enableEncryption == true
```

When `true`, each chunk is encrypted with **AES-256-CBC** using a random
per-chunk 16-byte IV (prepended to the ciphertext).

`encryptionKey` must be exactly **32 bytes**.

```dart
// Generate a random key (store it securely — losing it = losing all data).
import 'dart:math';
final rng = Random.secure();
final key = List.generate(32, (_) => rng.nextInt(256));

const config = RaidConfig(
  type: RaidType.raid5,
  diskCount: 3,
  enableEncryption: true,
  encryptionKey: key,
);
```

> **Warning** — Encryption is applied **after** compression (compressed data
> is not compressible, so the order matters).

---

### `chunkSize`

```dart
final int chunkSize; // default: 4 * 1024 * 1024  (4 MiB)
```

Maximum byte size of each stripe unit.

- Larger values → fewer metadata files, better throughput for large sequential
  writes.
- Smaller values → finer-grained parallelism and lower memory usage per chunk.

Typical values: `256 KiB` – `16 MiB`.

---

### `healthCheckInterval`

```dart
final Duration healthCheckInterval; // default: Duration(hours: 24)
```

How often the background timer re-probes all disk directories and logs a
warning when a failed disk is detected.

Set to `Duration.zero` to **disable** the background timer (useful in tests).

---

### `parityAlgorithm`

```dart
final ParityAlgorithm parityAlgorithm; // default: ParityAlgorithm.xor
```

Only relevant when `type == RaidType.raid5`. Choose from:

| Value | Description | Tolerates |
|-------|-------------|-----------|
| `ParityAlgorithm.xor` | Simple XOR — very fast | Exactly 1 disk failure |
| `ParityAlgorithm.reedSolomon` | GF(2^8) Reed-Solomon — stronger | 1 disk failure (currently 1 parity shard) |

---

### `maxRetries`

```dart
final int maxRetries; // default: 3
```

Number of automatic write retries on transient I/O errors before propagating
the exception. Each retry is delayed by `100 ms × attempt`.

---

### `writeVerification`

```dart
final bool writeVerification; // default: true
```

When `true`, every chunk is re-read from disk immediately after writing and
its SHA-256 digest is compared against the stored value.  Corrupt writes
throw `CorruptedDataException`.

**Trade-off**: Doubles disk I/O for writes.  Set to `false` in
high-throughput scenarios where you trust your hardware.

---

### `logLevel`

```dart
final RaidLogLevel logLevel; // default: RaidLogLevel.info
```

Controls the verbosity of the internal `RaidLogger`.

| Level | What is logged |
|-------|---------------|
| `RaidLogLevel.none` | Nothing |
| `RaidLogLevel.error` | Fatal errors only |
| `RaidLogLevel.warning` | Errors + warnings |
| `RaidLogLevel.info` | Normal operation messages *(default)* |
| `RaidLogLevel.debug` | Verbose per-chunk and per-operation messages |

To also print to the console attach the handler once at startup:

```dart
RaidLogger.attachConsole();
```

---

## Derived read-only properties

| Property | Type | Description |
|----------|------|-------------|
| `faultTolerance` | `int` | Number of disks that can fail without data loss |
| `storageEfficiency` | `double` | Fraction of total disk space available for data |

```dart
final config = RaidConfig(type: RaidType.raid5, diskCount: 4);
print(config.faultTolerance);     // 1
print(config.storageEfficiency);  // 0.75  (75 %)
```

---

## FilesystemRaidBuilder equivalents

The fluent builder exposes the same options as method calls:

```dart
final raid = FilesystemRaidBuilder()
    .disks(['/data/d0', '/data/d1', '/data/d2'])
    .type(RaidType.raid5)
    .compress()                           // enableCompression = true
    .encrypt(myKey32)                     // enableEncryption = true
    .chunkSize(8 * 1024 * 1024)          // 8 MiB chunks
    .healthInterval(Duration(hours: 6))
    .parity(ParityAlgorithm.reedSolomon)
    .retries(5)
    .skipVerification()                   // writeVerification = false
    .logLevel(RaidLogLevel.debug)
    .build();
```

---

## Common presets

### High-throughput scratch space (RAID 0)

```dart
const RaidConfig(
  type: RaidType.raid0,
  diskCount: 4,
  enableCompression: false,
  writeVerification: false,
  healthCheckInterval: Duration.zero,
  logLevel: RaidLogLevel.warning,
)
```

### Reliable OS-mirror (RAID 1)

```dart
const RaidConfig(
  type: RaidType.raid1,
  diskCount: 2,
  writeVerification: true,
  healthCheckInterval: Duration(hours: 1),
  logLevel: RaidLogLevel.info,
)
```

### NAS with compression (RAID 5)

```dart
const RaidConfig(
  type: RaidType.raid5,
  diskCount: 3,
  enableCompression: true,
  parityAlgorithm: ParityAlgorithm.xor,
  chunkSize: 4 * 1024 * 1024,
  healthCheckInterval: Duration(hours: 24),
  writeVerification: true,
  logLevel: RaidLogLevel.info,
)
```

### Encrypted secure archive (RAID 5)

```dart
RaidConfig(
  type: RaidType.raid5,
  diskCount: 3,
  enableCompression: true,
  enableEncryption: true,
  encryptionKey: mySecure32ByteKey,
  writeVerification: true,
  logLevel: RaidLogLevel.warning,
)
```
