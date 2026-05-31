/// DEFLATE / ZLIB compression helpers for optional chunk compression.
library filesystem_raid.utils.compression;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// CompressionResult
// ---------------------------------------------------------------------------

/// Outcome of a compress / decompress operation.
@immutable
class CompressionResult {
  /// Creates a [CompressionResult].
  const CompressionResult({
    required this.data,
    required this.originalSize,
    required this.compressedSize,
  });

  /// The resulting byte buffer (compressed or decompressed).
  final Uint8List data;

  /// Byte size before compression.
  final int originalSize;

  /// Byte size after compression.
  final int compressedSize;

  /// Compression ratio: compressedSize / originalSize.
  ///
  /// Values < 1.0 mean the data shrank; values ≥ 1.0 mean it grew.
  double get ratio =>
      originalSize > 0 ? compressedSize / originalSize : 1.0;

  /// Space saved as a percentage of the original size.
  double get savedPercent => (1.0 - ratio) * 100;

  @override
  String toString() => 'CompressionResult('
      'original: $originalSize bytes, '
      'compressed: $compressedSize bytes, '
      'ratio: ${ratio.toStringAsFixed(3)}, '
      'saved: ${savedPercent.toStringAsFixed(1)}%'
      ')';
}

// ---------------------------------------------------------------------------
// RaidCompression
// ---------------------------------------------------------------------------

/// Provides DEFLATE-based compression and decompression for chunk payloads.
///
/// Compression is applied before encryption (if enabled) so that encrypted
/// data (which looks random and is incompressible) is not passed to DEFLATE.
class RaidCompression {
  // Utility class — private constructor.
  const RaidCompression._();

  // ── Magic header ──────────────────────────────────────────────────────────

  /// 4-byte magic prefix prepended to every compressed payload so the reader
  /// can detect whether a chunk was compressed even without metadata.
  static const List<int> _magic = [0x52, 0x41, 0x5A, 0x43]; // "RAZC"

  // ── Compression ───────────────────────────────────────────────────────────

  /// Compresses [data] using DEFLATE and prepends the 4-byte magic header.
  ///
  /// If the compressed output is larger than the input, the original
  /// [data] is returned unchanged (incompressible data).
  ///
  /// Optionally uses [level] (0–9, default 6).
  static CompressionResult compress(Uint8List data, {int level = 6}) {
    assert(level >= 0 && level <= 9);
    final deflated = Uint8List.fromList(ZLibEncoder().encode(data, level: level));
    final compressed = Uint8List(4 + deflated.length);
    compressed.setRange(0, 4, _magic);
    compressed.setRange(4, compressed.length, deflated);

    // Skip compression if it makes data larger.
    if (compressed.length >= data.length) {
      return CompressionResult(
        data: data,
        originalSize: data.length,
        compressedSize: data.length,
      );
    }

    return CompressionResult(
      data: compressed,
      originalSize: data.length,
      compressedSize: compressed.length,
    );
  }

  // ── Decompression ─────────────────────────────────────────────────────────

  /// Decompresses [data] if it starts with the magic header; otherwise
  /// returns [data] unchanged (pass-through for un-compressed chunks).
  ///
  /// Throws [FormatException] if the payload starts with the magic bytes but
  /// cannot be inflated.
  static Uint8List decompress(Uint8List data) {
    if (!_hasMagic(data)) return data; // Not compressed — return as-is.

    final payload = Uint8List.sublistView(data, 4); // Strip 4-byte header.
    try {
      final inflated = ZLibDecoder().decodeBytes(payload);
      return Uint8List.fromList(inflated);
    } catch (e) {
      throw FormatException(
        'Failed to decompress RAID chunk: $e',
        data,
      );
    }
  }

  // ── Detection ─────────────────────────────────────────────────────────────

  /// Returns `true` when [data] begins with the 4-byte compression magic.
  static bool isCompressed(Uint8List data) => _hasMagic(data);

  static bool _hasMagic(Uint8List data) {
    if (data.length < 4) return false;
    for (var i = 0; i < 4; i++) {
      if (data[i] != _magic[i]) return false;
    }
    return true;
  }

  // ── Round-trip helpers ────────────────────────────────────────────────────

  /// Convenience: compress then immediately decompress, used in tests to
  /// verify round-trip correctness.
  @visibleForTesting
  static Uint8List roundTrip(Uint8List data) =>
      decompress(compress(data).data);
}

// ---------------------------------------------------------------------------
// RaidEncryption  (AES-256-CBC stub — requires the `encrypt` package)
// ---------------------------------------------------------------------------

/// AES-256-CBC encryption wrapper for chunk payloads.
///
/// **Usage**: Enable by setting `RaidConfig.enableEncryption = true` and
/// providing a 32-byte [RaidConfig.encryptionKey].
///
/// This class is intentionally lightweight — it wraps the `encrypt` package
/// and adds a 16-byte random IV prepended to every ciphertext so each chunk
/// has its own IV even when encrypted with the same key.
class RaidEncryption {
  const RaidEncryption._();

  /// Encrypts [plaintext] with AES-256-CBC using a random IV.
  ///
  /// Output format: `[16-byte IV][ciphertext]`.
  static Uint8List encrypt(Uint8List plaintext, List<int> key) {
    assert(key.length == 32, 'AES-256 requires a 32-byte key.');
    // Import lazily to avoid hard-dependency when encryption is disabled.
    // The real implementation lives in storage/chunk_handler.dart where
    // the `encrypt` package is imported.
    throw UnsupportedError(
      'Call ChunkHandler.encryptChunk() instead — '
      'it imports the encrypt package correctly.',
    );
  }

  /// Decrypts an AES-256-CBC ciphertext that begins with a 16-byte IV.
  static Uint8List decrypt(Uint8List ciphertext, List<int> key) {
    throw UnsupportedError(
      'Call ChunkHandler.decryptChunk() instead.',
    );
  }
}
