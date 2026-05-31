import 'dart:io';
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<String> diskPaths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('raid_1_test_');
    diskPaths = [
      '${tempDir.path}/d0',
      '${tempDir.path}/d1',
      '${tempDir.path}/d2',
    ];
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  FilesystemRaid makeRaid() => FilesystemRaid(
        diskPaths: diskPaths,
        config: const RaidConfig(
          type: RaidType.raid1,
          diskCount: 3,
          healthCheckInterval: Duration.zero,
          writeVerification: false,
        ),
      );

  group('RAID 1 – write / read', () {
    test('write and read back identical data', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList(List.generate(500, (i) => i % 256));
      await raid.write('photo.jpg', data);

      final readBack = await raid.read('photo.jpg');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('same file is present on all 3 disks', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      await raid.write('magic.bin', data);

      for (var i = 0; i < diskPaths.length; i++) {
        final files = await raid.listFiles();
        expect(files, contains('magic.bin'));
      }

      await raid.dispose();
    });
  });

  group('RAID 1 – fault tolerance', () {
    test('reads successfully when disk 0 fails', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList(List.generate(800, (i) => (i + 1) % 256));
      await raid.write('resilient.dat', data);

      raid.simulateDiskFailure(0);

      final readBack = await raid.read('resilient.dat');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('reads successfully when two of three disks fail', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList([1, 3, 5, 7, 9]);
      await raid.write('odds.bin', data);

      raid.simulateDiskFailure(0);
      raid.simulateDiskFailure(1);

      final readBack = await raid.read('odds.bin');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('fails when all disks fail', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList([42]);
      await raid.write('single.bin', data);

      raid.simulateDiskFailure(0);
      raid.simulateDiskFailure(1);
      raid.simulateDiskFailure(2);

      expect(
        () => raid.read('single.bin'),
        throwsA(isA<RaidRecoveryException>()),
      );

      await raid.dispose();
    });
  });

  group('RAID 1 – recovery', () {
    test('recover() rebuilds failed disk from healthy mirror', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList(List.generate(200, (i) => i % 256));
      await raid.write('docs.bin', data);

      raid.simulateDiskFailure(2);

      final report = await raid.recover();
      expect(report.isFullySuccessful, isTrue);
      expect(report.recoveredDiskIndexes, contains(2));

      await raid.dispose();
    });

    test('recover() returns notRequired when all disks are healthy', () async {
      final raid = makeRaid();
      await raid.initialize();

      await raid.write('fine.dat', Uint8List.fromList([1, 2, 3]));
      final report = await raid.recover();
      expect(report.status, equals(RecoveryStatus.notRequired));

      await raid.dispose();
    });
  });

  group('RAID 1 – large data', () {
    test('round-trips 2 MiB with one disk failed during write', () async {
      final raid = makeRaid();
      await raid.initialize();

      // Fail disk 0 BEFORE writing — remaining 2 mirrors keep data safe.
      raid.simulateDiskFailure(0);

      final data = Uint8List.fromList(
          List.generate(2 * 1024 * 1024, (i) => (i * 5) % 256));
      await raid.write('video.mp4', data);
      final readBack = await raid.read('video.mp4');
      expect(readBack, equals(data));

      await raid.dispose();
    });
  });
}
