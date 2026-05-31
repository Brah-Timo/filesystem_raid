import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

void main() {
  group('ChunkSplitter.split', () {
    test('splits data into exact number of chunks', () {
      final data = Uint8List.fromList(List.generate(12, (i) => i));
      final chunks = ChunkSplitter.split(data, 3);
      expect(chunks.length, equals(3));
      expect(chunks[0], equals(Uint8List.fromList([0, 1, 2, 3])));
      expect(chunks[1], equals(Uint8List.fromList([4, 5, 6, 7])));
      expect(chunks[2], equals(Uint8List.fromList([8, 9, 10, 11])));
    });

    test('last chunk is shorter when data not divisible', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final chunks = ChunkSplitter.split(data, 2);
      expect(chunks.length, equals(2));
      expect(ChunkSplitter.merge(chunks, originalLength: 5),
          equals(Uint8List.fromList([1, 2, 3, 4, 5])));
    });

    test('handles single-chunk split', () {
      final data = Uint8List.fromList([9, 8, 7]);
      final chunks = ChunkSplitter.split(data, 1);
      expect(chunks.length, equals(1));
      expect(chunks[0], equals(data));
    });

    test('handles empty data', () {
      final chunks = ChunkSplitter.split(Uint8List(0), 4);
      expect(chunks.length, equals(4));
      for (final c in chunks) {
        expect(c.isEmpty, isTrue);
      }
    });

    test('throws ArgumentError for diskCount < 1', () {
      expect(
        () => ChunkSplitter.split(Uint8List.fromList([1, 2]), 0),
        throwsArgumentError,
      );
    });
  });

  group('ChunkSplitter.merge', () {
    test('merges chunks back to original data', () {
      final original = Uint8List.fromList(List.generate(100, (i) => i % 256));
      final chunks = ChunkSplitter.split(original, 5);
      final merged = ChunkSplitter.merge(chunks, originalLength: original.length);
      expect(merged, equals(original));
    });

    test('truncates to originalLength', () {
      final a = Uint8List.fromList([1, 2, 3, 0]);  // padded
      final b = Uint8List.fromList([4, 5, 0, 0]);  // padded
      final merged = ChunkSplitter.merge([a, b], originalLength: 5);
      expect(merged, equals(Uint8List.fromList([1, 2, 3, 0, 4])));
    });
  });

  group('ChunkSplitter.equaliseLength', () {
    test('pads shorter chunks to max length', () {
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList([4, 5]);
      final result = ChunkSplitter.equaliseLength([a, b]);
      expect(result[0].length, equals(3));
      expect(result[1].length, equals(3));
      expect(result[1][2], equals(0)); // padded with zero
    });
  });

  group('ChunkSplitter.zeroPad', () {
    test('pads chunk to target length', () {
      final chunk = Uint8List.fromList([1, 2]);
      final padded = ChunkSplitter.zeroPad(chunk, 5);
      expect(padded.length, equals(5));
      expect(padded[3], equals(0));
    });

    test('returns original when already at target length', () {
      final chunk = Uint8List.fromList([1, 2, 3]);
      expect(ChunkSplitter.zeroPad(chunk, 3), same(chunk));
    });
  });

  group('ChunkSplitter.areEqualLength', () {
    test('returns true for equal-length chunks', () {
      final a = Uint8List(4);
      final b = Uint8List(4);
      expect(ChunkSplitter.areEqualLength([a, b]), isTrue);
    });

    test('returns false for unequal-length chunks', () {
      final a = Uint8List(4);
      final b = Uint8List(3);
      expect(ChunkSplitter.areEqualLength([a, b]), isFalse);
    });
  });

  group('ChunkSplitter round-trip', () {
    test('split → merge preserves large binary data', () {
      final original =
          Uint8List.fromList(List.generate(10000, (i) => (i * 7 + 3) % 256));
      for (final diskCount in [2, 3, 4, 5, 7]) {
        final chunks = ChunkSplitter.split(original, diskCount);
        final merged = ChunkSplitter.merge(chunks, originalLength: original.length);
        expect(merged, equals(original),
            reason: 'Mismatch for diskCount=$diskCount');
      }
    });
  });
}
