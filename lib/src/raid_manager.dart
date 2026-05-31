/// Main public API — FilesystemRaid orchestrates the entire RAID system.
library filesystem_raid.raid_manager;

import 'dart:async';
import 'dart:typed_data';

import '../models/disk_status.dart';
import '../models/raid_config.dart';
import '../models/recovery_report.dart';
import 'exceptions/raid_exceptions.dart';
import 'raid_types/raid_0.dart';
import 'raid_types/raid_1.dart';
import 'raid_types/raid_5.dart';
import 'raid_types/raid_strategy.dart';
import 'storage/disk_manager.dart';
import 'storage/storage_info.dart';
import 'utils/logger.dart';

// ---------------------------------------------------------------------------
// FilesystemRaid
// ---------------------------------------------------------------------------

/// **Top-level entry point** for the filesystem_raid package.
///
/// Creates and manages a RAID array backed by local filesystem directories
/// (one directory per physical or virtual disk).
///
/// ### Minimal example
/// ```dart
/// final raid = FilesystemRaid(
///   diskPaths: ['/mnt/d1', '/mnt/d2', '/mnt/d3'],
///   config: const RaidConfig(type: RaidType.raid5, diskCount: 3),
/// );
/// await raid.initialize();
///
/// await raid.write('backup.tar.gz', data);
/// final restored = await raid.read('backup.tar.gz');
///
/// final report = await raid.recover();
/// print(report.summary());
///
/// await raid.dispose();
/// ```
class FilesystemRaid {
  /// Creates a [FilesystemRaid] instance.
  ///
  /// [diskPaths]  — list of directory paths (one per physical disk).
  ///                Must have at least 2 elements (3 for RAID 5).
  /// [config]     — RAID configuration.
  FilesystemRaid({
    required List<String> diskPaths,
    required RaidConfig config,
  })  : _diskPaths = List.unmodifiable(diskPaths),
        _config = config {
    _validateConstructorArgs();
    _log = RaidLogger(config.logLevel);
    _diskManager = DiskManager(
      diskPaths: diskPaths,
      config: config,
      logger: _log,
    );
  }

  // ── Fields ────────────────────────────────────────────────────────────────

  final List<String> _diskPaths;
  final RaidConfig _config;

  late final RaidLogger _log;
  late final DiskManager _diskManager;
  late RaidStrategy _strategy;

  bool _initialised = false;
  Timer? _healthTimer;

  // ── Initialisation ────────────────────────────────────────────────────────

  /// Initialises the RAID array.
  ///
  /// Must be called **once** before any other method.
  /// Creates disk directories if they do not exist, scans disk health, and
  /// starts the optional background health-check timer.
  ///
  /// Throws [RaidConfigurationException] on invalid configuration.
  Future<void> initialize() async {
    if (_initialised) return;

    _log.info('FilesystemRaid: initialising ${_config.type.name.toUpperCase()} '
        'with ${_diskPaths.length} disks…');

    await _diskManager.initialize();
    _strategy = _buildStrategy();
    _startHealthTimer();

    _initialised = true;
    _log.info('FilesystemRaid: ready. ${_diskManager.computeStorageInfo()}');
  }

  // ── Write ─────────────────────────────────────────────────────────────────

  /// Writes [data] as logical file [filename] into the RAID array.
  ///
  /// The method is idempotent: writing the same [filename] twice overwrites
  /// the previous version.
  ///
  /// Throws [RaidConfigurationException] if [initialize] has not been called.
  Future<void> write(String filename, Uint8List data) async {
    _assertInitialised();
    _log.info('write: "$filename" (${_humanBytes(data.length)})');
    await _strategy.write(filename, data);
  }

  // ── Read ──────────────────────────────────────────────────────────────────

  /// Reads and returns the content of [filename] from the RAID array.
  ///
  /// When a disk has failed and the RAID level supports recovery, the missing
  /// data is silently reconstructed from parity or mirror copies.
  ///
  /// Throws [RaidFileNotFoundException] if [filename] is not in the array.
  Future<Uint8List> read(String filename) async {
    _assertInitialised();
    _log.info('read: "$filename"');
    return _strategy.read(filename);
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Removes all on-disk data for [filename] from every disk in the array.
  Future<void> delete(String filename) async {
    _assertInitialised();
    _log.info('delete: "$filename"');
    await _strategy.delete(filename);
  }

  // ── File listing ──────────────────────────────────────────────────────────

  /// Returns the set of all logical filenames stored in the array.
  Future<Set<String>> listFiles() async {
    _assertInitialised();
    return _strategy.listFiles();
  }

  /// Returns `true` when [filename] exists in the array.
  Future<bool> fileExists(String filename) async {
    _assertInitialised();
    return _diskManager.fileExists(filename);
  }

  // ── Health ────────────────────────────────────────────────────────────────

  /// Returns live [DiskStatus] snapshots for every disk.
  ///
  /// Re-probes each disk directory so the result reflects the current state.
  Future<List<DiskStatus>> checkDiskHealth() async {
    _assertInitialised();
    return _strategy.checkHealth();
  }

  /// Returns aggregated [StorageInfo] (capacity, utilisation, etc.).
  StorageInfo storageInfo() {
    _assertInitialised();
    return _diskManager.computeStorageInfo();
  }

  // ── Recovery ──────────────────────────────────────────────────────────────

  /// Scans for failed disks and attempts to rebuild them.
  ///
  /// Returns a [RecoveryReport] describing what was recovered (or not).
  ///
  /// - **RAID 0**: throws [RaidNotRecoverableException] immediately.
  /// - **RAID 1**: copies data from any healthy mirror.
  /// - **RAID 5**: reconstructs missing chunks using XOR/Reed-Solomon parity.
  Future<RecoveryReport> recover() async {
    _assertInitialised();
    _log.info('recover: starting…');
    final report = await _strategy.recover();
    _log.info('recover: done — ${report.status}');
    return report;
  }

  // ── Simulation helpers (testing / demo) ───────────────────────────────────

  /// Marks disk [index] as failed without touching the actual filesystem.
  ///
  /// Subsequent reads that access this disk will receive `null` (missing chunk),
  /// triggering parity recovery.  Useful in tests and demo applications.
  void simulateDiskFailure(int index) {
    _assertInitialised();
    _diskManager.simulateDiskFailure(index);
    _log.warning('⚠ Disk $index simulated as FAILED');
  }

  /// Re-probes disk [index] and marks it healthy.
  ///
  /// Use after [simulateDiskFailure] to restore the disk before calling
  /// [recover].
  Future<void> simulateDiskRestore(int index) async {
    _assertInitialised();
    await _diskManager.markDiskOnline(index);
    _log.info('✓ Disk $index simulated as RESTORED');
  }

  // ── Accessors ─────────────────────────────────────────────────────────────

  /// The RAID configuration this instance was constructed with.
  RaidConfig get config => _config;

  /// Ordered list of disk root paths.
  List<String> get diskPaths => _diskPaths;

  /// Number of disks in the array.
  int get diskCount => _diskPaths.length;

  /// `true` after [initialize] has completed successfully.
  bool get isInitialised => _initialised;

  // ── Dispose ───────────────────────────────────────────────────────────────

  /// Releases resources held by the RAID manager.
  ///
  /// Cancels the background health-check timer.
  Future<void> dispose() async {
    _healthTimer?.cancel();
    _healthTimer = null;
    _initialised = false;
    _log.info('FilesystemRaid disposed.');
  }

  // ── Private ───────────────────────────────────────────────────────────────

  RaidStrategy _buildStrategy() {
    switch (_config.type) {
      case RaidType.raid0:
        return Raid0(
          diskManager: _diskManager,
          config: _config,
          logger: _log,
        );
      case RaidType.raid1:
        return Raid1(
          diskManager: _diskManager,
          config: _config,
          logger: _log,
        );
      case RaidType.raid5:
        return Raid5(
          diskManager: _diskManager,
          config: _config,
          logger: _log,
        );
    }
  }

  void _startHealthTimer() {
    if (_config.healthCheckInterval == Duration.zero) return;
    _healthTimer = Timer.periodic(_config.healthCheckInterval, (_) async {
      _log.debug('Background health check…');
      try {
        final statuses = await _diskManager.refreshStatus();
        final failed = statuses.where((s) => s.isFailed).toList();
        if (failed.isNotEmpty) {
          _log.warning(
            '⚠ Health check: ${failed.length} disk(s) failed — '
            'indexes: ${failed.map((s) => s.diskIndex).join(", ")}',
          );
        } else {
          _log.debug('Health check: all disks healthy.');
        }
      } catch (e) {
        _log.error('Health check error', e);
      }
    });
  }

  void _assertInitialised() {
    if (!_initialised) {
      throw const RaidConfigurationException(
        'FilesystemRaid has not been initialised. Call initialize() first.',
      );
    }
  }

  void _validateConstructorArgs() {
    if (_diskPaths.length < 2) {
      throw const RaidConfigurationException(
        'At least 2 disk paths are required.',
      );
    }
    if (_diskPaths.length != _config.diskCount) {
      throw RaidConfigurationException(
        'diskPaths.length (${_diskPaths.length}) must equal '
        'config.diskCount (${_config.diskCount}).',
      );
    }
    if (_config.type == RaidType.raid5 && _diskPaths.length < 3) {
      throw const RaidConfigurationException(
        'RAID 5 requires at least 3 disks.',
      );
    }
  }

  static String _humanBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(3)} GiB';
  }
}

// ---------------------------------------------------------------------------
// FilesystemRaidBuilder — fluent builder for complex configurations
// ---------------------------------------------------------------------------

/// Fluent builder for [FilesystemRaid].
///
/// ```dart
/// final raid = FilesystemRaidBuilder()
///     .disks(['/mnt/d1', '/mnt/d2', '/mnt/d3'])
///     .type(RaidType.raid5)
///     .compress()
///     .chunkSize(8 * 1024 * 1024)
///     .build();
/// await raid.initialize();
/// ```
class FilesystemRaidBuilder {
  List<String> _diskPaths = [];
  RaidType _type = RaidType.raid5;
  bool _compress = false;
  bool _encrypt = false;
  List<int>? _encryptionKey;
  int _chunkSize = 4 * 1024 * 1024;
  Duration _healthInterval = const Duration(hours: 24);
  ParityAlgorithm _parityAlgorithm = ParityAlgorithm.xor;
  int _maxRetries = 3;
  bool _writeVerification = true;
  RaidLogLevel _logLevel = RaidLogLevel.info;

  /// Sets the disk paths.
  FilesystemRaidBuilder disks(List<String> paths) {
    _diskPaths = paths;
    return this;
  }

  /// Sets the RAID type.
  FilesystemRaidBuilder type(RaidType t) {
    _type = t;
    return this;
  }

  /// Enables DEFLATE compression.
  FilesystemRaidBuilder compress({bool enabled = true}) {
    _compress = enabled;
    return this;
  }

  /// Enables AES-256-CBC encryption with the given 32-byte [key].
  FilesystemRaidBuilder encrypt(List<int> key) {
    assert(key.length == 32);
    _encrypt = true;
    _encryptionKey = key;
    return this;
  }

  /// Sets the stripe chunk size in bytes (default 4 MiB).
  FilesystemRaidBuilder chunkSize(int bytes) {
    _chunkSize = bytes;
    return this;
  }

  /// Sets the background health-check interval.
  FilesystemRaidBuilder healthInterval(Duration d) {
    _healthInterval = d;
    return this;
  }

  /// Sets the parity algorithm.
  FilesystemRaidBuilder parity(ParityAlgorithm algo) {
    _parityAlgorithm = algo;
    return this;
  }

  /// Sets the I/O retry count.
  FilesystemRaidBuilder retries(int n) {
    _maxRetries = n;
    return this;
  }

  /// Disables post-write read-back verification.
  FilesystemRaidBuilder skipVerification() {
    _writeVerification = false;
    return this;
  }

  /// Sets the log verbosity level.
  FilesystemRaidBuilder logLevel(RaidLogLevel level) {
    _logLevel = level;
    return this;
  }

  /// Builds and returns the [FilesystemRaid] instance.
  FilesystemRaid build() {
    if (_diskPaths.isEmpty) {
      throw ArgumentError('Call disks() before build().');
    }
    final cfg = RaidConfig(
      type: _type,
      diskCount: _diskPaths.length,
      enableCompression: _compress,
      enableEncryption: _encrypt,
      encryptionKey: _encryptionKey,
      chunkSize: _chunkSize,
      healthCheckInterval: _healthInterval,
      parityAlgorithm: _parityAlgorithm,
      maxRetries: _maxRetries,
      writeVerification: _writeVerification,
      logLevel: _logLevel,
    );
    return FilesystemRaid(diskPaths: _diskPaths, config: cfg);
  }
}
