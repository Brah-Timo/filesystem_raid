// ignore_for_file: avoid_print
/// Home NAS setup example.
///
/// Demonstrates a production-like configuration with health monitoring,
/// multiple files, and periodic recovery checks.
///
/// Run with:
///   dart run example/nas_setup.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';

Future<void> main() async {
  RaidLogger.attachConsole();

  // In a real NAS you would use physical mount points:
  //   const diskPaths = ['/mnt/nas/disk1', '/mnt/nas/disk2', '/mnt/nas/disk3'];
  // Here we use temporary directories for the demo.
  final base = await Directory.systemTemp.createTemp('nas_demo_');
  final diskPaths = [
    '${base.path}/disk0',
    '${base.path}/disk1',
    '${base.path}/disk2',
  ];

  print('\n=== Home NAS — RAID 5 Setup Demo ===\n');

  // ── Build the array using the fluent builder ───────────────────────────────
  final raid = FilesystemRaidBuilder()
      .disks(diskPaths)
      .type(RaidType.raid5)
      .compress()                          // Save disk space
      .chunkSize(4 * 1024 * 1024)         // 4 MiB stripes
      .healthInterval(const Duration(seconds: 10)) // Fast check for demo
      .parity(ParityAlgorithm.xor)
      .retries(3)
      .logLevel(RaidLogLevel.info)
      .build();

  await raid.initialize();

  // ── Write some NAS "files" ─────────────────────────────────────────────────
  print('\n📤 Uploading files to NAS…');

  final uploads = {
    'family_photos.tar': _generateBytes(500 * 1024),   // 500 KiB
    'home_videos.mp4':   _generateBytes(1024 * 1024),  // 1 MiB
    'documents.zip':     _generateBytes(250 * 1024),   // 250 KiB
  };

  for (final entry in uploads.entries) {
    await raid.write(entry.key, entry.value);
    print('  ✓ ${entry.key} — ${entry.value.length ~/ 1024} KiB');
  }

  // ── Show storage info ──────────────────────────────────────────────────────
  print('\n${raid.storageInfo()}');

  // ── Simulate a disk failing mid-operation ─────────────────────────────────
  print('\n⚠  Disk 0 reports hardware failure…');
  raid.simulateDiskFailure(0);

  // All files should still be accessible via parity reconstruction.
  print('\n📥 Verifying data access with failed disk…');
  for (final filename in uploads.keys) {
    try {
      final data = await raid.read(filename);
      final ok = data.length == uploads[filename]!.length;
      print('  ${ok ? "✓" : "✗"} $filename (${data.length ~/ 1024} KiB)');
    } catch (e) {
      print('  ✗ $filename — ERROR: $e');
    }
  }

  // ── Replace failed disk and rebuild ───────────────────────────────────────
  print('\n🔄 Replacing disk 0 and rebuilding array…');
  await raid.simulateDiskRestore(0);
  final report = await raid.recover();
  print(report.summary());

  // ── Health check loop (simulated short interval) ───────────────────────────
  print('🩺 Running 3 health checks (every 2 s)…');
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final statuses = await raid.checkDiskHealth();
    final healthy = statuses.where((s) => s.isReadable).length;
    final failed = statuses.where((s) => s.isFailed).length;
    print('  Check ${i + 1}: $healthy OK, $failed FAILED — '
        '${DateTime.now().toIso8601String().substring(11, 19)}');
  }

  // ── Clean up ──────────────────────────────────────────────────────────────
  await raid.dispose();
  await base.delete(recursive: true);
  print('\n✓ NAS demo complete.\n');
}

/// Generates [length] bytes of pseudo-random test data.
Uint8List _generateBytes(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 17 + 7) % 256));
