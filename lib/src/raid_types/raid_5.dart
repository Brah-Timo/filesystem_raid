/// RAID 5 — distributed parity striping.
library filesystem_raid.raid_types.raid_5;

import 'dart:async';
import 'dart:typed_data';

import '../../models/chunk_metadata.dart';
import '../../models/disk_status.dart';
import '../../models/raid_config.dart';
import '../../models/recovery_report.dart';
import '../exceptions/raid_exceptions.dart';
import '../parity/parity_calculator.dart';
import '../parity/parity_recovery.dart';
import '../storage/disk_manager.dart';
import '../utils/chunk_splitter.dart';
import '../utils/logger.dart';
import 'raid_strategy.dart';

// ---------------------------------------------------------------------------
// Raid5
// ---------------------------------------------------------------------------

/// RAID 5 implementation.
///
/// **Characteristics**:
/// - Data is split into N-1 equal chunks distributed across N disks.
/// - One parity chunk per stripe is computed from the data chunks and
///   written to a **rotating** disk (left-symmetric rotation).
/// - Survives the failure of exactly **1** disk (more with Reed-Solomon).
/// - Storage efficiency: (N-1)/N  (e.g. 67 % for 3 disks, 75 % for 4).
///
/// **Best suited for**: NAS arrays, small servers, or any workload that
/// requires a balance of performance, capacity, and fault tolerance.
///
/// **Stripe layout** (3 disks):
/// ```
/// Stripe 0:  D0 | D1 | P
/// Stripe 1:  D0 | P  | D1
/// Stripe 2:  P  | D0 | D1
/// ```
class Raid5 implements RaidStrategy {
  /// Creates a [Raid5] strategy.
  Raid5({
    required this.diskManager,
    required this.config,
    required RaidLogger logger,
  })  : _log = logger,
        _recovery = ParityRecovery(config: config);

  /// The shared disk I/O manager.
  final DiskManager diskManager;

  /// RAID configuration.
  final RaidConfig config;

  final RaidLogger _log;
  final ParityRecovery _recovery;

  // ── Internal constants ────────────────────────────────────────────────────

  /// Number of data disks per stripe = total disks - 1 parity disk.
  int get _dataDiskCount => diskManager.diskCount - 1;

  // ── Write ─────────────────────────────────────────────────────────────────

  @override
  Future<void> write(String filename, Uint8List data) async {
    _log.info('RAID 5: writing "$filename" '
        '(${data.length} bytes, ${diskManager.diskCount} disks)');

    final op = OperationLogger(_log, 'RAID5.write[$filename]');

    // 1. Split into data chunks (one per data disk).
    final rawChunks = ChunkSplitter.split(data, _dataDiskCount);
    final equalised = ChunkSplitter.equaliseLength(rawChunks);

    // 2. Compute parity.
    final parity = _recovery.computeParity(equalised);

    // 3. Determine which disk holds parity for this "stripe 0"
    //    (single-file write treats the entire file as stripe 0).
    final parityDisk = ParityCalculator.parityDiskIndex(0, diskManager.diskCount);

    _log.debug('Parity disk for "$filename": $parityDisk');

    // 4. Assign data/parity to physical disk indexes.
    //    Data disks are all disks except the parity disk, in order.
    final dataDisks = [
      for (var i = 0; i < diskManager.diskCount; i++)
        if (i != parityDisk) i,
    ];

    assert(dataDisks.length == _dataDiskCount);

    // 5. Write data chunks and parity in parallel.
    final futures = <Future<void>>[];

    for (var ci = 0; ci < _dataDiskCount; ci++) {
      final diskIndex = dataDisks[ci];
      futures.add(diskManager.writeChunk(
        diskIndex: diskIndex,
        filename: filename,
        raw: rawChunks[ci],  // original (un-padded) for metadata
        chunkIndex: ci,
        totalChunks: _dataDiskCount,
        isParity: false,
        totalFileSize: data.length,
      ));
    }

    // Parity chunk on the parity disk.
    futures.add(diskManager.writeChunk(
      diskIndex: parityDisk,
      filename: filename,
      raw: parity,
      chunkIndex: 0,
      totalChunks: _dataDiskCount,
      isParity: true,
      totalFileSize: data.length,
    ));

    await Future.wait(futures);

    op.done(extra: '$_dataDiskCount data + 1 parity chunks');
  }

  // ── Read ──────────────────────────────────────────────────────────────────

  @override
  Future<Uint8List> read(String filename) async {
    _log.info('RAID 5: reading "$filename"');
    final op = OperationLogger(_log, 'RAID5.read[$filename]');

    if (!diskManager.fileExists(filename)) {
      throw RaidFileNotFoundException(
        'File not found in RAID 5 array.',
        filename: filename,
      );
    }

    final parityDisk =
        ParityCalculator.parityDiskIndex(0, diskManager.diskCount);

    final dataDisks = [
      for (var i = 0; i < diskManager.diskCount; i++)
        if (i != parityDisk) i,
    ];

    // 1. Read data chunks in parallel.
    final chunkFutures = [
      for (var ci = 0; ci < _dataDiskCount; ci++)
        diskManager.readChunk(
          diskIndex: dataDisks[ci],
          filename: filename,
          chunkIndex: ci,
        ),
    ];
    final parityFuture = diskManager.readChunk(
      diskIndex: parityDisk,
      filename: filename,
      chunkIndex: 0,
      isParity: true,
    );

    final chunkResults = await Future.wait(chunkFutures);
    final parityResult = await parityFuture;

    final missingDataCount = chunkResults.where((c) => c == null).length;

    // 2. Recover missing chunks if possible.
    List<Uint8List> dataChunks;
    if (missingDataCount == 0) {
      dataChunks = chunkResults.cast<Uint8List>();
    } else if (parityResult == null && missingDataCount > 0) {
      // Both parity and at least one data chunk are missing — unrecoverable.
      throw TooManyDiskFailuresException(
        'RAID 5 read failed: parity disk $parityDisk and at least one data '
        'disk are both unreadable for "$filename".',
        failedCount: missingDataCount + 1,
        toleratedCount: 1,
      );
    } else {
      _log.warning('RAID 5: recovering $missingDataCount missing '
          'chunk(s) for "$filename" using parity');
      try {
        dataChunks = _recovery.recoverChunks(
          chunks: chunkResults,
          parity: parityResult!,
        );
      } on TooManyDiskFailuresException {
        rethrow;
      } catch (e) {
        throw RaidRecoveryException(
          'Parity recovery failed for "$filename": $e',
          filename: filename,
          cause: e,
        );
      }
    }

    // 3. Get original total file length from any available chunk metadata.
    // totalFileSize holds the whole-file length directly (added in v1).
    // Fall back to summing per-chunk originalSize for legacy chunks.
    int? originalLength;
    for (var ci = 0; ci < _dataDiskCount && originalLength == null; ci++) {
      final m = await diskManager.readChunkMeta(
        diskIndex: dataDisks[ci],
        filename: filename,
        chunkIndex: ci,
      );
      if (m != null) {
        if (m.totalFileSize != null) {
          originalLength = m.totalFileSize;
        }
      }
    }
    if (originalLength == null) {
      // Legacy fallback: sum per-chunk originalSize values.
      final allMeta = await Future.wait([
        for (var ci = 0; ci < _dataDiskCount; ci++)
          diskManager.readChunkMeta(
            diskIndex: dataDisks[ci],
            filename: filename,
            chunkIndex: ci,
          ),
      ]);
      final valid = allMeta.whereType<ChunkMetadata>().toList();
      if (valid.isNotEmpty) {
        originalLength = valid.fold<int>(0, (s, m) => s + m.originalSize);
      }
    }

    final merged = ChunkSplitter.merge(dataChunks, originalLength: originalLength);
    op.done(extra: '${merged.length} bytes');
    return merged;
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  @override
  Future<void> delete(String filename) async {
    _log.info('RAID 5: deleting "$filename"');
    await diskManager.deleteAllChunks(filename, _dataDiskCount);
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
    _log.info('RAID 5: starting recovery scan…');
    final report = RecoveryReport();

    final statuses = await diskManager.refreshStatus();
    final failedDisks = [
      for (var i = 0; i < statuses.length; i++)
        if (statuses[i].isFailed) i,
    ];

    if (failedDisks.isEmpty) {
      _log.info('RAID 5: all disks healthy — no recovery needed.');
      report.finish(RecoveryStatus.notRequired);
      return report;
    }

    if (failedDisks.length > 1) {
      final msg = 'RAID 5 cannot recover — ${failedDisks.length} disks failed '
          '(only 1 tolerated).';
      for (final d in failedDisks) {
        report.addFailedDisk(d, msg);
      }
      report.finish(RecoveryStatus.failed);
      return report;
    }

    final failedDisk = failedDisks.first;
    _log.info('RAID 5: rebuilding disk $failedDisk…');

    final parityDisk =
        ParityCalculator.parityDiskIndex(0, diskManager.diskCount);
    final isParityDisk = failedDisk == parityDisk;

    final files = diskManager.listFiles();
    await diskManager.markDiskOnline(failedDisk);

    for (final filename in files) {
      try {
        await _rebuildFile(
          filename: filename,
          failedDisk: failedDisk,
          parityDisk: parityDisk,
          isParityDisk: isParityDisk,
          report: report,
        );
      } catch (e, st) {
        _log.error('RAID 5: recovery of "$filename" failed', e, st);
        report.addFileError(filename, e.toString());
      }
    }

    report.addRecoveredDisk(failedDisk);

    final status = report.errors.isEmpty
        ? RecoveryStatus.success
        : RecoveryStatus.partial;
    report.finish(status);
    _log.info('RAID 5: recovery done.\n${report.summary()}');
    return report;
  }

  // ── Private rebuild logic ─────────────────────────────────────────────────

  Future<void> _rebuildFile({
    required String filename,
    required int failedDisk,
    required int parityDisk,
    required bool isParityDisk,
    required RecoveryReport report,
  }) async {
    final dataDisks = [
      for (var i = 0; i < diskManager.diskCount; i++)
        if (i != parityDisk) i,
    ];

    if (isParityDisk) {
      // Rebuild parity from all data chunks.
      final chunkFutures = [
        for (var ci = 0; ci < _dataDiskCount; ci++)
          diskManager.readChunk(
            diskIndex: dataDisks[ci],
            filename: filename,
            chunkIndex: ci,
          ),
      ];
      final chunks = await Future.wait(chunkFutures);
      final available =
          chunks.where((c) => c != null).cast<Uint8List>().toList();

      final newParity = _recovery.computeParity(
          ChunkSplitter.equaliseLength(available));

      await diskManager.rebuildChunk(
        diskIndex: failedDisk,
        filename: filename,
        chunkIndex: 0,
        totalChunks: _dataDiskCount,
        recovered: newParity,
        isParity: true,
      );

      report.addRecoveredFile(RecoveredFile(
        filename: filename,
        fromDiskIndex: dataDisks.first,
        toDiskIndex: failedDisk,
        bytesRecovered: newParity.length,
        verified: config.writeVerification,
      ));
    } else {
      // Rebuild the missing data chunk from remaining data + parity.
      final failedChunkIndex =
          dataDisks.indexOf(failedDisk);

      final chunkFutures = [
        for (var ci = 0; ci < _dataDiskCount; ci++)
          if (dataDisks[ci] != failedDisk)
            diskManager.readChunk(
              diskIndex: dataDisks[ci],
              filename: filename,
              chunkIndex: ci,
            )
          else
            Future<Uint8List?>.value(null),
      ];
      final parityFuture = diskManager.readChunk(
        diskIndex: parityDisk,
        filename: filename,
        chunkIndex: 0,
        isParity: true,
      );

      final chunks = await Future.wait(chunkFutures);
      final parityData = await parityFuture;

      if (parityData == null) {
        throw RaidRecoveryException(
          'Cannot rebuild disk $failedDisk — parity disk $parityDisk is '
          'also unreadable for "$filename".',
          filename: filename,
        );
      }

      final recovered = _recovery.recoverChunks(
        chunks: chunks,
        parity: parityData,
      );

      final rebuiltChunk = recovered[failedChunkIndex];
      await diskManager.rebuildChunk(
        diskIndex: failedDisk,
        filename: filename,
        chunkIndex: failedChunkIndex,
        totalChunks: _dataDiskCount,
        recovered: rebuiltChunk,
      );

      report.addRecoveredFile(RecoveredFile(
        filename: filename,
        fromDiskIndex: parityDisk,
        toDiskIndex: failedDisk,
        bytesRecovered: rebuiltChunk.length,
        verified: config.writeVerification,
      ));
    }
  }
}
