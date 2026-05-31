/// Outcome report produced after a recovery operation.
library filesystem_raid.models.recovery_report;

import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// RecoveryStatus
// ---------------------------------------------------------------------------

/// High-level outcome of a recovery run.
enum RecoveryStatus {
  /// All failed disks were rebuilt successfully.
  success,

  /// Some disks were rebuilt but some files could not be recovered.
  partial,

  /// No failed disks were found; the array is already healthy.
  notRequired,

  /// Recovery failed completely (e.g. RAID 0, or more failures than tolerated).
  failed,
}

// ---------------------------------------------------------------------------
// RecoveredFile
// ---------------------------------------------------------------------------

/// Details about a single file that was recovered.
@immutable
class RecoveredFile {
  /// Creates a [RecoveredFile].
  const RecoveredFile({
    required this.filename,
    required this.fromDiskIndex,
    required this.toDiskIndex,
    required this.bytesRecovered,
    this.verified = false,
  });

  /// Logical filename of the recovered file.
  final String filename;

  /// Source disk index used for reconstruction.
  final int fromDiskIndex;

  /// Destination disk index that was rebuilt.
  final int toDiskIndex;

  /// Number of bytes written to the rebuilt disk.
  final int bytesRecovered;

  /// Whether the recovered data passed checksum verification.
  final bool verified;

  @override
  String toString() => 'RecoveredFile('
      '$filename, '
      'disk $fromDiskIndex → $toDiskIndex, '
      '${(bytesRecovered / 1024 / 1024).toStringAsFixed(2)} MiB, '
      'verified: $verified'
      ')';
}

// ---------------------------------------------------------------------------
// RecoveryReport
// ---------------------------------------------------------------------------

/// Full report produced by [FilesystemRaid.recover].
class RecoveryReport {
  /// Creates a [RecoveryReport].
  RecoveryReport({
    DateTime? startedAt,
    this.status = RecoveryStatus.notRequired,
  }) : startedAt = startedAt ?? DateTime.now();

  // ── Fields ────────────────────────────────────────────────────────────────

  /// When recovery started.
  final DateTime startedAt;

  /// When recovery finished (set by [finish]).
  DateTime? completedAt;

  /// Overall outcome.
  RecoveryStatus status;

  /// Indexes of disks that were successfully rebuilt.
  final List<int> recoveredDiskIndexes = [];

  /// Indexes of disks that could not be recovered.
  final List<int> failedDiskIndexes = [];

  /// Per-file recovery details.
  final List<RecoveredFile> recoveredFiles = [];

  /// Map of error descriptions keyed by "disk_<index>" or "file_<name>".
  final Map<String, String> errors = {};

  // ── Derived helpers ───────────────────────────────────────────────────────

  /// Elapsed time of the recovery run.
  Duration get duration =>
      completedAt != null ? completedAt!.difference(startedAt) : Duration.zero;

  /// `true` when [status] is [RecoveryStatus.success].
  bool get isFullySuccessful => status == RecoveryStatus.success;

  /// `true` when at least some data was recovered.
  bool get hasAnyRecovery => recoveredDiskIndexes.isNotEmpty;

  /// Total bytes recovered across all files.
  int get totalBytesRecovered =>
      recoveredFiles.fold<int>(0, (s, f) => s + f.bytesRecovered);

  /// Percentage of recovered disks vs detected failed disks.
  double get successRate {
    final total = recoveredDiskIndexes.length + failedDiskIndexes.length;
    if (total == 0) return 100.0;
    return (recoveredDiskIndexes.length / total) * 100;
  }

  // ── Mutation helpers ──────────────────────────────────────────────────────

  /// Marks the report as finished with the given [status].
  void finish(RecoveryStatus finalStatus) {
    status = finalStatus;
    completedAt = DateTime.now();
  }

  /// Records a successful disk rebuild.
  void addRecoveredDisk(int diskIndex) {
    if (!recoveredDiskIndexes.contains(diskIndex)) {
      recoveredDiskIndexes.add(diskIndex);
    }
  }

  /// Records a disk that could not be rebuilt.
  void addFailedDisk(int diskIndex, String reason) {
    if (!failedDiskIndexes.contains(diskIndex)) {
      failedDiskIndexes.add(diskIndex);
    }
    errors['disk_$diskIndex'] = reason;
  }

  /// Records a recovered file.
  void addRecoveredFile(RecoveredFile file) => recoveredFiles.add(file);

  /// Records a file-level error.
  void addFileError(String filename, String reason) =>
      errors['file_$filename'] = reason;

  // ── Formatting ────────────────────────────────────────────────────────────

  /// Returns a human-readable summary string.
  String summary() {
    final sb = StringBuffer();
    sb.writeln('═══════════════════════════════════════');
    sb.writeln('  RAID Recovery Report');
    sb.writeln('═══════════════════════════════════════');
    sb.writeln('  Status   : $status');
    sb.writeln('  Duration : ${duration.inSeconds}s');
    sb.writeln('  Disks OK : ${recoveredDiskIndexes.length}');
    sb.writeln('  Disks KO : ${failedDiskIndexes.length}');
    sb.writeln('  Files    : ${recoveredFiles.length}');
    sb.writeln(
        '  Bytes    : ${(totalBytesRecovered / 1024 / 1024).toStringAsFixed(2)} MiB');
    sb.writeln('  Success% : ${successRate.toStringAsFixed(1)}%');
    if (errors.isNotEmpty) {
      sb.writeln('  Errors   :');
      for (final e in errors.entries) {
        sb.writeln('    [${e.key}] ${e.value}');
      }
    }
    sb.writeln('═══════════════════════════════════════');
    return sb.toString();
  }

  @override
  String toString() => 'RecoveryReport('
      'status: $status, '
      'recovered: ${recoveredDiskIndexes.length}, '
      'failed: ${failedDiskIndexes.length}, '
      'duration: ${duration.inSeconds}s'
      ')';
}
