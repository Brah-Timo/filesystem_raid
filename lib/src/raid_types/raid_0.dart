/// RAID 0 — pure striping, maximum throughput, zero redundancy.
library filesystem_raid.raid_types.raid_0;

import 'dart:async';
import 'dart:typed_data';

import '../../models/chunk_metadata.dart';
import '../../models/disk_status.dart';
import '../../models/raid_config.dart';
import '../../models/recovery_report.dart';
import '../exceptions/raid_exceptions.dart';
import '../storage/disk_manager.dart';
import '../utils/chunk_splitter.dart';
import '../utils/logger.dart';
import 'raid_strategy.dart';

// ---------------------------------------------------------------------------
// Raid0
// ---------------------------------------------------------------------------

/// RAID 0 implementation.
///
/// **Characteristics**:
/// - Data is split into equal-size chunks, one per disk.
/// - Reads and writes run in parallel across all disks.
/// - No parity, no redundancy — loss of ANY disk = loss of ALL data.
/// - Storage efficiency: 100 %.
/// - Fault tolerance: 0 disk failures.
///
/// **Best suited for**: scratch space, caches, or any workload where speed
/// matters and the data is disposable or backed up elsewhere.
class Raid0 implements RaidStrategy {
  /// Creates a [Raid0] strategy.
  Raid0({
    required this.diskManager,
    required this.config,
    required RaidLogger logger,
  }) : _log = logger;

  /// The shared disk I/O manager.
  final DiskManager diskManager;

  /// RAID configuration.
  final RaidConfig config;

  final RaidLogger _log;

  // ── Write ─────────────────────────────────────────────────────────────────

  @override
  Future<void> write(String filename, Uint8List data) async {
    _log.info('RAID 0: writing "$filename" (${data.length} bytes) '
        'across ${diskManager.diskCount} disks');

    final op = OperationLogger(_log, 'RAID0.write[$filename]');

    final chunks = ChunkSplitter.split(data, diskManager.diskCount);

    // Write all chunks in parallel.
    await Future.wait([
      for (var i = 0; i < diskManager.diskCount; i++)
        diskManager.writeChunk(
          diskIndex: i,
          filename: filename,
          raw: chunks[i],
          chunkIndex: i,
          totalChunks: diskManager.diskCount,
          totalFileSize: data.length,
        ),
    ]);

    op.done(extra: '${diskManager.diskCount} parallel writes');
  }

  // ── Read ──────────────────────────────────────────────────────────────────

  @override
  Future<Uint8List> read(String filename) async {
    _log.info('RAID 0: reading "$filename"');
    final op = OperationLogger(_log, 'RAID0.read[$filename]');

    if (!diskManager.fileExists(filename)) {
      throw RaidFileNotFoundException(
        'File not found in RAID 0 array.',
        filename: filename,
      );
    }

    // Read all chunks in parallel.
    final futures = [
      for (var i = 0; i < diskManager.diskCount; i++)
        diskManager.readChunk(
          diskIndex: i,
          filename: filename,
          chunkIndex: i,
        ),
    ];
    final results = await Future.wait(futures);

    // RAID 0 has no recovery — any null means we've lost the data.
    for (var i = 0; i < results.length; i++) {
      if (results[i] == null) {
        throw DiskFailedException(
          'RAID 0 cannot recover — chunk $i is missing or unreadable.',
          diskIndex: i,
          diskPath: diskManager.diskPaths[i],
        );
      }
    }

    final chunks = results.cast<Uint8List>();

    // Retrieve original total file length from chunk 0's metadata.
    // totalFileSize was added to store the whole-file length directly.
    // Fall back to summing per-chunk originalSize for backwards-compat.
    final meta = await diskManager.readChunkMeta(
      diskIndex: 0,
      filename: filename,
      chunkIndex: 0,
    );
    int? originalLength = meta?.totalFileSize;
    if (originalLength == null && meta != null) {
      // Legacy path: sum originalSize across all chunks.
      final allMeta = await Future.wait([
        for (var i = 0; i < diskManager.diskCount; i++)
          diskManager.readChunkMeta(
            diskIndex: i,
            filename: filename,
            chunkIndex: i,
          ),
      ]);
      final valid = allMeta.whereType<ChunkMetadata>().toList();
      if (valid.isNotEmpty) {
        originalLength = valid.fold<int>(0, (s, m) => s + m.originalSize);
      }
    }

    final merged = ChunkSplitter.merge(chunks, originalLength: originalLength);
    op.done(extra: '${merged.length} bytes');
    return merged;
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  @override
  Future<void> delete(String filename) async {
    _log.info('RAID 0: deleting "$filename"');
    await diskManager.deleteAllChunks(filename, diskManager.diskCount);
  }

  // ── File listing ──────────────────────────────────────────────────────────

  @override
  Future<Set<String>> listFiles() async => diskManager.listFiles();

  // ── Health ────────────────────────────────────────────────────────────────

  @override
  Future<List<DiskStatus>> checkHealth() async =>
      diskManager.refreshStatus();

  // ── Recovery ──────────────────────────────────────────────────────────────

  @override
  Future<RecoveryReport> recover() async {
    // RAID 0 has no redundancy — recovery is impossible.
    final report = RecoveryReport();
    report.finish(RecoveryStatus.failed);
    throw const RaidNotRecoverableException(
      'RAID 0 does not support data recovery. '
      'Any disk failure results in permanent data loss.',
    );
  }
}
