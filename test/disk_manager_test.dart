import 'dart:io';
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<String> diskPaths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('raid_disk_mgr_test_');
    diskPaths = [
      '${tempDir.path}/disk0',
      '${tempDir.path}/disk1',
      '${tempDir.path}/disk2',
    ];
    for (final p in diskPaths) {
      await Directory(p).create(recursive: true);
    }
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  RaidConfig makeConfig() => RaidConfig(
        type: RaidType.raid5,
        diskCount: 3,
        healthCheckInterval: Duration.zero,
        writeVerification: false,
      );

  group('DiskManager initialisation', () {
    test('creates directories if missing', () async {
      final extraPath = '${tempDir.path}/extra_disk';
      final mgr = DiskManager(
        diskPaths: [extraPath],
        config: RaidConfig(
          type: RaidType.raid0,
          diskCount: 1,
          healthCheckInterval: Duration.zero,
        ),
        logger: RaidLogger.silent(),
      );
      await mgr.initialize();
      expect(Directory(extraPath).existsSync(), isTrue);
    });

    test('detects healthy disks', () async {
      final mgr = DiskManager(
        diskPaths: diskPaths,
        config: makeConfig(),
        logger: RaidLogger.silent(),
      );
      await mgr.initialize();
      expect(mgr.activeDiskCount, equals(3));
      expect(mgr.failedDiskCount, equals(0));
    });
  });

  group('DiskManager write / read', () {
    late DiskManager mgr;

    setUp(() async {
      mgr = DiskManager(
        diskPaths: diskPaths,
        config: makeConfig(),
        logger: RaidLogger.silent(),
      );
      await mgr.initialize();
    });

    test('writes and reads a chunk', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      await mgr.writeChunk(
        diskIndex: 0,
        filename: 'test.bin',
        raw: data,
        chunkIndex: 0,
        totalChunks: 1,
      );
      final read = await mgr.readChunk(
        diskIndex: 0,
        filename: 'test.bin',
        chunkIndex: 0,
      );
      expect(read, equals(data));
    });

    test('returns null for non-existent chunk', () async {
      final result = await mgr.readChunk(
        diskIndex: 1,
        filename: 'nonexistent.bin',
        chunkIndex: 0,
      );
      expect(result, isNull);
    });

    test('registers file after write', () async {
      await mgr.writeChunk(
        diskIndex: 0,
        filename: 'reg_test.txt',
        raw: Uint8List.fromList([42]),
        chunkIndex: 0,
        totalChunks: 1,
      );
      expect(mgr.fileExists('reg_test.txt'), isTrue);
    });

    test('deletes all chunks for a file', () async {
      final data = Uint8List.fromList([9, 8, 7]);
      for (var i = 0; i < 3; i++) {
        await mgr.writeChunk(
          diskIndex: i,
          filename: 'del_test.bin',
          raw: data,
          chunkIndex: i,
          totalChunks: 3,
        );
      }
      expect(mgr.fileExists('del_test.bin'), isTrue);
      await mgr.deleteAllChunks('del_test.bin', 3);
      expect(mgr.fileExists('del_test.bin'), isFalse);
    });
  });

  group('DiskManager failure simulation', () {
    late DiskManager mgr;

    setUp(() async {
      mgr = DiskManager(
        diskPaths: diskPaths,
        config: makeConfig(),
        logger: RaidLogger.silent(),
      );
      await mgr.initialize();
    });

    test('simulated failure marks disk as failed', () {
      mgr.simulateDiskFailure(1);
      expect(mgr.statusOf(1).isFailed, isTrue);
      expect(mgr.failedDiskCount, equals(1));
    });

    test('reading from failed disk returns null', () async {
      // Write first.
      await mgr.writeChunk(
        diskIndex: 1,
        filename: 'fail_read.bin',
        raw: Uint8List.fromList([1, 2, 3]),
        chunkIndex: 1,
        totalChunks: 1,
      );
      mgr.simulateDiskFailure(1);
      final result = await mgr.readChunk(
        diskIndex: 1,
        filename: 'fail_read.bin',
        chunkIndex: 1,
      );
      expect(result, isNull);
    });
  });
}
