/// Data splitting and merging utilities.
library filesystem_raid.utils.chunk_splitter;

import 'dart:typed_data';

import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// ChunkSplitter
// ---------------------------------------------------------------------------

/// Provides static helpers to split a byte buffer into equal-size chunks
/// and to merge them back to the original buffer.
///
/// The last chunk may be shorter than [chunkSize] when the data length is
/// not perfectly divisible; [merge] handles this transparently.
@immutable
class ChunkSplitter {
  // Private constructor — this is a utility class.
  const ChunkSplitter._();

  // ── Splitting ─────────────────────────────────────────────────────────────

  /// Splits [data] into exactly [diskCount] equal-length chunks.
  ///
  /// Pads the last chunk with zero bytes so all chunks are the same length.
  /// Use [originalLength] stored in [ChunkMetadata] to trim on read-back.
  ///
  /// Throws [ArgumentError] if [diskCount] < 1.
  static List<Uint8List> split(Uint8List data, int diskCount) {
    if (diskCount < 1) {
      throw ArgumentError.value(diskCount, 'diskCount', 'Must be at least 1.');
    }
    if (data.isEmpty) return List.generate(diskCount, (_) => Uint8List(0));

    final chunkSize = (data.length / diskCount).ceil();
    return splitBySize(data, chunkSize, targetCount: diskCount);
  }

  /// Splits [data] into chunks of at most [chunkSize] bytes.
  ///
  /// If [targetCount] is supplied the result is padded with empty chunks to
  /// reach exactly that count (used by [split] above).
  static List<Uint8List> splitBySize(
    Uint8List data,
    int chunkSize, {
    int? targetCount,
  }) {
    assert(chunkSize > 0);
    final chunks = <Uint8List>[];
    var offset = 0;

    while (offset < data.length) {
      final end = (offset + chunkSize).clamp(0, data.length);
      chunks.add(Uint8List.sublistView(data, offset, end));
      offset = end;
    }

    // Pad to targetCount with empty chunks.
    if (targetCount != null) {
      while (chunks.length < targetCount) {
        chunks.add(Uint8List(0));
      }
    }

    return chunks;
  }

  // ── Merging ───────────────────────────────────────────────────────────────

  /// Concatenates [chunks] in order and returns the combined [Uint8List].
  ///
  /// If [originalLength] is provided the result is truncated to that length,
  /// which removes any zero-padding added during [split].
  static Uint8List merge(
    List<Uint8List> chunks, {
    int? originalLength,
  }) {
    final totalLen = chunks.fold<int>(0, (s, c) => s + c.length);
    final buffer = Uint8List(totalLen);
    var offset = 0;
    for (final chunk in chunks) {
      buffer.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    if (originalLength != null && originalLength < buffer.length) {
      return Uint8List.sublistView(buffer, 0, originalLength);
    }
    return buffer;
  }

  // ── Padding helpers ───────────────────────────────────────────────────────

  /// Pads [chunk] with zero bytes on the right to reach [targetLength].
  ///
  /// Returns [chunk] unchanged if it is already at least [targetLength] bytes.
  static Uint8List zeroPad(Uint8List chunk, int targetLength) {
    if (chunk.length >= targetLength) return chunk;
    final padded = Uint8List(targetLength);
    padded.setRange(0, chunk.length, chunk);
    return padded;
  }

  /// Pads every chunk in [chunks] to the length of the longest chunk.
  static List<Uint8List> equaliseLength(List<Uint8List> chunks) {
    if (chunks.isEmpty) return chunks;
    final maxLen = chunks.fold<int>(0, (m, c) => c.length > m ? c.length : m);
    return chunks.map((c) => zeroPad(c, maxLen)).toList();
  }

  // ── Validation ────────────────────────────────────────────────────────────

  /// Returns `true` when all [chunks] have the same byte length.
  static bool areEqualLength(List<Uint8List> chunks) {
    if (chunks.length <= 1) return true;
    final len = chunks.first.length;
    return chunks.every((c) => c.length == len);
  }

  /// Returns the total byte count across all [chunks].
  static int totalBytes(List<Uint8List> chunks) =>
      chunks.fold<int>(0, (s, c) => s + c.length);
}
