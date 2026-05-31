# Compression & Encryption

This guide explains how **filesystem_raid** optionally compresses and encrypts
chunk data before writing it to disk, and how to configure both features safely.

---

## Table of Contents

1. [Overview](#overview)
2. [Compression](#compression)
   - [How it works](#how-it-works-compression)
   - [Enabling compression](#enabling-compression)
   - [When not to use compression](#when-not-to-use-compression)
   - [Checking results](#checking-results)
3. [Encryption](#encryption)
   - [How it works](#how-it-works-encryption)
   - [Enabling encryption](#enabling-encryption)
   - [Key management](#key-management)
   - [Rotating keys](#rotating-keys)
4. [Using both together](#using-both-together)
5. [Internal API details](#internal-api-details)

---

## Overview

Both features are applied **per chunk** in the following pipeline:

```
raw bytes  →  [DEFLATE compress]  →  [AES-256-CBC encrypt]  →  disk
```

The reverse pipeline is applied on read:

```
disk  →  [AES-256-CBC decrypt]  →  [DEFLATE decompress]  →  raw bytes
```

Each chunk carries a `ChunkMetadata` record (`compressed: bool`,
`encrypted: bool`) so the read path knows exactly which operations to reverse.

---

## Compression

### How it works (compression)

**filesystem_raid** uses the `archive` package's `ZLibEncoder` (DEFLATE)
to compress chunks before writing.

A 4-byte magic header `52 41 5A 43` ("RAZC") is prepended to every
compressed payload so the reader can detect whether a chunk is compressed
even without consulting metadata.

If the compressed payload is **equal to or larger** than the original data,
the library skips compression and writes the original bytes — this handles
already-compressed media such as JPEG, MP4, or ZIP files gracefully.

### Enabling compression

```dart
const config = RaidConfig(
  type: RaidType.raid5,
  diskCount: 3,
  enableCompression: true,  // ← enable
);
```

Or via the builder:

```dart
final raid = FilesystemRaidBuilder()
    .disks(diskPaths)
    .type(RaidType.raid5)
    .compress()              // enableCompression = true
    .build();
```

### When not to use compression

- **Already-compressed data** (JPEG, MP4, ZIP, GZ, …) — the library detects
  this automatically (compressed output ≥ input size) and skips compression,
  but you can save CPU by keeping `enableCompression: false` for such
  workloads.
- **Latency-sensitive applications** — DEFLATE adds measurable CPU overhead
  on very fast NVMe arrays.
- **Parity correctness** — parity is computed on the **raw** chunks before
  compression, so recovery always works correctly regardless of whether
  chunks were compressed.

### Checking results

Use `CompressionResult` to inspect how much space was saved per chunk:

```dart
import 'package:filesystem_raid/filesystem_raid.dart';

final result = RaidCompression.compress(myData);
print('Saved: ${result.savedPercent.toStringAsFixed(1)}%');
// e.g. "Saved: 68.3%"
```

---

## Encryption

### How it works (encryption)

Each chunk is encrypted with **AES-256-CBC**:

1. A cryptographically random 16-byte **IV** is generated for each chunk.
2. The chunk is encrypted with the supplied 32-byte key and the IV.
3. The IV is prepended to the ciphertext: `[16-byte IV][ciphertext]`.

Using a unique random IV per chunk means that identical plaintext in
different chunks always produces different ciphertext, preventing
block-level deduplication attacks.

The `encrypt` package (`^5.0.3`) provides the AES-256-CBC implementation.

### Enabling encryption

```dart
import 'dart:math';

// Generate a secure random 32-byte key.
final rng = Random.secure();
final key = List<int>.generate(32, (_) => rng.nextInt(256));

final config = RaidConfig(
  type: RaidType.raid5,
  diskCount: 3,
  enableEncryption: true,
  encryptionKey: key,       // must be exactly 32 bytes
);
```

Or with the builder:

```dart
final raid = FilesystemRaidBuilder()
    .disks(diskPaths)
    .type(RaidType.raid5)
    .encrypt(key)            // sets enableEncryption = true
    .build();
```

### Key management

> **Critical** — if you lose the encryption key, **all data is permanently
> unrecoverable**, even if all disks are healthy.

Guidelines:

- Store the key in a secure secret manager (e.g. HashiCorp Vault, AWS
  Secrets Manager, 1Password, or a hardware HSM).
- Never hardcode the key in source code.
- Generate a fresh key per array — do **not** reuse keys across different
  RAID arrays.
- Back up the key separately from the RAID disks.

```dart
// Good: load key from environment variable at runtime.
import 'dart:convert';
import 'dart:io';

final keyHex = Platform.environment['RAID_KEY'] ?? '';
if (keyHex.length != 64) throw Exception('RAID_KEY must be 64 hex chars (32 bytes)');
final key = List<int>.generate(32, (i) => int.parse(keyHex.substring(i * 2, i * 2 + 2), radix: 16));
```

### Rotating keys

Key rotation is not currently supported as a one-step operation.  To rotate:

1. Create a new `FilesystemRaid` instance pointing to **new** disk
   directories with the new key.
2. For each file, `read()` from the old array and `write()` to the new array.
3. Verify all data is correct (`read()` from new array and compare hashes).
4. Delete the old disk directories.

---

## Using both together

Enabling both compression and encryption is the most secure and
space-efficient configuration:

```dart
final config = RaidConfig(
  type: RaidType.raid5,
  diskCount: 3,
  enableCompression: true,  // compress first  (random-looking plaintext
  enableEncryption: true,   // then encrypt     is incompressible anyway)
  encryptionKey: myKey,
);
```

**Order matters** — compression is always applied **before** encryption:

- Encrypted data is essentially random and incompressible.
- Compressing plaintext first, then encrypting, gives the best of both worlds.

---

## Internal API details

### RaidCompression

```dart
class RaidCompression {
  static CompressionResult compress(Uint8List data, {int level = 6});
  static Uint8List decompress(Uint8List data);
  static bool isCompressed(Uint8List data);
}
```

`level` (0–9) maps directly to DEFLATE compression levels:
`0` = no compression, `9` = maximum compression, `6` = default balance.

### ChunkHandler encryption methods

```dart
class ChunkHandler {
  static Uint8List encryptChunk(Uint8List plaintext, List<int> key32);
  static Uint8List decryptChunk(Uint8List ciphertext, List<int> key32);
}
```

These are `static` methods called by `ChunkHandler.encode()` /
`ChunkHandler.decode()`.  They are public for testing purposes.

### On-disk representation

Compressed + encrypted chunk:

```
Bytes 0-3  : RAZC magic (0x52 0x41 0x5A 0x43)
Bytes 4-19 : AES-256-CBC IV (16 bytes random)  ← part of the encrypted blob
Bytes 20+  : AES-256-CBC ciphertext of the DEFLATE-compressed data
```

Wait — actually the pipeline is:

```
raw → compress → [RAZC | deflate_bytes] → encrypt → [IV | ciphertext_of_compressed_payload]
```

So the magic header is *inside* the encrypted envelope.  On read, the
decrypted payload is checked for the RAZC magic before decompression.
