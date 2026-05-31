# Testing Guide

Strategies, helpers, and examples for writing reliable tests against
**filesystem_raid**.

---

## Table of Contents

1. [Test setup](#test-setup)
2. [Unit testing individual components](#unit-testing-individual-components)
   - [ChunkSplitter](#chunksplitter)
   - [ParityCalculator](#paritycalculator)
   - [ReedSolomonCodec](#reedsolomoncodec)
   - [RaidCompression](#raidcompression)
   - [FileHasher](#filehasher)
3. [Integration tests](#integration-tests)
   - [Basic write / read roundtrip](#basic-write--read-roundtrip)
   - [RAID 0 — no recovery](#raid-0--no-recovery)
   - [RAID 1 — mirror rebuild](#raid-1--mirror-rebuild)
   - [RAID 5 — parity rebuild](#raid-5--parity-rebuild)
4. [Using simulateDiskFailure](#using-simulatediskfailure)
5. [Configuration tips for tests](#configuration-tips-for-tests)
6. [Coverage](#coverage)

---

## Test setup

**pubspec.yaml** dev dependencies:

```yaml
dev_dependencies:
  test: ^1.25.0
  mocktail: ^1.0.3
  coverage: ^1.7.2
  lints: ^3.0.0
```

Each test that touches the filesystem should use `setUp` / `tearDown` to
create and destroy a temporary directory:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<String> diskPaths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('raid_test_');
    diskPaths = List.generate(3, (i) => '${tempDir.path}/disk$i');
    for (final p in diskPaths) {
      await Directory(p).create(recursive: true);
    }
  });

  tearDown(() => tempDir.delete(recursive: true));
}
```

---

## Unit testing individual components

### ChunkSplitter

```dart
test('split and merge roundtrip', () {
  final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
  final chunks = ChunkSplitter.split(data, 3);
  expect(chunks.length, equals(3));

  final merged = ChunkSplitter.merge(chunks, originalLength: data.length);
  expect(merged, equals(data));
});

test('equaliseLength zero-pads to longest', () {
  final chunks = [
    Uint8List.fromList([1, 2]),
    Uint8List.fromList([3, 4, 5, 6]),
  ];
  final equal = ChunkSplitter.equaliseLength(chunks);
  expect(equal[0].length, equals(4));
  expect(equal[0][2], equals(0)); // padded with zero
});
```

### ParityCalculator

```dart
test('XOR parity roundtrip', () {
  const calc = ParityCalculator();
  final d0 = Uint8List.fromList([1, 2, 3]);
  final d1 = Uint8List.fromList([4, 5, 6]);
  final parity = calc.calculate([d0, d1]);
  // parity = [5, 7, 5]

  // Recover d0 from d1 + parity.
  final recovered = calc.recoverSingleChunk(
    availableChunks: [d1],
    parity: parity,
  );
  expect(recovered, equals(d0));
});
```

### ReedSolomonCodec

```dart
test('encode and decode recover missing shard', () {
  final rs = ReedSolomonCodec(dataCount: 3, parityCount: 1);
  final shards = List.generate(3, (i) => Uint8List.fromList([i + 1, i + 2, i + 3]));
  final encoded = rs.encode(shards);
  expect(encoded.length, equals(4));

  // Lose shard 1.
  final withMissing = List<Uint8List?>.from(encoded)..[1] = null;
  final decoded = rs.decode(withMissing);
  expect(decoded[1], equals(encoded[1]));
});
```

### RaidCompression

```dart
test('compress and decompress roundtrip', () {
  final original = Uint8List.fromList(List.generate(1024, (i) => 0xAB));
  final result = RaidCompression.compress(original);
  expect(result.compressedSize, lessThan(result.originalSize));

  final decompressed = RaidCompression.decompress(result.data);
  expect(decompressed, equals(original));
});

test('isCompressed detects magic header', () {
  final original = Uint8List.fromList(List.generate(1024, (i) => 0xAB));
  final result = RaidCompression.compress(original);
  if (result.compressedSize < result.originalSize) {
    expect(RaidCompression.isCompressed(result.data), isTrue);
  }
  expect(RaidCompression.isCompressed(original), isFalse);
});
```

### FileHasher

```dart
test('sha256Hex produces consistent results', () {
  final data = Uint8List.fromList('hello'.codeUnits);
  final hex1 = FileHasher.sha256Hex(data);
  final hex2 = FileHasher.sha256Hex(data);
  expect(hex1, equals(hex2));
  expect(hex1.length, equals(64));
});

test('verify returns false on tampered data', () {
  final data = Uint8List.fromList([1, 2, 3]);
  final checksum = FileHasher.sha256Hex(data);
  data[0] = 99; // tamper
  expect(FileHasher.verify(data, checksum), isFalse);
});
```

---

## Integration tests

### Basic write / read roundtrip

```dart
test('write and read returns original data', () async {
  final raid = FilesystemRaid(
    diskPaths: diskPaths,
    config: const RaidConfig(
      type: RaidType.raid5,
      diskCount: 3,
      healthCheckInterval: Duration.zero,
      writeVerification: false,
    ),
  );
  await raid.initialize();

  final data = Uint8List.fromList(List.generate(4096, (i) => i % 256));
  await raid.write('test.bin', data);
  final readBack = await raid.read('test.bin');

  expect(readBack, equals(data));
  await raid.dispose();
});
```

### RAID 0 — no recovery

```dart
test('RAID 0 throws RaidNotRecoverableException on recover()', () async {
  final raid = FilesystemRaid(
    diskPaths: diskPaths.take(2).toList(),
    config: const RaidConfig(
      type: RaidType.raid0,
      diskCount: 2,
      healthCheckInterval: Duration.zero,
    ),
  );
  await raid.initialize();

  expect(
    () => raid.recover(),
    throwsA(isA<RaidNotRecoverableException>()),
  );

  await raid.dispose();
});
```

### RAID 1 — mirror rebuild

```dart
test('RAID 1 reads from surviving mirror after disk failure', () async {
  final raid = FilesystemRaid(
    diskPaths: diskPaths.take(2).toList(),
    config: const RaidConfig(
      type: RaidType.raid1,
      diskCount: 2,
      healthCheckInterval: Duration.zero,
      writeVerification: false,
    ),
  );
  await raid.initialize();

  final data = Uint8List.fromList(List.generate(256, (i) => i));
  await raid.write('mirror.txt', data);

  // Fail one disk.
  raid.simulateDiskFailure(0);

  // Still readable from disk 1.
  final readBack = await raid.read('mirror.txt');
  expect(readBack, equals(data));

  // Recover.
  await raid.simulateDiskRestore(0);
  final report = await raid.recover();
  expect(report.status, equals(RecoveryStatus.success));

  await raid.dispose();
});
```

### RAID 5 — parity rebuild

```dart
test('RAID 5 reconstructs data chunk via XOR parity', () async {
  final raid = FilesystemRaid(
    diskPaths: diskPaths,
    config: const RaidConfig(
      type: RaidType.raid5,
      diskCount: 3,
      parityAlgorithm: ParityAlgorithm.xor,
      healthCheckInterval: Duration.zero,
      writeVerification: false,
    ),
  );
  await raid.initialize();

  final data = Uint8List.fromList(List.generate(6000, (i) => i % 251));
  await raid.write('data.bin', data);

  // Fail a data disk.
  raid.simulateDiskFailure(0);

  // Data is transparently recovered via parity.
  final readBack = await raid.read('data.bin');
  expect(readBack, equals(data));

  // Full rebuild.
  await raid.simulateDiskRestore(0);
  final report = await raid.recover();
  expect(report.status, equals(RecoveryStatus.success));
  expect(report.recoveredDiskIndexes, contains(0));

  await raid.dispose();
});
```

---

## Using simulateDiskFailure

`FilesystemRaid.simulateDiskFailure(index)` marks a disk as
`DiskHealth.failed` in-memory without touching the actual filesystem.

This means:
- Reads to that disk return `null` (triggering parity/mirror recovery).
- Writes to that disk throw `DiskFailedException`.

`simulateDiskRestore(index)` re-probes the directory, resets the status to
`healthy`, and reloads the file registry — making it ready for `recover()`.

These methods do **not** require `@visibleForTesting` imports — they are part
of the public API, intended for testing and demo scenarios.

---

## Configuration tips for tests

Use these settings to make tests fast and deterministic:

```dart
const RaidConfig(
  type: RaidType.raid5,
  diskCount: 3,
  healthCheckInterval: Duration.zero,   // disable background timer
  writeVerification: false,             // skip post-write read
  logLevel: RaidLogLevel.none,          // silence all output
)
```

For tests that specifically exercise write-verification, set
`writeVerification: true` and accept the slower execution.

---

## Coverage

Run the full test suite with coverage:

```bash
dart test --coverage=coverage/
dart pub global activate coverage
dart pub global run coverage:format_coverage \
    --lcov \
    --in=coverage/ \
    --out=coverage/lcov.info \
    --report-on=lib/
genhtml coverage/lcov.info -o coverage/html
```

Open `coverage/html/index.html` in your browser to see the coverage report.
