/// Abstract interface that every RAID strategy must implement.
library filesystem_raid.raid_types.raid_strategy;

import 'dart:typed_data';

import '../../models/disk_status.dart';
import '../../models/recovery_report.dart';

/// Contract for a RAID I/O strategy (RAID 0, 1, 5, …).
///
/// Every concrete strategy is initialised with the shared [DiskManager] and
/// [RaidLogger] via the [FilesystemRaid] constructor.
abstract interface class RaidStrategy {
  // ── Write ─────────────────────────────────────────────────────────────────

  /// Writes [data] as logical file [filename] across the array.
  ///
  /// Implementations are responsible for splitting, distributing,
  /// and optionally computing parity.
  Future<void> write(String filename, Uint8List data);

  // ── Read ──────────────────────────────────────────────────────────────────

  /// Reads and reconstructs the file identified by [filename].
  ///
  /// Implementations must silently recover missing chunks when the RAID
  /// level supports redundancy.
  Future<Uint8List> read(String filename);

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Removes all on-disk data for [filename].
  Future<void> delete(String filename);

  // ── File listing ──────────────────────────────────────────────────────────

  /// Returns all logical filenames stored in the array.
  Future<Set<String>> listFiles();

  // ── Health ────────────────────────────────────────────────────────────────

  /// Returns live [DiskStatus] snapshots for all disks.
  Future<List<DiskStatus>> checkHealth();

  // ── Recovery ──────────────────────────────────────────────────────────────

  /// Attempts to rebuild failed disks and returns a [RecoveryReport].
  Future<RecoveryReport> recover();
}
