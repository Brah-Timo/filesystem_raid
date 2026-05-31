# Getting Started with filesystem_raid

A step-by-step guide to adding **filesystem_raid** to your Dart or Flutter project
and running your first RAID array in minutes.

---

## Table of Contents

1. [Requirements](#requirements)
2. [Installation](#installation)
3. [Quick-start (RAID 5)](#quick-start-raid-5)
4. [Choosing a RAID level](#choosing-a-raid-level)
5. [Initialisation checklist](#initialisation-checklist)
6. [First write and read](#first-write-and-read)
7. [Simulating a disk failure](#simulating-a-disk-failure)
8. [Running recovery](#running-recovery)
9. [Cleanup](#cleanup)
10. [Next steps](#next-steps)

---

## Requirements

| Component | Minimum version |
|-----------|----------------|
| Dart SDK  | 3.0.0          |
| Flutter   | 3.10.0 (optional) |
| OS        | Any POSIX (Linux / macOS) or Windows |

---

## Installation

Add **filesystem_raid** to your `pubspec.yaml`:

```yaml
dependencies:
  filesystem_raid: ^1.0.0
```

Then fetch the package:

```bash
dart pub get
# or inside a Flutter project
flutter pub get
```

---

## Quick-start (RAID 5)

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:filesystem_raid/filesystem_raid.dart';

Future<void> main() async {
  // 1. Point to three disk directories (create them if necessary).
  final diskPaths = ['/data/disk0', '/data/disk1', '/data/disk2'];

  // 2. Build the RAID manager.
  final raid = FilesystemRaid(
    diskPaths: diskPaths,
    config: const RaidConfig(
      type: RaidType.raid5,
      diskCount: 3,
    ),
  );

  // 3. Initialise (scans directories, starts health timer).
  await raid.initialize();

  // 4. Write data.
  final data = await File('backup.tar.gz').readAsBytes();
  await raid.write('backup.tar.gz', data);

  // 5. Read data back.
  final recovered = await raid.read('backup.tar.gz');
  assert(recovered.length == data.length);

  // 6. Always dispose when done.
  await raid.dispose();
}
```

---

## Choosing a RAID level

| Level  | Min disks | Fault tolerance | Storage efficiency | Best for |
|--------|-----------|-----------------|-------------------|----------|
| RAID 0 | 2         | 0 disks         | 100 %             | Scratch / caches |
| RAID 1 | 2         | N-1 disks       | 1/N               | OS volumes, critical configs |
| RAID 5 | 3         | 1 disk          | (N-1)/N           | NAS, balanced workloads |

Pass the chosen level through `RaidConfig.type`:

```dart
const config = RaidConfig(type: RaidType.raid1, diskCount: 2);
```

---

## Initialisation checklist

Before calling `initialize()`:

- **Disk directories** — paths must already exist **or** be writable so the
  library can create them automatically.
- **diskCount** — `config.diskCount` **must equal** `diskPaths.length`.
- **Minimum disks** — RAID 5 requires at least **3** paths.
- **Encryption key** — if `enableEncryption: true`, supply a 32-byte key in
  `encryptionKey`.

---

## First write and read

```dart
// Write — any Uint8List works.
await raid.write('notes.txt', Uint8List.fromList('Hello!'.codeUnits));

// List what is stored.
final files = await raid.listFiles();
print(files); // {notes.txt}

// Read — returns Uint8List.
final bytes = await raid.read('notes.txt');
print(String.fromCharCodes(bytes)); // Hello!

// Delete.
await raid.delete('notes.txt');
```

---

## Simulating a disk failure

Use `simulateDiskFailure` during development to verify fault tolerance:

```dart
// After writing, mark disk 1 as failed.
raid.simulateDiskFailure(1);

// RAID 5/1 can still serve reads transparently.
final data = await raid.read('notes.txt');

// Restore the disk before calling recover().
await raid.simulateDiskRestore(1);
```

---

## Running recovery

```dart
final report = await raid.recover();
print(report.summary());

// Inspect the outcome.
if (report.isFullySuccessful) {
  print('All disks rebuilt!');
} else {
  for (final e in report.errors.entries) {
    print('  Error [${e.key}]: ${e.value}');
  }
}
```

---

## Cleanup

Always call `dispose()` when your application shuts down:

```dart
await raid.dispose();
```

This cancels the background health-check timer and resets internal state so
the instance can be garbage-collected.

---

## Next steps

- [Configuration Reference](configuration.md) — all `RaidConfig` options
- [Architecture Overview](architecture.md) — how the internals work
- [API Reference](api_reference.md) — complete class and method docs
- [Recovery Guide](recovery.md) — deep-dive into the recovery subsystem
- [Compression & Encryption](compression_encryption.md) — securing your data
