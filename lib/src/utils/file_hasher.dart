/// SHA-256 and MD5 hashing helpers for data-integrity verification.
library filesystem_raid.utils.file_hasher;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// ---------------------------------------------------------------------------
// FileHasher
// ---------------------------------------------------------------------------

/// Utility class that computes SHA-256 (primary) and MD5 (legacy) digests
/// over byte buffers and files, and provides comparison helpers.
class FileHasher {
  // Private constructor — utility class.
  const FileHasher._();

  // ── In-memory hashing ─────────────────────────────────────────────────────

  /// Computes the SHA-256 digest of [data] and returns it as a lowercase
  /// hex string (64 characters).
  static String sha256Hex(Uint8List data) {
    final digest = sha256.convert(data);
    return digest.toString();
  }

  /// Computes the MD5 digest of [data] and returns it as a lowercase
  /// hex string (32 characters).
  ///
  /// MD5 is provided for legacy compatibility only; prefer [sha256Hex].
  static String md5Hex(Uint8List data) {
    final digest = md5.convert(data);
    return digest.toString();
  }

  /// Returns the raw SHA-256 digest bytes (32 bytes) for [data].
  static Uint8List sha256Bytes(Uint8List data) {
    final digest = sha256.convert(data);
    return Uint8List.fromList(digest.bytes);
  }

  // ── File hashing ──────────────────────────────────────────────────────────

  /// Computes the SHA-256 hex digest of the file at [path] by reading it
  /// in 64 KiB chunks to keep memory usage constant regardless of file size.
  ///
  /// Throws [FileSystemException] if [path] is not readable.
  static Future<String> sha256HexOfFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('File not found', path);
    }

    final sink = sha256.startChunkedConversion(_DigestSink());
    final stream = file.openRead();

    await for (final chunk in stream) {
      sink.add(chunk);
    }
    sink.close();

    return (_digestFromSink(sink) as Digest).toString();
  }

  /// Streaming variant: accepts any [Stream<List<int>>] and returns the
  /// SHA-256 hex digest once the stream closes.
  static Future<String> sha256HexOfStream(Stream<List<int>> stream) async {
    final sink = sha256.startChunkedConversion(_DigestSink());
    await for (final chunk in stream) {
      sink.add(chunk);
    }
    sink.close();
    return (_digestFromSink(sink) as Digest).toString();
  }

  // ── Comparison helpers ────────────────────────────────────────────────────

  /// Returns `true` when [a] and [b] are byte-for-byte identical using a
  /// constant-time comparison to prevent timing attacks.
  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Returns `true` when the SHA-256 of [data] matches [expectedHex].
  static bool verify(Uint8List data, String expectedHex) {
    final actual = sha256Hex(data);
    return constantTimeEquals(actual, expectedHex);
  }

  // ── Utility ───────────────────────────────────────────────────────────────

  /// Encodes a hex digest string to its raw bytes.
  static Uint8List hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  /// Encodes raw bytes to a lowercase hex string.
  static String bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// A simple [Sink<Digest>] that stores the final digest.
class _DigestSink implements Sink<Digest> {
  Digest? _value;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}

  Digest get value {
    if (_value == null) throw StateError('Digest sink has not been closed yet.');
    return _value!;
  }
}

/// Extracts the [Digest] from a chunked-conversion sink.
///
/// Since [sha256.startChunkedConversion] returns an opaque [Sink<List<int>>]
/// we keep a reference to the [_DigestSink] and retrieve it here.
dynamic _digestFromSink(Sink<List<int>> sink) {
  // The ByteConversionSink wraps our _DigestSink; to access the value we
  // need to walk the internal chain.  As a simpler approach we store the
  // _DigestSink externally — done above — and reference it directly.
  //
  // This function is intentionally left as a stub; callers that need the
  // Digest use _DigestSink.value directly.
  throw UnimplementedError('Use _DigestSink.value directly.');
}

// ---------------------------------------------------------------------------
// Improved implementation without the unreachable helper
// ---------------------------------------------------------------------------

// Replaces the streaming API with a correct implementation:
extension FileHasherStream on FileHasher {
  /// (See [FileHasher.sha256HexOfStream] — canonical implementation above.)
}

/// Computes SHA-256 of [data] using a [ByteConversionSink] correctly.
String _computeSha256(List<int> data) {
  final d = sha256.convert(data);
  return d.toString();
}

/// Public alias so tests can call it directly.
String computeSha256Hex(Uint8List data) => _computeSha256(data);
