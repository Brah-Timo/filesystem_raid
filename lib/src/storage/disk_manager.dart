/// Physical disk access layer — reads, writes, health monitoring.
library filesystem_raid.storage.disk_manager;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../models/chunk_metadata.dart';
import '../../models/disk_status.dart';
import '../../models/raid_config.dart';
import '../exceptions/raid_exceptions.dart';
import '../utils/file_hasher.dart';
import '../utils/logger.dart';
import 'chunk_handler.dart';
import 'storage_info.dart';

// ---------------------------------------------------------------------------
// DiskManager
// ---------------------------------------------------------------------------

/// Manages all I/O to the individual disk directories that make up a RAID
/// array.
///
/// Responsibilities:
/// - Initialise disk directories on first use.
/// - Maintain live [DiskStatus] snapshots.
/// - Route chunk reads and writes through [ChunkHandler].
/// - Provide the registry of filenames known to the array.
class DiskManager {
  /// Creates a [DiskManager].
  DiskManager({
    required this.diskPaths,
    required this.config,
    required RaidLogger logger,
  })  : _log = logger,
        _handler = ChunkHandler(config: config, logger: logger);

  // ── Fields ────────────────────────────────────────────────────────────────

  /// Ordered list of root directories for each disk in the array.
  final List<String> diskPaths;

  /// RAID configuration (type, chunk size, compression, encryption…).
  final RaidConfig config;

  final RaidLogger _log;
  final ChunkHandler _handler;

  late List<DiskStatus> _statuses;
  late List<FileRegistry> _registries;

  /// Indexes that have been explicitly failed via [simulateDiskFailure].
  /// [refreshStatus] and [markDiskOnline] respect this set.
  final Set<int> _manuallyFailed = {};

  // ── Initialisation ────────────────────────────────────────────────────────

  /// Scans all disk directories, creates them if missing, and populates the
  /// initial [DiskStatus] list.
  Future<void> initialize() async {
    _log.info('DiskManager: initialising ${diskPaths.length} disks…');
    _statuses = [];
    _registries = [];

    for (var i = 0; i < diskPaths.length; i++) {
      final path = diskPaths[i];
      final status = await _probeDisk(i, path);
      _statuses.add(status);
      _registries.add(await FileRegistry.load(path));
      _log.debug('Disk $i ($path): ${status.health}');
    }

    _log.info('DiskManager: ${activeDiskCount} active, '
        '${failedDiskCount} failed.');
  }

  // ── Disk probing ──────────────────────────────────────────────────────────

  Future<DiskStatus> _probeDisk(int index, String path) async {
    final dir = Directory(path);
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        _log.info('Created disk directory: $path');
      }

      // Measure write latency with a tiny temp file.
      final sw = Stopwatch()..start();
      final probe = File('$path/.raid_probe_${DateTime.now().millisecondsSinceEpoch}');
      await probe.writeAsBytes([0x01]);
      final writeMs = sw.elapsedMilliseconds.toDouble();
      sw.reset();
      await probe.readAsBytes();
      final readMs = sw.elapsedMilliseconds.toDouble();
      await probe.delete();

      final (total, free) = await _diskSpace(path);

      return DiskStatus(
        path: path,
        diskIndex: index,
        health: DiskHealth.healthy,
        totalBytes: total,
        availableBytes: free,
        readLatencyMs: readMs,
        writeLatencyMs: writeMs,
        lastChecked: DateTime.now(),
      );
    } catch (e, st) {
      _log.error('Disk $index ($path) probe failed', e, st);
      return DiskStatus(
        path: path,
        diskIndex: index,
        health: DiskHealth.failed,
        totalBytes: 0,
        availableBytes: 0,
        errorLogs: [e.toString()],
        lastChecked: DateTime.now(),
      );
    }
  }

  // ── Public getters ────────────────────────────────────────────────────────

  /// Number of disks in the array.
  int get diskCount => diskPaths.length;

  /// Number of disks that are healthy or degraded.
  int get activeDiskCount => _statuses.where((s) => s.isReadable).length;

  /// Number of disks in the failed state.
  int get failedDiskCount => _statuses.where((s) => s.isFailed).length;

  /// Current snapshot for disk [index].
  DiskStatus statusOf(int index) => _statuses[index];

  /// All current disk status snapshots.
  List<DiskStatus> get allStatuses => List.unmodifiable(_statuses);

  // ── Chunk write ───────────────────────────────────────────────────────────

  /// Encodes [raw] through the pipeline and writes the result to disk [diskIndex].
  ///
  /// Throws [DiskFailedException] if the target disk is failed.
  /// Throws [InsufficientSpaceException] if the disk has insufficient space.
  Future<ChunkMetadata> writeChunk({
    required int diskIndex,
    required String filename,
    required Uint8List raw,
    required int chunkIndex,
    required int totalChunks,
    bool isParity = false,
    int? totalFileSize,
  }) async {
    _assertDiskAlive(diskIndex);

    final path = diskPaths[diskIndex];
    final encoded = _handler.encode(raw);
    final chunkFile = ChunkHandler.chunkPath(
      path, filename, chunkIndex,
      isParity: isParity,
    );

    // Space check.
    await _assertSufficientSpace(diskIndex, encoded.payload.length);

    // Write payload.
    await _writeWithRetry(chunkFile, encoded.payload);

    // Build metadata.
    final meta = ChunkMetadata(
      filename: filename,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      diskIndex: diskIndex,
      originalSize: raw.length,
      totalFileSize: totalFileSize,
      checksum: encoded.checksum,
      isParityChunk: isParity,
      compressed: encoded.compressed,
      encrypted: encoded.encrypted,
      raidType: config.type.name,
    );

    await _handler.writeMetadata(chunkFile, meta);

    // Optional write-back verification.
    if (config.writeVerification) {
      final readBack = await File(chunkFile).readAsBytes();
      if (!FileHasher.verify(readBack, encoded.checksum)) {
        throw CorruptedDataException(
          'Write-verification failed — on-disk data does not match written data.',
          filename: filename,
          diskIndex: diskIndex,
          chunkIndex: chunkIndex,
        );
      }
    }

    // Register filename.
    _registries[diskIndex].register(filename);
    await _registries[diskIndex].save(path);

    _log.debug('Wrote chunk $chunkIndex of "$filename" → disk $diskIndex');
    return meta;
  }

  // ── Chunk read ────────────────────────────────────────────────────────────

  /// Reads, decodes, and verifies chunk [chunkIndex] of [filename] from
  /// disk [diskIndex].
  ///
  /// Returns `null` if the chunk is absent (helps parity recovery).
  Future<Uint8List?> readChunk({
    required int diskIndex,
    required String filename,
    required int chunkIndex,
    bool isParity = false,
  }) async {
    if (_statuses[diskIndex].isFailed) return null;

    final chunkFile = ChunkHandler.chunkPath(
      diskPaths[diskIndex], filename, chunkIndex,
      isParity: isParity,
    );
    final file = File(chunkFile);
    if (!await file.exists()) {
      _log.debug('Chunk not found: $chunkFile');
      return null;
    }

    try {
      final payload = await file.readAsBytes();
      final meta = await _handler.readMetadata(chunkFile);

      return _handler.decode(
        payload,
        expectedChecksum: meta.checksum,
        compressed: meta.compressed,
        encrypted: meta.encrypted,
        filename: filename,
      );
    } catch (e, st) {
      _log.warning('Error reading chunk $chunkIndex from disk $diskIndex', e, st);
      return null;
    }
  }

  /// Reads chunk metadata without reading the full payload.
  Future<ChunkMetadata?> readChunkMeta({
    required int diskIndex,
    required String filename,
    required int chunkIndex,
    bool isParity = false,
  }) async {
    if (_statuses[diskIndex].isFailed) return null;
    final chunkFile = ChunkHandler.chunkPath(
      diskPaths[diskIndex], filename, chunkIndex,
      isParity: isParity,
    );
    if (!await File(chunkFile).exists()) return null;
    try {
      return await _handler.readMetadata(chunkFile);
    } catch (_) {
      return null;
    }
  }

  // ── Chunk delete ──────────────────────────────────────────────────────────

  /// Deletes all on-disk chunks for [filename] across all disks.
  Future<void> deleteAllChunks(String filename, int totalChunks) async {
    for (var diskIndex = 0; diskIndex < diskCount; diskIndex++) {
      if (_statuses[diskIndex].isFailed) continue;
      for (var ci = 0; ci < totalChunks; ci++) {
        await _deleteChunkFile(diskIndex, filename, ci);
      }
      // Remove parity file too.
      await _deleteChunkFile(diskIndex, filename, 0, isParity: true);
      _registries[diskIndex].deregister(filename);
      await _registries[diskIndex].save(diskPaths[diskIndex]);
    }
    _log.info('Deleted all chunks for "$filename"');
  }

  Future<void> _deleteChunkFile(
    int diskIndex,
    String filename,
    int chunkIndex, {
    bool isParity = false,
  }) async {
    final path = ChunkHandler.chunkPath(
      diskPaths[diskIndex], filename, chunkIndex,
      isParity: isParity,
    );
    final f = File(path);
    if (await f.exists()) await f.delete();
    final m = File('$path.meta');
    if (await m.exists()) await m.delete();
  }

  // ── Rebuild (recovery) ────────────────────────────────────────────────────

  /// Writes [recovered] data as chunk [chunkIndex] to a previously failed
  /// disk that is now back online.
  Future<void> rebuildChunk({
    required int diskIndex,
    required String filename,
    required int chunkIndex,
    required int totalChunks,
    required Uint8List recovered,
    bool isParity = false,
    int? totalFileSize,
  }) async {
    _log.info('Rebuilding chunk $chunkIndex of "$filename" on disk $diskIndex');
    await writeChunk(
      diskIndex: diskIndex,
      filename: filename,
      raw: recovered,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      isParity: isParity,
      totalFileSize: totalFileSize,
    );
  }

  // ── File listing ──────────────────────────────────────────────────────────

  /// Returns the union of all filenames known to any healthy disk.
  Set<String> listFiles() {
    final files = <String>{};
    for (var i = 0; i < diskCount; i++) {
      if (!_statuses[i].isFailed) {
        files.addAll(_registries[i].files);
      }
    }
    return files;
  }

  /// Returns `true` when [filename] is registered on at least one healthy disk.
  bool fileExists(String filename) =>
      listFiles().contains(filename);

  /// Returns `true` when [filename] is registered on **any** disk,
  /// regardless of its health state.  Used by RAID 1 read to distinguish
  /// "file was never written" from "file exists but all mirrors are failed".
  bool fileExistsAny(String filename) {
    for (var i = 0; i < diskCount; i++) {
      if (_registries[i].contains(filename)) return true;
    }
    return false;
  }

  // ── Health check ──────────────────────────────────────────────────────────

  /// Refreshes disk status snapshots and returns the updated list.
  ///
  /// Disks that were explicitly failed via [simulateDiskFailure] are **not**
  /// re-probed — their failed status is preserved until [markDiskOnline] is
  /// called.
  Future<List<DiskStatus>> refreshStatus() async {
    for (var i = 0; i < diskPaths.length; i++) {
      if (_manuallyFailed.contains(i)) continue; // keep simulated failure
      _statuses[i] = await _probeDisk(i, diskPaths[i]);
    }
    return allStatuses;
  }

  /// Marks disk [index] as failed (used in tests or manual override).
  ///
  /// The failure is **sticky**: subsequent calls to [refreshStatus] will not
  /// clear it.  Only [markDiskOnline] removes the override.
  void simulateDiskFailure(int index) {
    _manuallyFailed.add(index);
    _statuses[index] = _statuses[index].copyWith(health: DiskHealth.failed);
    _log.warning('⚠ Disk $index manually marked as FAILED (simulation)');
  }

  /// Marks disk [index] as healthy (used after replacing a disk).
  ///
  /// Also clears any [simulateDiskFailure] override for this index.
  Future<void> markDiskOnline(int index) async {
    _manuallyFailed.remove(index);
    _statuses[index] = await _probeDisk(index, diskPaths[index]);
    _log.info('Disk $index back online: ${_statuses[index].health}');
  }

  // ── StorageInfo ───────────────────────────────────────────────────────────

  /// Computes and returns aggregate [StorageInfo] for the array.
  StorageInfo computeStorageInfo() =>
      StorageInfo.fromDiskStatuses(_statuses, config.type);

  // ── Private helpers ───────────────────────────────────────────────────────

  void _assertDiskAlive(int index) {
    if (_statuses[index].isFailed) {
      throw DiskFailedException(
        'Disk $index is in a failed state.',
        diskIndex: index,
        diskPath: diskPaths[index],
      );
    }
  }

  Future<void> _assertSufficientSpace(int index, int bytesNeeded) async {
    final avail = _statuses[index].availableBytes;
    if (avail < bytesNeeded) {
      throw InsufficientSpaceException(
        'Disk $index has insufficient space.',
        diskIndex: index,
        requiredBytes: bytesNeeded,
        availableBytes: avail,
      );
    }
  }

  Future<void> _writeWithRetry(String path, Uint8List data) async {
    for (var attempt = 1; attempt <= config.maxRetries; attempt++) {
      try {
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data, flush: true);
        return;
      } catch (e) {
        if (attempt == config.maxRetries) rethrow;
        _log.warning('Write attempt $attempt/$config.maxRetries failed: $e');
        await Future<void>.delayed(
            Duration(milliseconds: 100 * attempt));
      }
    }
  }

  /// Returns (totalBytes, freeBytes) for the filesystem hosting [path].
  ///
  /// Falls back to dummy values on platforms that don't expose statvfs.
  Future<(int, int)> _diskSpace(String path) async {
    try {
      // `df` gives us 512-byte blocks on POSIX; parse the output.
      final result = await Process.run(
        'df',
        ['-k', '--output=size,avail', path],
        runInShell: true,
      );
      if (result.exitCode == 0) {
        final lines = (result.stdout as String).trim().split('\n');
        if (lines.length >= 2) {
          final parts = lines.last.trim().split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            final total = int.tryParse(parts[0]) ?? 0;
            final free = int.tryParse(parts[1]) ?? 0;
            return (total * 1024, free * 1024);
          }
        }
      }
    } catch (_) {
      // Ignore — use fallback.
    }
    // Fallback: report 1 TiB total / 512 GiB free (non-POSIX environments).
    return (1 * 1024 * 1024 * 1024 * 1024, 512 * 1024 * 1024 * 1024);
  }
}
