# Architecture Overview

This document describes the internal design of **filesystem_raid**: its layers,
the call flow for every major operation, and the data model used on disk.

---

## Table of Contents

1. [High-level layer diagram](#high-level-layer-diagram)
2. [Layer descriptions](#layer-descriptions)
   - [Public API layer](#public-api-layer)
   - [Strategy layer](#strategy-layer)
   - [Storage layer](#storage-layer)
   - [Parity layer](#parity-layer)
   - [Utility layer](#utility-layer)
3. [Write call flow](#write-call-flow)
4. [Read call flow](#read-call-flow)
5. [Recovery call flow](#recovery-call-flow)
6. [On-disk layout](#on-disk-layout)
7. [Threading / async model](#threading--async-model)
8. [Extension points](#extension-points)

---

## High-level layer diagram

```
┌──────────────────────────────────────────────────────────┐
│                    Public API layer                       │
│           FilesystemRaid  ·  FilesystemRaidBuilder        │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────┐
│                   Strategy layer                          │
│         Raid0   ·   Raid1   ·   Raid5                    │
│         (implements RaidStrategy)                        │
└─────────┬──────────────────────────────┬─────────────────┘
          │                              │
┌─────────▼─────────────┐    ┌──────────▼──────────────────┐
│    Storage layer      │    │      Parity layer            │
│  DiskManager          │    │  ParityCalculator (XOR)      │
│  ChunkHandler         │    │  ReedSolomonCodec (GF(2^8))  │
│  FileRegistry         │    │  ParityRecovery              │
│  StorageInfo          │    └─────────────────────────────-┘
└─────────┬─────────────┘
          │
┌─────────▼─────────────────────────────────────────────────┐
│                   Utility layer                            │
│   ChunkSplitter  ·  RaidCompression  ·  FileHasher        │
│   RaidLogger     ·  OperationLogger                       │
└───────────────────────────────────────────────────────────┘
```

---

## Layer descriptions

### Public API layer

**`FilesystemRaid`** is the single entry point for callers. It:

- Validates constructor arguments.
- Creates a `DiskManager` and a `RaidLogger`.
- Builds the concrete `RaidStrategy` matching `RaidConfig.type`.
- Starts the optional background health-check `Timer`.
- Delegates all I/O through the strategy.

**`FilesystemRaidBuilder`** offers a fluent builder that calls
`FilesystemRaid` internally.

### Strategy layer

Each RAID level is a class that implements `RaidStrategy`:

| Class   | File                    | Behaviour |
|---------|-------------------------|-----------|
| `Raid0` | `raid_types/raid_0.dart` | Splits data evenly across all disks; no parity |
| `Raid1` | `raid_types/raid_1.dart` | Writes entire file to every disk; reads from first healthy |
| `Raid5` | `raid_types/raid_5.dart` | Distributes data + rotating parity across N disks |

All strategies receive shared references to `DiskManager`, `RaidConfig`, and
`RaidLogger` at construction time.

### Storage layer

**`DiskManager`** owns the stateful disk roster:

- Maintains a `List<DiskStatus>` and a `List<FileRegistry>` — one per disk.
- Exposes `writeChunk`, `readChunk`, `rebuildChunk`, `deleteAllChunks`.
- Implements retry logic (`_writeWithRetry`) with exponential back-off.
- Delegates encode/decode pipeline to `ChunkHandler`.

**`ChunkHandler`** is stateless and handles one chunk at a time:

- `encode(raw)` → optional DEFLATE compress → optional AES-256-CBC encrypt →
  SHA-256 checksum → `EncodedChunk`.
- `decode(payload, …)` → checksum verify → optional decrypt → optional
  decompress → raw bytes.
- Reads/writes companion `.meta` JSON files via `readMetadata` /
  `writeMetadata`.

**`FileRegistry`** is a simple `Set<String>` persisted as
`_raid_registry.json` on every disk directory.  `DiskManager` reconciles
registries across disks on startup.

### Parity layer

**`ParityCalculator`** computes XOR parity:

- `calculate(chunks)` — XOR all bytes at each position.
- `recoverStripe(chunks, parity)` — XOR remaining chunks + parity to rebuild
  the missing one.

**`ReedSolomonCodec`** implements systematic Reed-Solomon over GF(2^8):

- Vandermonde encoding matrix, row-reduced to systematic form.
- `encode(dataShards)` → N+K shards.
- `decode(shards)` → recovers up to K missing shards.

**`ParityRecovery`** selects the algorithm based on
`RaidConfig.parityAlgorithm` and provides `computeParity` and
`recoverChunks` to the `Raid5` strategy.

### Utility layer

| Class / Function | Role |
|------------------|------|
| `ChunkSplitter`   | `split` (data → chunks), `merge` (chunks → data), `equaliseLength` |
| `RaidCompression` | DEFLATE compress/decompress using `archive` package; 4-byte magic header |
| `FileHasher`      | SHA-256 hex over `Uint8List` or `File`; constant-time equality |
| `RaidLogger`      | Thin wrapper around `logging`; coloured ANSI console output |
| `OperationLogger` | Scoped timing helper (`done()` / `failed()`) |

---

## Write call flow

```
FilesystemRaid.write(filename, data)
  └─ RaidStrategy.write(filename, data)                [chosen strategy]
       ├─ ChunkSplitter.split(data, n)                 [split into N chunks]
       ├─ ParityRecovery.computeParity(chunks)         [RAID 5 only]
       └─ DiskManager.writeChunk(…) × N               [parallel futures]
            ├─ ChunkHandler.encode(raw)
            │    ├─ RaidCompression.compress(data)     [if enabled]
            │    ├─ ChunkHandler.encryptChunk(data)    [if enabled]
            │    └─ FileHasher.sha256Hex(payload)
            ├─ File.writeAsBytes(payload)
            └─ ChunkHandler.writeMetadata(chunkPath)
```

---

## Read call flow

```
FilesystemRaid.read(filename)
  └─ RaidStrategy.read(filename)
       ├─ DiskManager.readChunk(…) × N               [parallel futures]
       │    ├─ File.readAsBytes(payload)
       │    ├─ ChunkHandler.readMetadata(chunkPath)
       │    └─ ChunkHandler.decode(payload, …)
       │         ├─ FileHasher.verify(payload, checksum)
       │         ├─ ChunkHandler.decryptChunk(data)   [if encrypted]
       │         └─ RaidCompression.decompress(data)  [if compressed]
       ├─ ParityRecovery.recoverChunks(…)             [if any null — RAID 5]
       └─ ChunkSplitter.merge(chunks, originalLength)
```

---

## Recovery call flow

```
FilesystemRaid.recover()
  └─ RaidStrategy.recover()
       ├─ DiskManager.refreshStatus()                 [re-probe all disks]
       ├─ for each failedDisk …
       │    ├─ DiskManager.markDiskOnline(failedDisk)
       │    └─ for each filename …
       │         ├─ DiskManager.readChunk(…) × N      [healthy disks]
       │         ├─ ParityRecovery.recoverChunks(…)   [rebuild missing]
       │         └─ DiskManager.rebuildChunk(…)       [write to restored disk]
       └─ RecoveryReport.finish(status)
```

---

## On-disk layout

Each **disk root directory** contains:

```
<diskRoot>/
├── _raid_registry.json          # FileRegistry — list of logical filenames
├── <sanitised_filename>_chunk0.raid      # data chunk 0
├── <sanitised_filename>_chunk0.raid.meta # ChunkMetadata JSON
├── <sanitised_filename>_chunk1.raid
├── <sanitised_filename>_chunk1.raid.meta
└── <sanitised_filename>_parity.raid      # parity chunk (RAID 5)
    <sanitised_filename>_parity.raid.meta
```

Filename sanitisation replaces `/ \ : * ? " < > |` with `_`.

### `.raid` file format

```
[payload bytes]
```

If compression is enabled, the first 4 bytes are the magic `52 41 5A 43`
("RAZC") followed by DEFLATE-compressed data.  
If encryption is enabled, the first 16 bytes of the *compressed* payload are
the random AES-CBC IV, followed by ciphertext.

### `.meta` file format

UTF-8 JSON:

```json
{
  "filename": "backup.tar.gz",
  "chunkIndex": 0,
  "totalChunks": 2,
  "diskIndex": 0,
  "originalSize": 2097152,
  "checksum": "a3f…",
  "isParityChunk": false,
  "compressed": true,
  "encrypted": false,
  "raidType": "raid5",
  "createdAt": "2026-01-01T12:00:00.000Z"
}
```

---

## Threading / async model

- All disk I/O is **non-blocking async** (Dart's `Future`-based I/O).
- Writes to multiple disks in the same stripe are issued with
  `Future.wait([…])` for parallel execution.
- Reads follow the same parallel pattern.
- The health-check timer runs on the event loop — it will not block I/O.
- There is **no thread-pool or isolate** in this version; everything runs on
  the main isolate event loop.

---

## Extension points

| Scenario | How to extend |
|----------|---------------|
| New RAID level | Implement `RaidStrategy` and extend `_buildStrategy()` in `FilesystemRaid` |
| Custom parity algorithm | Add a `ParityAlgorithm` variant and handle it in `ParityRecovery` |
| Custom storage backend | Replace `DiskManager` with a custom class that honours the same interface |
| Custom logging | Replace `RaidLogger.attachConsole()` with your own `Logger.root.onRecord` listener |
