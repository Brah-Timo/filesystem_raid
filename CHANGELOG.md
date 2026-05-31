# Changelog

All notable changes to `filesystem_raid` will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-05-31

### Added

#### Core Architecture
- `FilesystemRaid` — top-level orchestrator with full write/read/delete/list/recover API
- `FilesystemRaidBuilder` — fluent builder for ergonomic configuration
- `RaidStrategy` interface — clean contract for all RAID implementations

#### RAID Levels
- **RAID 0** (Striping): parallel writes/reads, zero overhead, no fault tolerance
- **RAID 1** (Mirroring): full data copy to all disks, tolerates N-1 disk failures
- **RAID 5** (Striping with distributed parity): balanced performance + redundancy,
  tolerates 1 disk failure; distributed parity with left-symmetric rotation

#### Parity Engine
- `ParityCalculator` — XOR-based parity with single-chunk and full-stripe recovery
- `ReedSolomonCodec` — GF(2⁸) Reed-Solomon codec with Vandermonde matrix encoding;
  tolerates multiple disk failures (configurable parity shard count)
- `ParityRecovery` — high-level coordinator; switches between XOR and RS automatically

#### Storage Layer
- `DiskManager` — low-level disk I/O with health probing, write retry, simulated failures
- `ChunkHandler` — encode/decode pipeline (compress → encrypt → checksum)
- `FileRegistry` — JSON-backed per-disk file catalogue
- `StorageInfo` — aggregated capacity and utilisation statistics

#### Utilities
- `ChunkSplitter` — zero-copy split/merge with zero-padding and length restoration
- `FileHasher` — SHA-256 / MD5 helpers with constant-time comparison
- `RaidCompression` — DEFLATE with 4-byte magic header for transparent detection
- `RaidEncryption` / `ChunkHandler.encryptChunk` — AES-256-CBC with random IV per chunk
- `RaidLogger` / `OperationLogger` — levelled structured logging with ANSI colour

#### Models
- `RaidConfig` — immutable config with derived efficiency and fault-tolerance helpers
- `DiskStatus` — disk health snapshot with utilisation metrics
- `ChunkMetadata` — JSON-serialisable per-chunk metadata (checksum, compression, encryption flags)
- `RecoveryReport` — detailed recovery outcome with per-file and per-disk records

#### Exceptions
- `RaidConfigurationException`, `DiskFailedException`, `ChunkNotFoundException`,
  `RaidFileNotFoundException`, `InsufficientSpaceException`, `CorruptedDataException`,
  `RaidNotRecoverableException`, `TooManyDiskFailuresException`, `RaidRecoveryException`,
  `MetadataException`, `ParityException`

#### Tests
- `parity_test.dart` — XOR calculation, stripe recovery, rotation
- `reed_solomon_test.dart` — encode, 1-shard recovery, 2-shard recovery, round-trips
- `chunk_splitter_test.dart` — split, merge, pad, equalise, round-trips
- `disk_manager_test.dart` — init, write, read, delete, failure simulation
- `raid_0_test.dart` — write/read, delete, failure, 1 MiB round-trip
- `raid_1_test.dart` — mirroring, 2-disk failure, recovery
- `raid_5_test.dart` — data/parity disk failure, recovery, builder
- `integration_test.dart` — full end-to-end scenarios for all RAID levels

#### Examples
- `basic_usage.dart` — minimal write/read/recover demo
- `nas_setup.dart` — home NAS simulation with health monitoring
- `recovery_example.dart` — all four recovery scenarios side-by-side

---

## [Unreleased]

### Planned
- RAID 6 support (double-parity, tolerates 2 disk failures)
- Async health callback / event stream for real-time monitoring
- Hot-spare disk support for automatic online rebuilds
- S3-compatible backend adapter (store chunks on object storage)
- Web UI dashboard for disk health and array status
- Benchmark suite (throughput, latency, recovery time)
