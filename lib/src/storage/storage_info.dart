/// Array-level storage statistics aggregated across all disks.
library filesystem_raid.storage.storage_info;

import 'package:meta/meta.dart';

import '../../models/disk_status.dart';
import '../../models/raid_config.dart';

// ---------------------------------------------------------------------------
// StorageInfo
// ---------------------------------------------------------------------------

/// Aggregated storage statistics for the entire RAID array.
///
/// Computed by [DiskManager.computeStorageInfo] from the list of
/// [DiskStatus] snapshots.
@immutable
class StorageInfo {
  /// Creates a [StorageInfo].
  const StorageInfo({
    required this.raidType,
    required this.diskCount,
    required this.activeDiskCount,
    required this.failedDiskCount,
    required this.totalRawBytes,
    required this.availableRawBytes,
    required this.usableBytes,
    required this.availableUsableBytes,
  });

  // ── Fields ────────────────────────────────────────────────────────────────

  /// RAID level of the array.
  final RaidType raidType;

  /// Total number of disks configured in the array.
  final int diskCount;

  /// Number of disks that are healthy or degraded (i.e. readable).
  final int activeDiskCount;

  /// Number of disks in the [DiskHealth.failed] state.
  final int failedDiskCount;

  /// Sum of all disks' total capacity in bytes (raw, before efficiency).
  final int totalRawBytes;

  /// Sum of all disks' free capacity in bytes.
  final int availableRawBytes;

  /// Effective (usable) capacity after applying RAID efficiency.
  final int usableBytes;

  /// Effective free space available for new writes.
  final int availableUsableBytes;

  // ── Derived ───────────────────────────────────────────────────────────────

  /// Bytes currently used across the array (usable perspective).
  int get usedUsableBytes => usableBytes - availableUsableBytes;

  /// Overall utilisation fraction (0.0 – 1.0) from a usable perspective.
  double get utilizationFraction =>
      usableBytes > 0 ? usedUsableBytes / usableBytes : 0.0;

  /// Overall utilisation percentage.
  double get utilizationPercentage => utilizationFraction * 100;

  /// `true` when at least one disk has failed.
  bool get isDegraded => failedDiskCount > 0;

  /// Formats raw byte counts in human-readable GiB.
  static String _fmt(int bytes) =>
      '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Builds a [StorageInfo] from a list of [DiskStatus] snapshots.
  factory StorageInfo.fromDiskStatuses(
    List<DiskStatus> statuses,
    RaidType raidType,
  ) {
    final diskCount = statuses.length;
    final active = statuses.where((s) => s.isReadable).length;
    final failed = statuses.where((s) => s.isFailed).length;

    final totalRaw = statuses.fold<int>(0, (s, d) => s + d.totalBytes);
    final availRaw = statuses.fold<int>(0, (s, d) => s + d.availableBytes);

    // Efficiency varies by RAID type.
    final double efficiency;
    switch (raidType) {
      case RaidType.raid0:
        efficiency = 1.0;
      case RaidType.raid1:
        efficiency = diskCount > 0 ? 1.0 / diskCount : 0.0;
      case RaidType.raid5:
        efficiency = diskCount > 1 ? (diskCount - 1) / diskCount : 0.0;
    }

    final usable = (totalRaw * efficiency).floor();
    final availUsable = (availRaw * efficiency).floor();

    return StorageInfo(
      raidType: raidType,
      diskCount: diskCount,
      activeDiskCount: active,
      failedDiskCount: failed,
      totalRawBytes: totalRaw,
      availableRawBytes: availRaw,
      usableBytes: usable,
      availableUsableBytes: availUsable,
    );
  }

  @override
  String toString() => 'StorageInfo('
      'type: $raidType, '
      'disks: $activeDiskCount/$diskCount, '
      'usable: ${_fmt(usableBytes)}, '
      'free: ${_fmt(availableUsableBytes)}, '
      'util: ${utilizationPercentage.toStringAsFixed(1)}%'
      ')';
}
