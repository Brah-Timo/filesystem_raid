/// Configuration model for a FilesystemRaid instance.
library filesystem_raid.models.raid_config;

import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// Enumerations
// ---------------------------------------------------------------------------

/// RAID levels supported by this package.
enum RaidType {
  /// Striping — maximum performance, zero redundancy.
  raid0,

  /// Mirroring — full redundancy, 50 % storage efficiency.
  raid1,

  /// Striping with distributed parity — balanced performance & redundancy.
  raid5,
}

/// Parity algorithm to use in RAID 5 mode.
enum ParityAlgorithm {
  /// Simple XOR — fast and sufficient for single-disk-failure scenarios.
  xor,

  /// Reed-Solomon GF(2^8) — stronger multi-disk error correction.
  reedSolomon,
}

// ---------------------------------------------------------------------------
// RaidConfig
// ---------------------------------------------------------------------------

/// Immutable configuration object passed to [FilesystemRaid].
///
/// Example:
/// ```dart
/// const config = RaidConfig(
///   type: RaidType.raid5,
///   diskCount: 3,
///   enableCompression: true,
/// );
/// ```
@immutable
class RaidConfig {
  /// Creates a [RaidConfig].
  const RaidConfig({
    required this.type,
    required this.diskCount,
    this.enableCompression = false,
    this.enableEncryption = false,
    this.encryptionKey,
    this.chunkSize = _defaultChunkSize,
    this.healthCheckInterval = const Duration(hours: 24),
    this.parityAlgorithm = ParityAlgorithm.xor,
    this.maxRetries = 3,
    this.writeVerification = true,
    this.logLevel = RaidLogLevel.info,
  })  : assert(diskCount >= 1, 'At least 1 disk is required.'),
        assert(
          type == RaidType.raid0 || diskCount >= 2,
          'RAID 1 and RAID 5 require at least 2 disks.',
        ),
        assert(chunkSize > 0, 'chunkSize must be positive.'),
        assert(
          !enableEncryption || encryptionKey != null,
          'encryptionKey must be supplied when enableEncryption is true.',
        ),
        assert(
          type != RaidType.raid5 || diskCount >= 3,
          'RAID 5 requires at least 3 disks.',
        );

  // ── Default values ────────────────────────────────────────────────────────

  /// Default chunk size: 4 MiB.
  static const int _defaultChunkSize = 4 * 1024 * 1024;

  // ── Fields ────────────────────────────────────────────────────────────────

  /// RAID level.
  final RaidType type;

  /// Number of physical disks (must match the [diskPaths] list length).
  final int diskCount;

  /// Compress chunk data before writing (DEFLATE).
  final bool enableCompression;

  /// Encrypt chunk data with AES-256-CBC before writing.
  final bool enableEncryption;

  /// 32-byte AES key. Required when [enableEncryption] is `true`.
  final List<int>? encryptionKey;

  /// Size in bytes of each stripe chunk (default 4 MiB).
  final int chunkSize;

  /// How often the background health checker inspects disk status.
  final Duration healthCheckInterval;

  /// Parity algorithm used when [type] is [RaidType.raid5].
  final ParityAlgorithm parityAlgorithm;

  /// Number of I/O retry attempts on transient errors.
  final int maxRetries;

  /// Re-read every chunk after write to verify data integrity.
  final bool writeVerification;

  /// Verbosity of the internal logger.
  final RaidLogLevel logLevel;

  // ── Derived helpers ───────────────────────────────────────────────────────

  /// Number of tolerated disk failures before data loss.
  int get faultTolerance {
    switch (type) {
      case RaidType.raid0:
        return 0;
      case RaidType.raid1:
        return diskCount - 1;
      case RaidType.raid5:
        return 1;
    }
  }

  /// Storage efficiency (usable / total capacity).
  double get storageEfficiency {
    switch (type) {
      case RaidType.raid0:
        return 1.0;
      case RaidType.raid1:
        return 1.0 / diskCount;
      case RaidType.raid5:
        return (diskCount - 1) / diskCount;
    }
  }

  @override
  String toString() => 'RaidConfig('
      'type: $type, '
      'disks: $diskCount, '
      'chunkSize: $chunkSize, '
      'compression: $enableCompression, '
      'encryption: $enableEncryption, '
      'parity: $parityAlgorithm'
      ')';
}

// ---------------------------------------------------------------------------
// RaidLogLevel
// ---------------------------------------------------------------------------

/// Log verbosity levels exposed by the RAID manager.
enum RaidLogLevel {
  /// No output.
  none,

  /// Errors only.
  error,

  /// Warnings + errors.
  warning,

  /// Normal operational messages.
  info,

  /// Verbose debug output.
  debug,
}
