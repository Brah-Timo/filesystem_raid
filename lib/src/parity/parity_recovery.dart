/// High-level parity recovery coordinator — sits above the math layer.
library filesystem_raid.parity.parity_recovery;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../models/raid_config.dart';
import '../exceptions/raid_exceptions.dart';
import 'parity_calculator.dart';
import 'reed_solomon.dart';

// ---------------------------------------------------------------------------
// ParityRecovery
// ---------------------------------------------------------------------------

/// Coordinates the recovery of one or more missing chunks in a RAID 5 stripe
/// using either XOR ([ParityCalculator]) or Reed-Solomon ([ReedSolomonCodec]).
///
/// Choose the algorithm via [RaidConfig.parityAlgorithm]:
/// - [ParityAlgorithm.xor]          → fast, tolerates exactly 1 failure.
/// - [ParityAlgorithm.reedSolomon]  → slower, tolerates `parityCount` failures.
@immutable
class ParityRecovery {
  /// Creates a [ParityRecovery] configured by [config].
  const ParityRecovery({required this.config});

  /// The RAID configuration this recovery instance is bound to.
  final RaidConfig config;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Recovers missing chunks in [chunks] (null = missing) using [parity].
  ///
  /// Selects XOR or Reed-Solomon based on [RaidConfig.parityAlgorithm].
  ///
  /// Returns the fully populated (no nulls) list of data chunks.
  List<Uint8List> recoverChunks({
    required List<Uint8List?> chunks,
    required Uint8List parity,
  }) {
    final missingCount = chunks.where((c) => c == null).length;

    if (missingCount == 0) {
      // Nothing to do.
      return chunks.cast<Uint8List>();
    }

    _validateFaultCount(missingCount);

    switch (config.parityAlgorithm) {
      case ParityAlgorithm.xor:
        return _recoverXor(chunks: chunks, parity: parity);
      case ParityAlgorithm.reedSolomon:
        return _recoverReedSolomon(chunks: chunks, parity: parity);
    }
  }

  // ── XOR recovery ──────────────────────────────────────────────────────────

  List<Uint8List> _recoverXor({
    required List<Uint8List?> chunks,
    required Uint8List parity,
  }) {
    const calc = ParityCalculator();
    return calc.recoverStripe(chunks: chunks, parity: parity);
  }

  // ── Reed-Solomon recovery ─────────────────────────────────────────────────

  List<Uint8List> _recoverReedSolomon({
    required List<Uint8List?> chunks,
    required Uint8List parity,
  }) {
    final dataCount = chunks.length;

    final codec = ReedSolomonCodec(
      dataCount: dataCount,
      parityCount: 1, // For RAID 5, we always have 1 parity shard.
    );

    // Build the full shard list (data + parity) for the codec.
    final shards = List<Uint8List?>.from(chunks)..add(parity);

    // Decode recovers all missing shards.
    final recovered = codec.decode(shards);

    // Return only the data portion (drop the parity shard at the end).
    return recovered.take(dataCount).toList();
  }

  // ── Parity computation ────────────────────────────────────────────────────

  /// Computes the parity block for a set of [dataChunks].
  ///
  /// Uses XOR or Reed-Solomon based on [RaidConfig.parityAlgorithm].
  Uint8List computeParity(List<Uint8List> dataChunks) {
    switch (config.parityAlgorithm) {
      case ParityAlgorithm.xor:
        const calc = ParityCalculator();
        return calc.calculate(dataChunks);
      case ParityAlgorithm.reedSolomon:
        final codec = ReedSolomonCodec(
          dataCount: dataChunks.length,
          parityCount: 1,
        );
        return codec.encode(dataChunks).last;
    }
  }

  /// Verifies that the [storedParity] is consistent with [dataChunks].
  ///
  /// Returns `true` when the parity check passes.
  bool verifyParity(List<Uint8List> dataChunks, Uint8List storedParity) {
    final computed = computeParity(dataChunks);
    if (computed.length != storedParity.length) return false;
    for (var i = 0; i < computed.length; i++) {
      if (computed[i] != storedParity[i]) return false;
    }
    return true;
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  void _validateFaultCount(int missing) {
    final tolerated = config.faultTolerance;
    if (missing > tolerated) {
      throw TooManyDiskFailuresException(
        'Cannot recover: $missing chunk(s) are missing but the configured '
        '${config.type.name.toUpperCase()} array only tolerates $tolerated '
        'failure(s).',
        failedCount: missing,
        toleratedCount: tolerated,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// ParityRecoveryResult
// ---------------------------------------------------------------------------

/// Outcome of a stripe-level recovery operation.
@immutable
class ParityRecoveryResult {
  /// Creates a [ParityRecoveryResult].
  const ParityRecoveryResult({
    required this.recovered,
    required this.recoveredIndexes,
    required this.algorithm,
    required this.durationMicros,
  });

  /// The recovered (complete, null-free) list of data chunks.
  final List<Uint8List> recovered;

  /// Indexes of the chunks that were actually reconstructed.
  final List<int> recoveredIndexes;

  /// The parity algorithm used for this recovery.
  final ParityAlgorithm algorithm;

  /// Wall-clock microseconds taken for the recovery computation.
  final int durationMicros;

  /// `true` when at least one chunk was reconstructed.
  bool get anyRecovered => recoveredIndexes.isNotEmpty;

  @override
  String toString() => 'ParityRecoveryResult('
      'recovered: $recoveredIndexes, '
      'algo: $algorithm, '
      '${(durationMicros / 1000).toStringAsFixed(2)} ms'
      ')';
}
