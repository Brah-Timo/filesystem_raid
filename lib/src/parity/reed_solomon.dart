/// Reed-Solomon GF(2^8) codec — advanced multi-disk error correction.
library filesystem_raid.parity.reed_solomon;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../exceptions/raid_exceptions.dart';

// ---------------------------------------------------------------------------
// GF(2^8) arithmetic
// ---------------------------------------------------------------------------

/// Galois Field GF(2^8) operations using the primitive polynomial
/// x^8 + x^4 + x^3 + x^2 + 1  (0x11D).
///
/// All arithmetic is table-driven for maximum speed.
@immutable
class _GF256 {
  const _GF256._();

  static const int _primitive = 0x11D;
  static const int _size = 256;

  // Exponent and logarithm tables.
  static final Uint8List _exp = _buildExpTable();
  static final Uint8List _log = _buildLogTable();

  static Uint8List _buildExpTable() {
    final exp = Uint8List(_size * 2);
    var x = 1;
    for (var i = 0; i < _size - 1; i++) {
      exp[i] = x;
      x <<= 1;
      if (x >= _size) x ^= _primitive;
    }
    // Duplicate for easy modular lookup.
    for (var i = _size - 1; i < _size * 2; i++) {
      exp[i] = exp[i - (_size - 1)];
    }
    return exp;
  }

  static Uint8List _buildLogTable() {
    final log = Uint8List(_size);
    log[0] = 0; // undefined — log(0) = -∞
    for (var i = 0; i < _size - 1; i++) {
      log[_exp[i]] = i;
    }
    return log;
  }

  /// Multiplication in GF(2^8).
  static int mul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    return _exp[(_log[a] + _log[b]) % 255];
  }

  /// Inverse: 1/x in GF(2^8).
  static int inv(int x) {
    assert(x != 0, 'Zero has no inverse in GF(2^8).');
    return _exp[255 - _log[x]];
  }

}

// ---------------------------------------------------------------------------
// ReedSolomonCodec
// ---------------------------------------------------------------------------

/// Systematic Reed-Solomon encoder / decoder over GF(2^8).
///
/// Encodes [dataCount] data shards into [dataCount + parityCount] shards.
/// Can recover from the loss of any [parityCount] shards.
///
/// Example — 3-of-5 encoding (3 data + 2 parity):
/// ```dart
/// final rs = ReedSolomonCodec(dataCount: 3, parityCount: 2);
/// final encoded = rs.encode(dataShards);         // List of 5 shards
/// encoded[1] = null;                             // Simulate disk failure
/// final decoded = rs.decode(encoded);            // Recover missing shard
/// ```
class ReedSolomonCodec {
  /// Creates a [ReedSolomonCodec].
  ///
  /// [dataCount]   — number of original data shards.
  /// [parityCount] — number of redundancy shards (fault tolerance level).
  ReedSolomonCodec({
    required this.dataCount,
    required this.parityCount,
  })  : assert(dataCount > 0),
        assert(parityCount > 0),
        assert(dataCount + parityCount <= 256,
            'Total shards must not exceed 256.'),
        totalCount = dataCount + parityCount,
        _encMatrix = _buildEncodingMatrix(dataCount, parityCount);

  // ── Fields ────────────────────────────────────────────────────────────────

  /// Number of data shards.
  final int dataCount;

  /// Number of parity shards.
  final int parityCount;

  /// Total shards = dataCount + parityCount.
  final int totalCount;

  final List<Uint8List> _encMatrix; // (totalCount × dataCount) matrix

  // ── Encoding matrix (Cauchy — systematic) ────────────────────────────────
  //
  // A Cauchy matrix C[i][j] = 1 / (x_i XOR y_j) in GF(2^8) is always
  // invertible as long as the x and y sets are disjoint and all elements
  // are distinct.  We use:
  //   x_i = i                        for i in 0..parityCount-1
  //   y_j = parityCount + j          for j in 0..dataCount-1
  //
  // The systematic encoding matrix is then:
  //   [ I_dataCount    ]   (identity block — data rows pass through)
  //   [ C_parityxdata  ]   (Cauchy block   — parity rows)

  static List<Uint8List> _buildEncodingMatrix(
      int dataCount, int parityCount) {
    final total = dataCount + parityCount;
    final matrix = List.generate(total, (_) => Uint8List(dataCount));

    // Identity block: data rows.
    for (var i = 0; i < dataCount; i++) {
      matrix[i][i] = 1;
    }

    // Cauchy block: parity rows.
    for (var i = 0; i < parityCount; i++) {
      final xi = i; // x_i
      for (var j = 0; j < dataCount; j++) {
        final yj = parityCount + j; // y_j
        // 1 / (x_i XOR y_j) — safe because x and y sets are disjoint.
        matrix[dataCount + i][j] = _GF256.inv(xi ^ yj);
      }
    }

    return matrix;
  }

  // ── Encode ────────────────────────────────────────────────────────────────

  /// Encodes [dataShards] and returns [totalCount] shards.
  ///
  /// All shards must have the same byte length.
  /// The first [dataCount] shards in the output are identical to the input
  /// (systematic code).
  List<Uint8List> encode(List<Uint8List> dataShards) {
    assert(dataShards.length == dataCount);
    _assertEqualLength(dataShards);

    final shardLen = dataShards.first.length;
    final output =
        List.generate(totalCount, (_) => Uint8List(shardLen));

    // Copy data shards verbatim.
    for (var i = 0; i < dataCount; i++) {
      output[i].setAll(0, dataShards[i]);
    }

    // Compute parity shards.
    for (var row = dataCount; row < totalCount; row++) {
      for (var col = 0; col < dataCount; col++) {
        final coeff = _encMatrix[row][col];
        if (coeff == 0) continue;
        final src = dataShards[col];
        final dst = output[row];
        for (var j = 0; j < shardLen; j++) {
          dst[j] ^= _GF256.mul(coeff, src[j]);
        }
      }
    }

    return output;
  }

  // ── Decode ────────────────────────────────────────────────────────────────

  /// Recovers missing shards from [shards] (null entries = lost shards).
  ///
  /// Requires at least [dataCount] non-null shards.
  ///
  /// Throws [TooManyDiskFailuresException] if fewer than [dataCount] shards
  /// are present.
  List<Uint8List> decode(List<Uint8List?> shards) {
    assert(shards.length == totalCount);

    final presentIndexes = <int>[];
    for (var i = 0; i < totalCount; i++) {
      if (shards[i] != null) presentIndexes.add(i);
    }

    if (presentIndexes.length < dataCount) {
      throw TooManyDiskFailuresException(
        'Reed-Solomon decode requires at least $dataCount shards; '
        'only ${presentIndexes.length} are available.',
        failedCount: totalCount - presentIndexes.length,
        toleratedCount: parityCount,
      );
    }

    // Use the first dataCount present shards.
    final useIndexes = presentIndexes.take(dataCount).toList();
    final shardLen = shards[useIndexes.first]!.length;

    // Build the sub-matrix for the chosen rows.
    final subMatrix = List.generate(
        dataCount, (i) => Uint8List.fromList(_encMatrix[useIndexes[i]]));

    // Invert it.
    final invMatrix = _invertMatrix(subMatrix, dataCount);

    // Multiply to recover data shards.
    final recovered = List.generate(dataCount, (_) => Uint8List(shardLen));
    for (var row = 0; row < dataCount; row++) {
      for (var col = 0; col < dataCount; col++) {
        final coeff = invMatrix[row][col];
        if (coeff == 0) continue;
        final src = shards[useIndexes[col]]!;
        final dst = recovered[row];
        for (var j = 0; j < shardLen; j++) {
          dst[j] ^= _GF256.mul(coeff, src[j]);
        }
      }
    }

    // Re-encode to fill parity shards, build full output.
    final full = encode(recovered);

    // Return full shard list, including original non-null shards as-is.
    final result = List<Uint8List>.from(full);
    for (final idx in presentIndexes) {
      result[idx] = shards[idx]!;
    }
    return result;
  }

  // ── Matrix inversion (GF) ─────────────────────────────────────────────────

  static List<Uint8List> _invertMatrix(
      List<Uint8List> matrix, int n) {
    // Augmented matrix: [M | I].
    final aug = List.generate(n, (i) {
      final row = Uint8List(n * 2);
      row.setRange(0, n, matrix[i]);
      row[n + i] = 1;
      return row;
    });

    for (var col = 0; col < n; col++) {
      // Find a non-zero pivot in this column.
      if (aug[col][col] == 0) {
        for (var row = col + 1; row < n; row++) {
          if (aug[row][col] != 0) {
            final tmp = aug[col];
            aug[col] = aug[row];
            aug[row] = tmp;
            break;
          }
        }
      }
      // If the pivot is still zero the sub-matrix is singular — should never
      // happen with a valid Cauchy encoding matrix and fewer failures than
      // parityCount, but guard defensively.
      if (aug[col][col] == 0) continue;

      final inv = _GF256.inv(aug[col][col]);
      for (var c = 0; c < n * 2; c++) {
        aug[col][c] = _GF256.mul(aug[col][c], inv);
      }

      for (var row = 0; row < n; row++) {
        if (row == col) continue;
        final factor = aug[row][col];
        if (factor == 0) continue;
        for (var c = 0; c < n * 2; c++) {
          aug[row][c] ^= _GF256.mul(factor, aug[col][c]);
        }
      }
    }

    return List.generate(n, (i) => Uint8List.sublistView(aug[i], n));
  }

  // ── Validation helper ─────────────────────────────────────────────────────

  static void _assertEqualLength(List<Uint8List> shards) {
    if (shards.isEmpty) return;
    final len = shards.first.length;
    for (final s in shards) {
      assert(s.length == len, 'All shards must have equal length.');
    }
  }
}
