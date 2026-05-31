/// Custom exception hierarchy for the filesystem_raid package.
///
/// All exceptions extend [RaidException] so callers can catch the entire
/// family with a single `on RaidException` clause, or handle individual
/// subtypes for fine-grained error handling.
library filesystem_raid.exceptions.raid_exceptions;

// ---------------------------------------------------------------------------
// Base
// ---------------------------------------------------------------------------

/// Root exception type for the filesystem_raid package.
abstract class RaidException implements Exception {
  /// Creates a [RaidException] with a [message] and optional [cause].
  const RaidException(this.message, {this.cause});

  /// Human-readable description of the error.
  final String message;

  /// The underlying exception or error that triggered this exception, if any.
  final Object? cause;

  @override
  String toString() {
    final causeStr = cause != null ? '\n  Caused by: $cause' : '';
    return '${runtimeType.toString()}: $message$causeStr';
  }
}

// ---------------------------------------------------------------------------
// Configuration errors
// ---------------------------------------------------------------------------

/// Thrown when the supplied [RaidConfig] or disk list is invalid.
class RaidConfigurationException extends RaidException {
  /// Creates a [RaidConfigurationException].
  const RaidConfigurationException(super.message, {super.cause});
}

// ---------------------------------------------------------------------------
// Disk / I/O errors
// ---------------------------------------------------------------------------

/// Thrown when an operation is attempted on a disk that has been marked
/// as failed or is unreachable.
class DiskFailedException extends RaidException {
  /// Creates a [DiskFailedException].
  const DiskFailedException(
    super.message, {
    super.cause,
    required this.diskIndex,
    required this.diskPath,
  });

  /// Zero-based index of the failed disk.
  final int diskIndex;

  /// Filesystem path of the failed disk directory.
  final String diskPath;

  @override
  String toString() => 'DiskFailedException(disk $diskIndex @ $diskPath): '
      '$message${cause != null ? '\n  Caused by: $cause' : ''}';
}

/// Thrown when an expected chunk file cannot be located on disk.
class ChunkNotFoundException extends RaidException {
  /// Creates a [ChunkNotFoundException].
  const ChunkNotFoundException(
    super.message, {
    super.cause,
    required this.filename,
    required this.diskIndex,
    required this.chunkIndex,
  });

  /// Logical filename the chunk belongs to.
  final String filename;

  /// Disk index where the chunk was expected.
  final int diskIndex;

  /// Chunk index within the stripe.
  final int chunkIndex;

  @override
  String toString() =>
      'ChunkNotFoundException(file: $filename, disk: $diskIndex, '
      'chunk: $chunkIndex): $message';
}

/// Thrown when a file does not exist in the RAID array.
class RaidFileNotFoundException extends RaidException {
  /// Creates a [RaidFileNotFoundException].
  const RaidFileNotFoundException(super.message,
      {super.cause, required this.filename});

  /// The filename that was requested.
  final String filename;

  @override
  String toString() => 'RaidFileNotFoundException($filename): $message';
}

/// Thrown when a disk or chunk has less available space than required.
class InsufficientSpaceException extends RaidException {
  /// Creates an [InsufficientSpaceException].
  const InsufficientSpaceException(
    super.message, {
    super.cause,
    required this.diskIndex,
    required this.requiredBytes,
    required this.availableBytes,
  });

  /// Disk that ran out of space.
  final int diskIndex;

  /// Bytes that were required for the operation.
  final int requiredBytes;

  /// Bytes that were actually available.
  final int availableBytes;
}

// ---------------------------------------------------------------------------
// Data integrity errors
// ---------------------------------------------------------------------------

/// Thrown when a checksum mismatch is detected on a chunk.
class CorruptedDataException extends RaidException {
  /// Creates a [CorruptedDataException].
  const CorruptedDataException(
    super.message, {
    super.cause,
    required this.filename,
    this.diskIndex,
    this.chunkIndex,
    this.expectedChecksum,
    this.actualChecksum,
  });

  /// Logical filename of the corrupted file.
  final String filename;

  /// Disk index where corruption was detected (null = unknown).
  final int? diskIndex;

  /// Chunk index where corruption was detected (null = unknown).
  final int? chunkIndex;

  /// SHA-256 digest that was stored in the metadata.
  final String? expectedChecksum;

  /// SHA-256 digest computed from the actual on-disk bytes.
  final String? actualChecksum;

  @override
  String toString() => 'CorruptedDataException(file: $filename, '
      'disk: $diskIndex, chunk: $chunkIndex): $message\n'
      '  expected : $expectedChecksum\n'
      '  actual   : $actualChecksum';
}

// ---------------------------------------------------------------------------
// Recovery errors
// ---------------------------------------------------------------------------

/// Thrown when a RAID level does not support data recovery.
///
/// This is expected for RAID 0, which has no redundancy.
class RaidNotRecoverableException extends RaidException {
  /// Creates a [RaidNotRecoverableException].
  const RaidNotRecoverableException(super.message, {super.cause});
}

/// Thrown when recovery is attempted but too many disks have failed.
class TooManyDiskFailuresException extends RaidException {
  /// Creates a [TooManyDiskFailuresException].
  const TooManyDiskFailuresException(
    super.message, {
    super.cause,
    required this.failedCount,
    required this.toleratedCount,
  });

  /// Number of disks currently in a failed state.
  final int failedCount;

  /// Maximum number of disk failures the RAID level can tolerate.
  final int toleratedCount;

  @override
  String toString() => 'TooManyDiskFailuresException: $message '
      '($failedCount failed, only $toleratedCount tolerated)';
}

/// Thrown when recovery logic detects an unrecoverable situation for a
/// specific file.
class RaidRecoveryException extends RaidException {
  /// Creates a [RaidRecoveryException].
  const RaidRecoveryException(super.message,
      {super.cause, this.filename});

  /// Logical filename that could not be recovered (null = array-level error).
  final String? filename;
}

// ---------------------------------------------------------------------------
// Metadata errors
// ---------------------------------------------------------------------------

/// Thrown when chunk metadata is malformed or missing.
class MetadataException extends RaidException {
  /// Creates a [MetadataException].
  const MetadataException(super.message,
      {super.cause, this.filename, this.diskIndex});

  /// Logical filename whose metadata is invalid.
  final String? filename;

  /// Disk index where the bad metadata was found.
  final int? diskIndex;
}

// ---------------------------------------------------------------------------
// Parity errors
// ---------------------------------------------------------------------------

/// Thrown when parity calculation encounters an irrecoverable state.
class ParityException extends RaidException {
  /// Creates a [ParityException].
  const ParityException(super.message, {super.cause});
}
