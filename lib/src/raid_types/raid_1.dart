/// RAID 1 — full mirroring, maximum redundancy.
library filesystem_raid.raid_types.raid_1;

import 'dart:async';
import 'dart:typed_data';

import '../../models/disk_status.dart';
import '../../models/raid_config.dart';
import '../../models/recovery_report.dart';
import '../exceptions/raid_exceptions.dart';
import '../storage/disk_manager.dart';
import '../utils/logger.dart';
import 'raid_strategy.dart';

// ---------------------------------------------------------------------------
// Raid1
// ---------------------------------------------------------------------------

/// RAID 1 implementation.
///
/// **Characteristics**:
/// - Every file is written identically to ALL disks in the array.
/// - Reads are served from the first available (healthy) disk.
/// - Survives the failure of up to `diskCount - 1` disks.
/// - Storage efficiency: 1 / diskCount (e.g. 50 % for a 2-disk mirror).
///
/// **Best suited for**: operating system volumes, critical configuration files,
/// or anything where maximum read availability and fault tolerance matter more
/// than raw storage capacity.
class Raid1 implements RaidStrategy {
  /// Creates a [Raid1] strategy.
  Raid1({
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
    _log.info('RAID 1: mirroring "$filename" (${data.length} bytes) '
        'to ${diskManager.diskCount} disks');

    final op = OperationLogger(_log, 'RAID1.write[$filename]');

    // Attempt all disks; record which ones succeed.
    final writeErrors = <int, Object>{};
    await Future.wait([
      for (var i = 0; i < diskManager.diskCount; i++)
        _tryWrite(i, filename, data, errors: writeErrors),
    ]);

    // At least one disk must have accepted the write.
    if (writeErrors.length == diskManager.diskCount) {
      throw RaidRecoveryException(
        'RAID 1 write failed: every disk rejected the write for "$filename".',
        filename: filename,
      );
    }

    if (writeErrors.isNotEmpty) {
      _log.warning('RAID 1: ${writeErrors.length} disk(s) failed during '
          'write of "$filename"; data is still safe on '
          '${diskManager.diskCount - writeErrors.length} disk(s).');
    }

    op.done(
        extra: '${diskManager.diskCount - writeErrors.length} mirrors written');
  }

  Future<void> _tryWrite(
    int diskIndex,
    String filename,
    Uint8List data, {
    required Map<int, Object> errors,
  }) async {
    try {
      // In RAID 1 the "chunk" IS the whole file — chunkIndex 0, totalChunks 1.
      await diskManager.writeChunk(
        diskIndex: diskIndex,
        filename: filename,
        raw: data,
        chunkIndex: 0,
        totalChunks: 1,
      );
    } catch (e) {
      _log.warning('RAID 1: disk $diskIndex write error for "$filename": $e');
      errors[diskIndex] = e;
    }
  }

  // ── Read ──────────────────────────────────────────────────────────────────

  @override
  Future<Uint8List> read(String filename) async {
    _log.info('RAID 1: reading "$filename"');
    final op = OperationLogger(_log, 'RAID1.read[$filename]');

    // Check that at least one disk (healthy or not) knows this file.
    // We use the full registry union including failed disks so that a
    // "all disks failed" scenario throws RaidRecoveryException rather than
    // RaidFileNotFoundException.
    final knownOnAnyDisk = diskManager.fileExistsAny(filename);
    if (!knownOnAnyDisk) {
      throw RaidFileNotFoundException(
        'File not found in RAID 1 array.',
        filename: filename,
      );
    }

    // Try each disk in order; return on the first success.
    Object? lastError;
    for (var i = 0; i < diskManager.diskCount; i++) {
      try {
        final data = await diskManager.readChunk(
          diskIndex: i,
          filename: filename,
          chunkIndex: 0,
        );
        if (data != null) {
          op.done(extra: 'read from disk $i');
          return data;
        }
      } catch (e) {
        lastError = e;
        _log.debug('RAID 1: disk $i unreadable for "$filename": $e');
        continue;
      }
    }

    throw RaidRecoveryException(
      'RAID 1 read failed: no readable mirror found for "$filename".',
      filename: filename,
      cause: lastError,
    );
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  @override
  Future<void> delete(String filename) async {
    _log.info('RAID 1: deleting "$filename" from all mirrors');
    await diskManager.deleteAllChunks(filename, 1);
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
    _log.info('RAID 1: starting recovery scan…');
    final report = RecoveryReport();

    final statuses = await diskManager.refreshStatus();
    final failedDisks = [
      for (var i = 0; i < statuses.length; i++)
        if (statuses[i].isFailed) i,
    ];

    if (failedDisks.isEmpty) {
      _log.info('RAID 1: all disks healthy — no recovery needed.');
      report.finish(RecoveryStatus.notRequired);
      return report;
    }

    // Check that at least one donor disk is healthy.
    final healthyDisks = [
      for (var i = 0; i < statuses.length; i++)
        if (statuses[i].isReadable) i,
    ];

    if (healthyDisks.isEmpty) {
      report.addFileError('<all>', 'No healthy mirror to recover from.');
      report.finish(RecoveryStatus.failed);
      return report;
    }

    final donorIndex = healthyDisks.first;
    final files = diskManager.listFiles();

    for (final filename in files) {
      for (final failedIndex in failedDisks) {
        try {
          final data = await diskManager.readChunk(
            diskIndex: donorIndex,
            filename: filename,
            chunkIndex: 0,
          );
          if (data == null) {
            report.addFileError(filename, 'Donor disk $donorIndex returned null.');
            continue;
          }

          await diskManager.markDiskOnline(failedIndex);
          await diskManager.rebuildChunk(
            diskIndex: failedIndex,
            filename: filename,
            chunkIndex: 0,
            totalChunks: 1,
            recovered: data,
          );

          report.addRecoveredFile(RecoveredFile(
            filename: filename,
            fromDiskIndex: donorIndex,
            toDiskIndex: failedIndex,
            bytesRecovered: data.length,
            verified: config.writeVerification,
          ));
        } catch (e, st) {
          _log.error(
              'RAID 1: failed to recover "$filename" on disk $failedIndex',
              e, st);
          report.addFileError(filename, e.toString());
        }
      }
    }

    for (final i in failedDisks) {
      if (!report.failedDiskIndexes.contains(i)) {
        report.addRecoveredDisk(i);
      }
    }

    final status = report.failedDiskIndexes.isEmpty
        ? RecoveryStatus.success
        : (report.recoveredDiskIndexes.isNotEmpty
            ? RecoveryStatus.partial
            : RecoveryStatus.failed);

    report.finish(status);
    _log.info('RAID 1: recovery complete — ${report.summary()}');
    return report;
  }
}
