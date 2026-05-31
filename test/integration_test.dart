/// Integration test: exercises the full stack end-to-end for all RAID levels.
import 'dart:io';
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

Future<List<String>> makeDiskPaths(Directory base, int count) async {
  final paths = <String>[];
  for (var i = 0; i < count; i++) {
    final dir = Directory('${base.path}/disk$i');
    await dir.create(recursive: true);
    paths.add(dir.path);
  }
  return paths;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('raid_integration_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // ── RAID 0 ────────────────────────────────────────────────────────────────
  group('[Integration] RAID 0', () {
    test('full write-read-delete cycle', () async {
      final paths = await makeDiskPaths(tempDir, 4);
      final raid = FilesystemRaid(
        diskPaths: paths,
        config: const RaidConfig(
          type: RaidType.raid0,
          diskCount: 4,
          healthCheckInterval: Duration.zero,
          writeVerification: false,
        ),
      );
      await raid.initialize();

      // Write several files.
      final files = {
        'doc.txt': Uint8List.fromList(List.generate(5000, (i) => i % 256)),
        'image.raw': Uint8List.fromList(List.generate(8192, (i) => (i * 3) % 256)),
        'tiny.bin': Uint8List.fromList([0xCA, 0xFE]),
      };

      for (final entry in files.entries) {
        await raid.write(entry.key, entry.value);
      }

      // Verify all reads.
      for (final entry in files.entries) {
        final readBack = await raid.read(entry.key);
        expect(readBack, equals(entry.value), reason: 'Mismatch for ${entry.key}');
      }

      // Delete one file.
      await raid.delete('doc.txt');
      expect(await raid.fileExists('doc.txt'), isFalse);
      expect(await raid.fileExists('image.raw'), isTrue);

      final info = raid.storageInfo();
      expect(info.raidType, equals(RaidType.raid0));

      await raid.dispose();
    });
  });

  // ── RAID 1 ────────────────────────────────────────────────────────────────
  group('[Integration] RAID 1', () {
    test('write, fail all-but-one disk, read, recover', () async {
      final paths = await makeDiskPaths(tempDir, 3);
      final raid = FilesystemRaid(
        diskPaths: paths,
        config: const RaidConfig(
          type: RaidType.raid1,
          diskCount: 3,
          healthCheckInterval: Duration.zero,
          writeVerification: false,
        ),
      );
      await raid.initialize();

      final payload = Uint8List.fromList(List.generate(2000, (i) => (i * 7) % 256));
      await raid.write('backup.tar', payload);

      // Fail 2 of 3 disks.
      raid.simulateDiskFailure(0);
      raid.simulateDiskFailure(1);

      // Should still read from disk 2.
      final readBack = await raid.read('backup.tar');
      expect(readBack, equals(payload));

      // Restore disks and trigger recovery.
      await raid.simulateDiskRestore(0);
      await raid.simulateDiskRestore(1);
      final report = await raid.recover();
      expect(report.status, equals(RecoveryStatus.notRequired),
          reason: 'All disks are healthy after restore, no rebuild needed');

      await raid.dispose();
    });
  });

  // ── RAID 5 ────────────────────────────────────────────────────────────────
  group('[Integration] RAID 5', () {
    test('write, fail one disk, read via parity, rebuild', () async {
      final paths = await makeDiskPaths(tempDir, 3);
      final raid = FilesystemRaid(
        diskPaths: paths,
        config: const RaidConfig(
          type: RaidType.raid5,
          diskCount: 3,
          healthCheckInterval: Duration.zero,
          writeVerification: false,
        ),
      );
      await raid.initialize();

      final payload =
          Uint8List.fromList(List.generate(4096, (i) => (i * 11 + 5) % 256));
      await raid.write('database.db', payload);

      // Fail disk 0.
      raid.simulateDiskFailure(0);

      // Parity read should reconstruct.
      final readBack = await raid.read('database.db');
      expect(readBack, equals(payload));

      // Rebuild.
      await raid.simulateDiskRestore(0);
      final report = await raid.recover();
      expect(
        report.status,
        anyOf(equals(RecoveryStatus.success), equals(RecoveryStatus.partial),
            equals(RecoveryStatus.notRequired)),
      );

      // After rebuild, normal read should still work.
      final readAfterRebuild = await raid.read('database.db');
      expect(readAfterRebuild, equals(payload));

      await raid.dispose();
    });

    test('multiple files survive parity disk failure', () async {
      final paths = await makeDiskPaths(tempDir, 3);
      final raid = FilesystemRaid(
        diskPaths: paths,
        config: const RaidConfig(
          type: RaidType.raid5,
          diskCount: 3,
          healthCheckInterval: Duration.zero,
          writeVerification: false,
        ),
      );
      await raid.initialize();

      final files = {
        'a.bin': Uint8List.fromList(List.generate(300, (i) => i % 256)),
        'b.bin': Uint8List.fromList(List.generate(600, (i) => (i * 2) % 256)),
        'c.bin': Uint8List.fromList(List.generate(900, (i) => (i * 3) % 256)),
      };

      for (final e in files.entries) {
        await raid.write(e.key, e.value);
      }

      // Fail the parity disk.
      final parityDisk = ParityCalculator.parityDiskIndex(0, 3);
      raid.simulateDiskFailure(parityDisk);

      // All files should still be readable (parity is not needed for data).
      for (final e in files.entries) {
        final readBack = await raid.read(e.key);
        expect(readBack, equals(e.value), reason: 'Mismatch for ${e.key}');
      }

      await raid.dispose();
    });
  });

  // ── Compression + RAID 5 ─────────────────────────────────────────────────
  group('[Integration] RAID 5 with compression', () {
    test('compressed write-read round-trip', () async {
      final paths = await makeDiskPaths(tempDir, 3);
      final raid = FilesystemRaid(
        diskPaths: paths,
        config: const RaidConfig(
          type: RaidType.raid5,
          diskCount: 3,
          enableCompression: true,
          healthCheckInterval: Duration.zero,
          writeVerification: false,
        ),
      );
      await raid.initialize();

      // Highly compressible data (runs of zeros).
      final payload = Uint8List(8192); // all zeros

      await raid.write('compressible.bin', payload);
      final readBack = await raid.read('compressible.bin');
      expect(readBack, equals(payload));

      await raid.dispose();
    });
  });

  // ── Builder ───────────────────────────────────────────────────────────────
  group('[Integration] FilesystemRaidBuilder', () {
    test('builds and operates a RAID 5 array end-to-end', () async {
      final paths = await makeDiskPaths(tempDir, 4);
      final raid = FilesystemRaidBuilder()
          .disks(paths)
          .type(RaidType.raid5)
          .compress()
          .chunkSize(512 * 1024)
          .healthInterval(Duration.zero)
          .retries(1)
          .skipVerification()
          .logLevel(RaidLogLevel.none)
          .build();

      await raid.initialize();

      final data = Uint8List.fromList(List.generate(10000, (i) => i % 256));
      await raid.write('built.dat', data);

      raid.simulateDiskFailure(2);
      final readBack = await raid.read('built.dat');
      expect(readBack, equals(data));

      await raid.dispose();
    });
  });
}
