/// Low-level chunk serialisation: compression, encryption, checksumming.
library filesystem_raid.storage.chunk_handler;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:meta/meta.dart';

import '../../models/chunk_metadata.dart';
import '../../models/raid_config.dart';
import '../exceptions/raid_exceptions.dart';
import '../utils/compression.dart';
import '../utils/file_hasher.dart';
import '../utils/logger.dart';

// ---------------------------------------------------------------------------
// ChunkPipeline
// ---------------------------------------------------------------------------

/// Result of encoding (compressing + encrypting) a raw chunk.
@immutable
class EncodedChunk {
  /// Creates an [EncodedChunk].
  const EncodedChunk({
    required this.payload,
    required this.originalSize,
    required this.checksum,
    required this.compressed,
    required this.encrypted,
  });

  /// The processed payload ready to be written to disk.
  final Uint8List payload;

  /// Byte length of the original un-processed chunk.
  final int originalSize;

  /// SHA-256 hex digest of [payload] (after compression/encryption).
  final String checksum;

  /// Whether [payload] was DEFLATE-compressed.
  final bool compressed;

  /// Whether [payload] was AES-256 encrypted.
  final bool encrypted;
}

// ---------------------------------------------------------------------------
// ChunkHandler
// ---------------------------------------------------------------------------

/// Handles the encode/decode pipeline for a single chunk:
///
/// **Write path**: raw bytes → [compress] → [encrypt] → disk
///
/// **Read path**: disk → [decrypt] → [decompress] → raw bytes
///
/// Also writes and reads the companion `.meta` JSON file.
class ChunkHandler {
  /// Creates a [ChunkHandler] configured from [config].
  ChunkHandler({
    required this.config,
    required RaidLogger logger,
  }) : _log = logger;

  final RaidConfig config;
  final RaidLogger _log;

  // ── Encode ────────────────────────────────────────────────────────────────

  /// Encodes [raw] through the compression → encryption pipeline.
  EncodedChunk encode(Uint8List raw) {
    var data = raw;
    var compressed = false;
    var encrypted = false;

    if (config.enableCompression) {
      final result = RaidCompression.compress(data);
      if (result.compressedSize < result.originalSize) {
        data = result.data;
        compressed = true;
        _log.debug('Compressed chunk: ${result.savedPercent.toStringAsFixed(1)}% saved');
      }
    }

    if (config.enableEncryption) {
      data = encryptChunk(data, config.encryptionKey!);
      encrypted = true;
    }

    final checksum = FileHasher.sha256Hex(data);

    return EncodedChunk(
      payload: data,
      originalSize: raw.length,
      checksum: checksum,
      compressed: compressed,
      encrypted: encrypted,
    );
  }

  /// Decodes a [payload] back to raw bytes (inverse of [encode]).
  ///
  /// Validates the [expectedChecksum] before decoding.
  Uint8List decode(
    Uint8List payload, {
    required String expectedChecksum,
    required bool compressed,
    required bool encrypted,
    String? filename,
  }) {
    // 1. Verify integrity.
    final actual = FileHasher.sha256Hex(payload);
    if (!FileHasher.constantTimeEquals(actual, expectedChecksum)) {
      throw CorruptedDataException(
        'Checksum mismatch — chunk data is corrupted.',
        filename: filename ?? '<unknown>',
        expectedChecksum: expectedChecksum,
        actualChecksum: actual,
      );
    }

    var data = payload;

    // 2. Decrypt.
    if (encrypted) {
      data = decryptChunk(data, config.encryptionKey!);
    }

    // 3. Decompress.
    if (compressed) {
      data = RaidCompression.decompress(data);
    }

    return data;
  }

  // ── Encryption helpers ────────────────────────────────────────────────────

  /// Encrypts [plaintext] with AES-256-CBC using a random 16-byte IV.
  ///
  /// Output: `[16-byte IV][ciphertext]`.
  @visibleForTesting
  static Uint8List encryptChunk(Uint8List plaintext, List<int> key32) {
    assert(key32.length == 32, 'Key must be 32 bytes for AES-256.');
    final keyBytes = enc.Key(Uint8List.fromList(key32));
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter =
        enc.Encrypter(enc.AES(keyBytes, mode: enc.AESMode.cbc));
    final encrypted = encrypter.encryptBytes(plaintext, iv: iv);
    // Prepend IV.
    final out = Uint8List(16 + encrypted.bytes.length);
    out.setRange(0, 16, iv.bytes);
    out.setRange(16, out.length, encrypted.bytes);
    return out;
  }

  /// Decrypts an AES-256-CBC ciphertext prefixed with a 16-byte IV.
  @visibleForTesting
  static Uint8List decryptChunk(Uint8List ciphertext, List<int> key32) {
    assert(key32.length == 32);
    assert(ciphertext.length > 16, 'Ciphertext too short to contain IV.');
    final ivBytes = Uint8List.sublistView(ciphertext, 0, 16);
    final data = Uint8List.sublistView(ciphertext, 16);
    final keyBytes = enc.Key(Uint8List.fromList(key32));
    final iv = enc.IV(ivBytes);
    final encrypter =
        enc.Encrypter(enc.AES(keyBytes, mode: enc.AESMode.cbc));
    final decrypted = encrypter.decryptBytes(enc.Encrypted(data), iv: iv);
    return Uint8List.fromList(decrypted);
  }

  // ── Metadata I/O ──────────────────────────────────────────────────────────

  /// Persists [metadata] as UTF-8 JSON to a companion `.meta` file.
  Future<void> writeMetadata(String chunkPath, ChunkMetadata metadata) async {
    final metaPath = '$chunkPath.meta';
    final file = File(metaPath);
    await file.writeAsBytes(metadata.toJsonBytes(), flush: true);
    _log.debug('Wrote metadata → $metaPath');
  }

  /// Reads and deserialises the `.meta` companion file for [chunkPath].
  ///
  /// Throws [MetadataException] if the file is missing or malformed.
  Future<ChunkMetadata> readMetadata(String chunkPath) async {
    final metaPath = '$chunkPath.meta';
    final file = File(metaPath);
    if (!await file.exists()) {
      throw MetadataException(
        'Metadata file not found: $metaPath',
        filename: chunkPath,
      );
    }
    try {
      final content = await file.readAsString();
      return ChunkMetadata.fromJsonString(content);
    } catch (e) {
      throw MetadataException(
        'Failed to parse metadata at $metaPath',
        cause: e,
        filename: chunkPath,
      );
    }
  }

  // ── Filename convention ───────────────────────────────────────────────────

  /// Returns the on-disk path for chunk [chunkIndex] of logical [filename]
  /// stored on disk at [diskRoot].
  static String chunkPath(
    String diskRoot,
    String filename,
    int chunkIndex, {
    bool isParity = false,
  }) {
    final sanitised = filename.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    final suffix = isParity ? 'parity' : 'chunk$chunkIndex';
    return '$diskRoot/${sanitised}_$suffix.raid';
  }

  /// Returns the path where file-level metadata is stored (on disk 0).
  static String fileMetaPath(String diskRoot, String filename) {
    final sanitised = filename.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    return '$diskRoot/${sanitised}.filemeta';
  }
}

// ---------------------------------------------------------------------------
// FileRegistry  — tracks which files live in the array
// ---------------------------------------------------------------------------

/// Simple JSON registry stored on every disk to enumerate known filenames.
///
/// Each disk holds a `_registry.json` file with the list of logical filenames.
/// [DiskManager] reconciles across disks on initialisation.
class FileRegistry {
  /// Creates an empty registry.
  FileRegistry() : _files = {};

  FileRegistry._fromSet(Set<String> files) : _files = files;

  final Set<String> _files;

  /// All registered filenames.
  Set<String> get files => Set.unmodifiable(_files);

  /// Adds [filename] to the registry.
  void register(String filename) => _files.add(filename);

  /// Removes [filename] from the registry (used on delete).
  void deregister(String filename) => _files.remove(filename);

  /// Returns `true` if [filename] is known.
  bool contains(String filename) => _files.contains(filename);

  // ── Serialisation ─────────────────────────────────────────────────────────

  /// Serialises to JSON bytes.
  Uint8List toJsonBytes() {
    final json = jsonEncode({'files': _files.toList()..sort()});
    return Uint8List.fromList(utf8.encode(json));
  }

  /// Deserialises from a JSON string.
  factory FileRegistry.fromJsonString(String source) {
    final map = jsonDecode(source) as Map<String, dynamic>;
    final files = (map['files'] as List).cast<String>().toSet();
    return FileRegistry._fromSet(files);
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  /// Registry filename written to the root of each disk directory.
  static const String registryFileName = '_raid_registry.json';

  /// Persists the registry to [diskRoot].
  Future<void> save(String diskRoot) async {
    final file = File('$diskRoot/$registryFileName');
    await file.writeAsBytes(toJsonBytes(), flush: true);
  }

  /// Loads the registry from [diskRoot].
  ///
  /// Returns an empty registry if the file does not exist yet.
  static Future<FileRegistry> load(String diskRoot) async {
    final file = File('$diskRoot/$registryFileName');
    if (!await file.exists()) return FileRegistry();
    final content = await file.readAsString();
    return FileRegistry.fromJsonString(content);
  }
}
