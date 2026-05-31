/// XOR-based parity calculation and recovery for RAID 5.
library filesystem_raid.parity.parity_calculator;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../exceptions/raid_exceptions.dart';
import '../utils/chunk_splitter.dart';

// ---------------------------------------------------------------------------
// ParityCalculator
// ---------------------------------------------------------------------------

/// Computes and verifies XOR-based parity blocks for RAID 5 stripe rows.
///
/// XOR parity works over GF(2) (the integers modulo 2):
///
///   P = D₀ ⊕ D₁ ⊕ … ⊕ D_{n-1}
///
/// To recover a missing chunk Dᵢ:
///
///   Dᵢ = P ⊕ D₀ ⊕ … ⊕ D_{i-1} ⊕ D_{i+1} ⊕ … ⊕ D_{n-1}
///
/// which is the XOR of all other known values (data + parity).
///
/// This tolerates **exactly one** missing chunk per stripe.  For
/// multi-disk fault tolerance, use [ReedSolomonCodec].
@immutable
class ParityCalculator {
  /// Creates a [ParityCalculator].
  const ParityCalculator();

  // ── Parity computation ────────────────────────────────────────────────────

  /// Computes the XOR parity of [chunks].
  ///
  /// All chunks are first zero-padded to the length of the longest chunk
  /// before XOR-ing, so the result length equals `max(chunk lengths)`.
  Uint8List calculate(List<Uint8List> chunks) {
    if (chunks.isEmpty) return Uint8List(0);

    final equalised = ChunkSplitter.equaliseLength(chunks);
    final length = equalised.first.length;
    final parity = Uint8List(length);

    for (final chunk in equalised) {
      for (var i = 0; i < length; i++) {
        parity[i] ^= chunk[i];
      }
    }

    return parity;
  }

  /// Verifies that `calculate(dataChunks) == storedParity`.
  ///
  /// Returns `true` when the parity is consistent with the data chunks.
  bool verify(List<Uint8List> dataChunks, Uint8List storedParity) {
    final computed = calculate(dataChunks);
    if (computed.length != storedParity.length) return false;
    for (var i = 0; i < computed.length; i++) {
      if (computed[i] != storedParity[i]) return false;
    }
    return true;
  }

  // ── Single-chunk recovery ─────────────────────────────────────────────────

  /// Recovers a single missing chunk from [availableChunks] and [parity].
  ///
  /// [availableChunks] must contain all chunks **except** the missing one.
  /// The missing chunk's position (index) is not needed — XOR is
  /// commutative and associative, so the order doesn't matter.
  ///
  /// Throws [ParityException] if [availableChunks] is empty and [parity]
  /// is also empty.
  Uint8List recoverSingleChunk({
    required List<Uint8List> availableChunks,
    required Uint8List parity,
  }) {
    if (availableChunks.isEmpty) {
      throw const ParityException(
        'Cannot recover a chunk: no available chunks supplied.',
      );
    }

    // Include parity as one of the "chunks" in the XOR chain.
    final all = [...availableChunks, parity];
    return calculate(all);
  }

  // ── Stripe-level recovery ─────────────────────────────────────────────────

  /// Given a list [chunks] where some entries may be `null` (missing) and a
  /// [parity] block, recovers all missing chunks.
  ///
  /// Throws [TooManyDiskFailuresException] if more than one chunk is missing.
  List<Uint8List> recoverStripe({
    required List<Uint8List?> chunks,
    required Uint8List parity,
  }) {
    final missingIndexes =
        [for (var i = 0; i < chunks.length; i++) if (chunks[i] == null) i];

    if (missingIndexes.length > 1) {
      throw TooManyDiskFailuresException(
        'XOR parity can only recover 1 missing chunk; '
        '${missingIndexes.length} are missing.',
        failedCount: missingIndexes.length,
        toleratedCount: 1,
      );
    }

    if (missingIndexes.isEmpty) {
      // Nothing to recover.
      return chunks.cast<Uint8List>();
    }

    final available = chunks
        .where((c) => c != null)
        .cast<Uint8List>()
        .toList();

    final recovered = recoverSingleChunk(
      availableChunks: available,
      parity: parity,
    );

    final result = List<Uint8List>.from(chunks.map((c) => c ?? Uint8List(0)));
    result[missingIndexes.first] = recovered;
    return result;
  }

  // ── Distributed parity position (RAID 5 rotation) ─────────────────────────

  /// Returns the disk index that holds the parity block for stripe [stripeIndex]
  /// in a RAID 5 array with [diskCount] disks.
  ///
  /// Standard left-symmetric rotation:
  ///   parity disk = (diskCount - 1 - stripeIndex % diskCount)
  static int parityDiskIndex(int stripeIndex, int diskCount) =>
      (diskCount - 1 - stripeIndex % diskCount).abs() % diskCount;
}
