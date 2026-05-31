// ignore_for_file: avoid_print
/// Basic usage example for the filesystem_raid package.
///
/// Run with:
///   dart run example/basic_usage.dart
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';

Future<void> main() async {
  // ── 1. Enable coloured console logging ────────────────────────────────────
  RaidLogger.attachConsole();

  // ── 2. Create temporary disk directories ─────────────────────────────────
  final base = await Directory.systemTemp.createTemp('raid_example_');
  final diskPaths = [
    '${base.path}/disk0',
    '${base.path}/disk1',
    '${base.path}/disk2',
  ];

  print('\n=== filesystem_raid — Basic Usage Demo ===\n');

  // ── 3. Create and initialise a RAID 5 array ───────────────────────────────
  final raid = FilesystemRaid(
    diskPaths: diskPaths,
    config: const RaidConfig(
      type: RaidType.raid5,
      diskCount: 3,
      enableCompression: true,
      healthCheckInterval: Duration.zero,
      writeVerification: false,  // set true in production
      logLevel: RaidLogLevel.info,
    ),
  );

  await raid.initialize();
  print('\n✓ RAID 5 array initialised on 3 disks.');

  // ── 4. Write a file ───────────────────────────────────────────────────────
  final original = Uint8List.fromList(
    List.generate(64 * 1024, (i) => (i * 37 + 13) % 256), // 64 KiB
  );

  await raid.write('document.bin', original);
  print('✓ Wrote ${original.length ~/ 1024} KiB → document.bin');

  // ── 5. Read it back ───────────────────────────────────────────────────────
  final readBack = await raid.read('document.bin');
  assert(readBack.length == original.length, 'Length mismatch!');
  assert(
    List.generate(original.length, (i) => readBack[i] == original[i])
        .every((b) => b),
    'Data mismatch!',
  );
  print('✓ Read back ${readBack.length ~/ 1024} KiB — data verified.');

  // ── 6. List files ─────────────────────────────────────────────────────────
  await raid.write('notes.txt', Uint8List.fromList('Hello RAID!'.codeUnits));
  final files = await raid.listFiles();
  print('\n📂 Files in array: ${files.join(', ')}');

  // ── 7. Storage info ───────────────────────────────────────────────────────
  final info = raid.storageInfo();
  print('\n$info');

  // ── 8. Simulate disk failure & transparent read ───────────────────────────
  print('\n⚠  Simulating failure of disk 1…');
  raid.simulateDiskFailure(1);

  final afterFailure = await raid.read('document.bin');
  final dataMatch = afterFailure.length == original.length &&
      List.generate(original.length, (i) => afterFailure[i] == original[i])
          .every((b) => b);

  print('✓ Read after disk 1 failure — data match: $dataMatch');

  // ── 9. Recover ────────────────────────────────────────────────────────────
  print('\n🔧 Starting recovery…');
  await raid.simulateDiskRestore(1);
  final report = await raid.recover();
  print(report.summary());

  // ── 10. Clean up ──────────────────────────────────────────────────────────
  await raid.dispose();
  await base.delete(recursive: true);
  print('✓ Clean-up complete.\n');
}
