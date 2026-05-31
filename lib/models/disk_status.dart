/// Snapshot of a physical (or virtual) disk's state.
library filesystem_raid.models.disk_status;

import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// DiskHealth
// ---------------------------------------------------------------------------

/// Coarse health classification for a disk.
enum DiskHealth {
  /// Disk responds normally; no errors detected.
  healthy,

  /// Disk is operational but shows warning signs (high utilisation, etc.).
  degraded,

  /// Disk is unresponsive or has fatal I/O errors.
  failed,

  /// Disk status has not been checked yet.
  unknown,
}

// ---------------------------------------------------------------------------
// DiskStatus
// ---------------------------------------------------------------------------

/// An immutable snapshot describing one disk in the RAID array.
@immutable
class DiskStatus {
  /// Creates a [DiskStatus].
  const DiskStatus({
    required this.path,
    required this.diskIndex,
    required this.health,
    required this.totalBytes,
    required this.availableBytes,
    this.errorLogs = const [],
    this.readLatencyMs,
    this.writeLatencyMs,
    DateTime? lastChecked,
  }) : lastChecked = lastChecked ?? const _Sentinel();

  // ── Fields ────────────────────────────────────────────────────────────────

  /// Filesystem path where this disk's data directory lives.
  final String path;

  /// Zero-based index of this disk in the array.
  final int diskIndex;

  /// Current health classification.
  final DiskHealth health;

  /// Total capacity in bytes.
  final int totalBytes;

  /// Free capacity in bytes.
  final int availableBytes;

  /// Recent error messages collected during I/O operations.
  final List<String> errorLogs;

  /// Average read latency in milliseconds (null = not measured).
  final double? readLatencyMs;

  /// Average write latency in milliseconds (null = not measured).
  final double? writeLatencyMs;

  /// Timestamp of last health check.
  final DateTime lastChecked;

  // ── Derived helpers ───────────────────────────────────────────────────────

  /// Bytes actually used on the disk.
  int get usedBytes => totalBytes - availableBytes;

  /// Fraction of the disk that is in use (0.0 – 1.0).
  double get utilizationFraction =>
      totalBytes > 0 ? usedBytes / totalBytes : 0.0;

  /// Utilisation expressed as a percentage (0 – 100).
  double get utilizationPercentage => utilizationFraction * 100;

  /// Convenience shorthand — returns `true` when [health] is [DiskHealth.failed].
  bool get isFailed => health == DiskHealth.failed;

  /// Returns `true` when the disk is either healthy or merely degraded.
  bool get isReadable =>
      health == DiskHealth.healthy || health == DiskHealth.degraded;

  // ── Copy helper ───────────────────────────────────────────────────────────

  /// Creates a copy with optional field overrides.
  DiskStatus copyWith({
    String? path,
    int? diskIndex,
    DiskHealth? health,
    int? totalBytes,
    int? availableBytes,
    List<String>? errorLogs,
    double? readLatencyMs,
    double? writeLatencyMs,
    DateTime? lastChecked,
  }) =>
      DiskStatus(
        path: path ?? this.path,
        diskIndex: diskIndex ?? this.diskIndex,
        health: health ?? this.health,
        totalBytes: totalBytes ?? this.totalBytes,
        availableBytes: availableBytes ?? this.availableBytes,
        errorLogs: errorLogs ?? this.errorLogs,
        readLatencyMs: readLatencyMs ?? this.readLatencyMs,
        writeLatencyMs: writeLatencyMs ?? this.writeLatencyMs,
        lastChecked: lastChecked ?? this.lastChecked,
      );

  @override
  String toString() => 'DiskStatus('
      'index: $diskIndex, '
      'path: $path, '
      'health: $health, '
      'used: ${(utilizationPercentage).toStringAsFixed(1)}%, '
      'errors: ${errorLogs.length}'
      ')';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiskStatus &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          diskIndex == other.diskIndex &&
          health == other.health;

  @override
  int get hashCode => Object.hash(path, diskIndex, health);
}

// Private sentinel so `lastChecked` defaults to DateTime.now() in the
// constructor without breaking const-ness at definition time.
class _Sentinel implements DateTime {
  const _Sentinel();

  @override
  dynamic noSuchMethod(Invocation invocation) => DateTime.now();
}
