import 'dart:io';
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<String> diskPaths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('raid_0_test_');
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
          type: RaidType.raid0,
          diskCount: 3,
          healthCheckInterval: Duration.zero,
          writeVerification: false,
        ),
      );

  group('RAID 0 – write / read', () {
    test('writes and reads back identical data', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data =
          Uint8List.fromList(List.generate(3000, (i) => i % 256));
      await raid.write('test.bin', data);

      final readBack = await raid.read('test.bin');
      expect(readBack, equals(data));

      await raid.dispose();
    });

    test('lists written files', () async {
      final raid = makeRaid();
      await raid.initialize();
      await raid.write('alpha.dat', Uint8List.fromList([1, 2, 3]));
      await raid.write('beta.dat', Uint8List.fromList([4, 5, 6]));

      final files = await raid.listFiles();
      expect(files, contains('alpha.dat'));
      expect(files, contains('beta.dat'));

      await raid.dispose();
    });

    test('deletes a file', () async {
      final raid = makeRaid();
      await raid.initialize();
      await raid.write('del.dat', Uint8List.fromList([9, 9]));
      expect(await raid.fileExists('del.dat'), isTrue);

      await raid.delete('del.dat');
      expect(await raid.fileExists('del.dat'), isFalse);

      await raid.dispose();
    });

    test('reads file not found throws RaidFileNotFoundException', () async {
      final raid = makeRaid();
      await raid.initialize();

      expect(
        () => raid.read('ghost.bin'),
        throwsA(isA<RaidFileNotFoundException>()),
      );

      await raid.dispose();
    });
  });

  group('RAID 0 – recovery', () {
    test('recover() throws RaidNotRecoverableException', () async {
      final raid = makeRaid();
      await raid.initialize();

      expect(
        () => raid.recover(),
        throwsA(isA<RaidNotRecoverableException>()),
      );

      await raid.dispose();
    });

    test('read fails when a disk is failed', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data = Uint8List.fromList(List.generate(900, (i) => i % 256));
      await raid.write('striped.bin', data);

      raid.simulateDiskFailure(1);

      expect(
        () => raid.read('striped.bin'),
        throwsA(isA<DiskFailedException>()),
      );

      await raid.dispose();
    });
  });

  group('RAID 0 – large file', () {
    test('round-trips a 1 MiB file correctly', () async {
      final raid = makeRaid();
      await raid.initialize();

      final data =
          Uint8List.fromList(List.generate(1024 * 1024, (i) => (i * 3) % 256));
      await raid.write('large.bin', data);
      final readBack = await raid.read('large.bin');
      expect(readBack, equals(data));

      await raid.dispose();
    });
  });
}
