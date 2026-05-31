/// # filesystem_raid
///
/// A professional Dart package that implements software RAID 0 / 1 / 5
/// entirely on the local filesystem — no kernel modules, no special hardware.
///
/// ## Quick-start
///
/// ```dart
/// import 'package:filesystem_raid/filesystem_raid.dart';
///
/// Future<void> main() async {
///   final raid = FilesystemRaid(
///     diskPaths: ['/mnt/disk1', '/mnt/disk2', '/mnt/disk3'],
///     config: const RaidConfig(type: RaidType.raid5, diskCount: 3),
///   );
///
///   await raid.initialize();
///
///   // Write a file
///   final bytes = await File('video.mp4').readAsBytes();
///   await raid.write('video.mp4', bytes);
///
///   // Read it back
///   final recovered = await raid.read('video.mp4');
///
///   // Health check
///   final statuses = await raid.checkDiskHealth();
///
///   // Recover from a failed disk
///   final report = await raid.recover();
///   print(report.summary());
///
///   await raid.dispose();
/// }
/// ```
library filesystem_raid;

// ── Public API (sorted alphabetically) ───────────────────────────────────

export 'models/chunk_metadata.dart';
export 'models/disk_status.dart';
export 'models/raid_config.dart';
export 'models/recovery_report.dart';
export 'src/exceptions/raid_exceptions.dart';
export 'src/parity/parity_calculator.dart';
export 'src/parity/parity_recovery.dart';
export 'src/parity/reed_solomon.dart';
export 'src/raid_manager.dart';
export 'src/raid_types/raid_0.dart';
export 'src/raid_types/raid_1.dart';
export 'src/raid_types/raid_5.dart';
export 'src/storage/chunk_handler.dart';
export 'src/storage/disk_manager.dart';
export 'src/storage/storage_info.dart';
export 'src/utils/chunk_splitter.dart';
export 'src/utils/compression.dart';
export 'src/utils/file_hasher.dart';
export 'src/utils/logger.dart';
