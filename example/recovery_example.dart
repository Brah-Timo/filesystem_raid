// ignore_for_file: avoid_print
/// Data recovery example.
///
/// Demonstrates all recovery scenarios across RAID levels.
///
/// Run with:
///   dart run example/recovery_example.dart
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';

Future<void> main() async {
  RaidLogger.attachConsole();
  final base = await Directory.systemTemp.createTemp('recovery_demo_');

  print('\n=== filesystem_raid — Recovery Scenarios Demo ===\n');

  await _demoRaid1Recovery(base);
  await _demoRaid5DataDiskRecovery(base);
  await _demoRaid5ParityDiskRecovery(base);
  await _demoRaid0NoRecovery(base);

  await base.delete(recursive: true);
  print('\n✓ All recovery demos completed.\n');
}

// ── RAID 1 Recovery ───────────────────────────────────────────────────────────

Future<void> _demoRaid1Recovery(Directory base) async {
  print('──────────────────────────────────────');
  print('Scenario 1: RAID 1 — disk failure + rebuild');
  print('──────────────────────────────────────');

  final diskPaths = await _mkDisks(base, 'raid1_recovery', 2);
  final raid = FilesystemRaid(
    diskPaths: diskPaths,
    config: const RaidConfig(
      type: RaidType.raid1,
      diskCount: 2,
      healthCheckInterval: Duration.zero,
      writeVerification: false,
    ),
  );
  await raid.initialize();

  final original = _bytes(300);
  await raid.write('critical.db', original);
  print('  ✓ Written to both mirrors.');

  // Fail disk 0.
  raid.simulateDiskFailure(0);
  print('  ⚠ Disk 0 failed.');

  // Still readable from mirror.
  final readBack = await raid.read('critical.db');
  print('  ✓ Read from mirror (disk 1) — match: ${_match(readBack, original)}');

  // Rebuild disk 0.
  await raid.simulateDiskRestore(0);
  final report = await raid.recover();
  print('  🔧 Recovery status: ${report.status}');
  print('  🔧 Rebuilt disks  : ${report.recoveredDiskIndexes}');

  await raid.dispose();
  print('');
}

// ── RAID 5 — Data Disk Recovery ───────────────────────────────────────────────

Future<void> _demoRaid5DataDiskRecovery(Directory base) async {
  print('──────────────────────────────────────');
  print('Scenario 2: RAID 5 — data disk failure (XOR parity)');
  print('──────────────────────────────────────');

  final diskPaths = await _mkDisks(base, 'raid5_data_rec', 3);
  final raid = FilesystemRaid(
    diskPaths: diskPaths,
    config: const RaidConfig(
      type: RaidType.raid5,
      diskCount: 3,
      healthCheckInterval: Duration.zero,
      writeVerification: false,
      parityAlgorithm: ParityAlgorithm.xor,
    ),
  );
  await raid.initialize();

  final original = _bytes(4096); // 4 KiB
  await raid.write('archive.tar', original);
  print('  ✓ Written with XOR parity across 3 disks.');

  raid.simulateDiskFailure(1);
  print('  ⚠ Disk 1 (data) failed.');

  final readBack = await raid.read('archive.tar');
  print('  ✓ XOR recovery successful — match: ${_match(readBack, original)}');

  await raid.simulateDiskRestore(1);
  final report = await raid.recover();
  print('  🔧 Recovery: ${report.status}, '
      '${report.recoveredFiles.length} file(s) rebuilt.');

  await raid.dispose();
  print('');
}

// ── RAID 5 — Parity Disk Recovery ────────────────────────────────────────────

Future<void> _demoRaid5ParityDiskRecovery(Directory base) async {
  print('──────────────────────────────────────');
  print('Scenario 3: RAID 5 — parity disk failure (Reed-Solomon)');
  print('──────────────────────────────────────');

  final diskPaths = await _mkDisks(base, 'raid5_parity_rec', 4);
  final raid = FilesystemRaid(
    diskPaths: diskPaths,
    config: const RaidConfig(
      type: RaidType.raid5,
      diskCount: 4,
      healthCheckInterval: Duration.zero,
      writeVerification: false,
      parityAlgorithm: ParityAlgorithm.reedSolomon,
    ),
  );
  await raid.initialize();

  final original = _bytes(6144);
  await raid.write('video_thumb.jpg', original);

  final parityDisk = ParityCalculator.parityDiskIndex(0, 4);
  raid.simulateDiskFailure(parityDisk);
  print('  ⚠ Parity disk ($parityDisk) failed.');

  // Data is accessible without parity.
  final readBack = await raid.read('video_thumb.jpg');
  print('  ✓ Data read without parity — match: ${_match(readBack, original)}');

  await raid.simulateDiskRestore(parityDisk);
  final report = await raid.recover();
  print('  🔧 Parity rebuilt: ${report.status}');

  await raid.dispose();
  print('');
}

// ── RAID 0 — No Recovery ──────────────────────────────────────────────────────

Future<void> _demoRaid0NoRecovery(Directory base) async {
  print('──────────────────────────────────────');
  print('Scenario 4: RAID 0 — expected no-recovery behaviour');
  print('──────────────────────────────────────');

  final diskPaths = await _mkDisks(base, 'raid0_no_rec', 2);
  final raid = FilesystemRaid(
    diskPaths: diskPaths,
    config: const RaidConfig(
      type: RaidType.raid0,
      diskCount: 2,
      healthCheckInterval: Duration.zero,
    ),
  );
  await raid.initialize();

  await raid.write('temp.dat', _bytes(200));
  raid.simulateDiskFailure(0);
  print('  ⚠ Disk 0 failed.');

  try {
    await raid.recover();
    print('  ✗ Expected exception not thrown!');
  } on RaidNotRecoverableException catch (e) {
    print('  ✓ Caught expected: ${e.message}');
  }

  await raid.dispose();
  print('');
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Future<List<String>> _mkDisks(Directory base, String name, int count) async {
  final paths = <String>[];
  for (var i = 0; i < count; i++) {
    final dir = Directory('${base.path}/${name}_d$i');
    await dir.create(recursive: true);
    paths.add(dir.path);
  }
  return paths;
}

Uint8List _bytes(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 23 + 11) % 256));

bool _match(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
