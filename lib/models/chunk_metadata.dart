/// Metadata persisted alongside every chunk on disk.
library filesystem_raid.models.chunk_metadata;

import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// ChunkMetadata
// ---------------------------------------------------------------------------

/// Describes one data chunk stored as part of a RAID stripe.
///
/// Metadata is serialised to JSON and saved in a companion `.meta` file
/// next to every `.chunk` file.
class ChunkMetadata {
  // ── Constructors ──────────────────────────────────────────────────────────

  /// Creates a [ChunkMetadata].
  ///
  /// [createdAt] defaults to [DateTime.now()] when omitted.
  ChunkMetadata({
    required this.filename,
    required this.chunkIndex,
    required this.totalChunks,
    required this.diskIndex,
    required this.originalSize,
    required this.checksum,
    this.totalFileSize,
    this.parityChecksum,
    this.isParityChunk = false,
    this.compressed = false,
    this.encrypted = false,
    this.raidType = 'raid5',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Deserialises from a JSON-compatible [Map].
  factory ChunkMetadata.fromJson(Map<String, dynamic> map) => ChunkMetadata(
        filename: map['filename'] as String,
        chunkIndex: map['chunkIndex'] as int,
        totalChunks: map['totalChunks'] as int,
        diskIndex: map['diskIndex'] as int,
        originalSize: map['originalSize'] as int,
        totalFileSize: map['totalFileSize'] as int?,
        checksum: map['checksum'] as String,
        parityChecksum: map['parityChecksum'] as String?,
        isParityChunk: map['isParityChunk'] as bool? ?? false,
        compressed: map['compressed'] as bool? ?? false,
        encrypted: map['encrypted'] as bool? ?? false,
        raidType: map['raidType'] as String? ?? 'raid5',
        createdAt: DateTime.parse(map['createdAt'] as String),
      );

  /// Deserialises from a JSON [String].
  factory ChunkMetadata.fromJsonString(String source) =>
      ChunkMetadata.fromJson(jsonDecode(source) as Map<String, dynamic>);

  // ── Fields ────────────────────────────────────────────────────────────────

  /// The logical filename this chunk belongs to.
  final String filename;

  /// Zero-based index of this chunk within the stripe.
  final int chunkIndex;

  /// Total number of data chunks in the stripe (excludes parity).
  final int totalChunks;

  /// The physical disk index this chunk was written to.
  final int diskIndex;

  /// Byte size of the original (un-padded) chunk data.
  final int originalSize;

  /// Total byte size of the whole logical file (all chunks combined, un-padded).
  ///
  /// Stored redundantly in every chunk so that any single chunk's metadata
  /// is sufficient to know the correct merge length on read-back.
  final int? totalFileSize;

  /// SHA-256 hex digest of the raw (post-compress/encrypt) chunk bytes.
  final String checksum;

  /// SHA-256 hex digest of the parity block for this stripe row (nullable).
  final String? parityChecksum;

  /// True when this metadata describes a parity chunk, not a data chunk.
  final bool isParityChunk;

  /// Whether the payload was DEFLATE-compressed before writing.
  final bool compressed;

  /// Whether the payload was AES-256 encrypted before writing.
  final bool encrypted;

  /// RAID type string (e.g. 'raid0', 'raid1', 'raid5').
  final String raidType;

  /// When this chunk was first written.
  final DateTime createdAt;

  // ── Serialisation ─────────────────────────────────────────────────────────

  /// Serialises to a JSON-compatible [Map].
  Map<String, dynamic> toJson() => {
        'filename': filename,
        'chunkIndex': chunkIndex,
        'totalChunks': totalChunks,
        'diskIndex': diskIndex,
        'originalSize': originalSize,
        'totalFileSize': totalFileSize,
        'checksum': checksum,
        'parityChecksum': parityChecksum,
        'isParityChunk': isParityChunk,
        'compressed': compressed,
        'encrypted': encrypted,
        'raidType': raidType,
        'createdAt': createdAt.toIso8601String(),
      };

  /// Encodes to a JSON [String].
  String toJsonString() => jsonEncode(toJson());

  /// Encodes to UTF-8 JSON bytes ready to be written to disk.
  Uint8List toJsonBytes() => Uint8List.fromList(utf8.encode(toJsonString()));

  // ── Copy helper ───────────────────────────────────────────────────────────

  /// Returns a copy with optional overrides.
  ChunkMetadata copyWith({
    String? filename,
    int? chunkIndex,
    int? totalChunks,
    int? diskIndex,
    int? originalSize,
    int? totalFileSize,
    String? checksum,
    String? parityChecksum,
    bool? isParityChunk,
    bool? compressed,
    bool? encrypted,
    String? raidType,
    DateTime? createdAt,
  }) =>
      ChunkMetadata(
        filename: filename ?? this.filename,
        chunkIndex: chunkIndex ?? this.chunkIndex,
        totalChunks: totalChunks ?? this.totalChunks,
        diskIndex: diskIndex ?? this.diskIndex,
        originalSize: originalSize ?? this.originalSize,
        totalFileSize: totalFileSize ?? this.totalFileSize,
        checksum: checksum ?? this.checksum,
        parityChecksum: parityChecksum ?? this.parityChecksum,
        isParityChunk: isParityChunk ?? this.isParityChunk,
        compressed: compressed ?? this.compressed,
        encrypted: encrypted ?? this.encrypted,
        raidType: raidType ?? this.raidType,
        createdAt: createdAt ?? this.createdAt,
      );

  @override
  String toString() => 'ChunkMetadata('
      'file: $filename, '
      'chunk: $chunkIndex/$totalChunks, '
      'disk: $diskIndex, '
      'parity: $isParityChunk'
      ')';
}
