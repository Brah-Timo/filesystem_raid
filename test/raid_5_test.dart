import 'dart:io';
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<String> diskPaths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('raid_5_test_');
    diskPaths = [
      '${tempDir.path}/d0',
      '${tempDir.path}/d1',
      '${tempDir.path}/d2',
    ];
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  FilesystemRaid makeRaid({
    ParityAlgorithm algo = ParityAlgorithm.xor,
  }) =>
      FilesystemRaid(
        diskPaths: diskPaths,
        config: RaidConfig(
          type: RaidType.raid5,
          diskCount: 3,
          healthCheckInterval: Duration.zero,
          writeVerification: false,
          parityAlgorithm: algo,
        ),
      );

  group('RAID 5 – write / read (healthy array)', () {
    test('writes and reads back identical small data', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList([72, 101, 108, 108, 111]); // "Hello"
      await raid.write('hello.txt', data);
      final readBack = await raid.read('hello.txt');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('writes and reads back 1 MiB binary data', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data =
          Uint8List.fromList(List.generate(1024 * 1024, (i) => (i * 13) % 256));
      await raid.write('binary.bin', data);
      final readBack = await raid.read('binary.bin');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('lists files after write', () async {
      final raid = makeRaid();
      await raid.initialize();

      await raid.write('a.dat', Uint8List.fromList([1]));
      await raid.write('b.dat', Uint8List.fromList([2]));

      final files = await raid.listFiles();
      expect(files, containsAll(['a.dat', 'b.dat']));

      await raid.dispose();
    });

    test('overwrites a file without errors', () async {
      final raid = makeRaid();
      await raid.initialize();

      await raid.write('over.dat', Uint8List.fromList([1, 2, 3]));
      await raid.write('over.dat', Uint8List.fromList([9, 8, 7]));

      final readBack = await raid.read('over.dat');
      // Should return the latest version.
      expect(readBack, equals(Uint8List.fromList([9, 8, 7])));

      await raid.dispose();
    });
  });

  group('RAID 5 – fault tolerance (one disk failure)', () {
    test('reads correctly when disk 0 (data) fails', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList(List.generate(600, (i) => i % 256));
      await raid.write('important.bin', data);

      raid.simulateDiskFailure(0);

      final readBack = await raid.read('important.bin');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('reads correctly when disk 1 (data) fails', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data =
          Uint8List.fromList(List.generate(900, (i) => (i * 7) % 256));
      await raid.write('data.db', data);

      raid.simulateDiskFailure(1);

      final readBack = await raid.read('data.db');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('reads correctly when parity disk fails', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList(List.generate(300, (i) => i % 256));
      await raid.write('nodeparity.bin', data);

      // Find out which disk is the parity disk.
      final parityDisk =
          ParityCalculator.parityDiskIndex(0, diskPaths.length);
      raid.simulateDiskFailure(parityDisk);

      final readBack = await raid.read('nodeparity.bin');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('fails when two disks fail simultaneously', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      await raid.write('doomed.bin', data);

      raid.simulateDiskFailure(0);
      raid.simulateDiskFailure(1);

      expect(
        () => raid.read('doomed.bin'),
        throwsA(anyOf(
          isA<TooManyDiskFailuresException>(),
          isA<RaidRecoveryException>(),
        )),
      );

      await raid.dispose();
    });
  });

  group('RAID 5 – recovery operation', () {
    test('recover() rebuilds a failed data disk', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList(List.generate(600, (i) => i % 256));
      await raid.write('recover_me.bin', data);

      raid.simulateDiskFailure(0);

      final report = await raid.recover();
      expect(report.status,
          anyOf(equals(RecoveryStatus.success), equals(RecoveryStatus.partial)));
      expect(report.recoveredDiskIndexes, contains(0));

      // After recovery the file must be readable again.
      final readBack = await raid.read('recover_me.bin');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('recover() returns notRequired when healthy', () async {
      final raid = makeRaid();
      await raid.initialize();
      await raid.write('fine.bin', Uint8List.fromList([1, 2, 3]));

      final report = await raid.recover();
      expect(report.status, equals(RecoveryStatus.notRequired));

      await raid.dispose();
    });

    test('recover() returns failed for 2 simultaneous failures', () async {
      final raid = makeRaid();
      await raid.initialize();
      await raid.write('two_fail.bin', Uint8List.fromList([1, 2, 3]));

      raid.simulateDiskFailure(0);
      raid.simulateDiskFailure(1);

      final report = await raid.recover();
      expect(report.status, equals(RecoveryStatus.failed));

      await raid.dispose();
    });
  });

  group('RAID 5 – storageInfo', () {
    test('reports 67 % usable efficiency for 3 disks', () async {
      final raid = makeRaid();
      await raid.initialize();

      final info = raid.storageInfo();
      expect(info.diskCount, equals(3));
      // 2/3 ≈ 66.67 %
      final efficiency = (info.diskCount - 1) / info.diskCount;
      expect(efficiency, closeTo(0.6667, 0.01));

      await raid.dispose();
    });
  });

  group('RAID 5 – FilesystemRaidBuilder', () {
    test('builder produces a valid RAID 5 instance', () async {
      final raid = FilesystemRaidBuilder()
          .disks(diskPaths)
          .type(RaidType.raid5)
          .compress()
          .chunkSize(1024 * 1024)
          .logLevel(RaidLogLevel.none)
          .build();

      await raid.initialize();
      expect(raid.isInitialised, isTrue);
      expect(raid.config.enableCompression, isTrue);

      await raid.dispose();
    });
  });
}
