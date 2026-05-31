import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

void main() {
  group('ReedSolomonCodec', () {
    test('encodes 3 data shards into 5 total shards', () {
      final codec = ReedSolomonCodec(dataCount: 3, parityCount: 2);
      final data = [
        Uint8List.fromList([1, 2, 3, 4]),
        Uint8List.fromList([5, 6, 7, 8]),
        Uint8List.fromList([9, 10, 11, 12]),
      ];
      final encoded = codec.encode(data);
      expect(encoded.length, equals(5));
      // First 3 shards are the original data (systematic code).
      expect(encoded[0], equals(data[0]));
      expect(encoded[1], equals(data[1]));
      expect(encoded[2], equals(data[2]));
    });

    test('recovers from 1 missing shard (3+2 codec)', () {
      final codec = ReedSolomonCodec(dataCount: 3, parityCount: 2);
      final data = [
        Uint8List.fromList([10, 20, 30]),
        Uint8List.fromList([40, 50, 60]),
        Uint8List.fromList([70, 80, 90]),
      ];
      final encoded = codec.encode(data);

      // Lose shard 1.
      final shards = List<Uint8List?>.from(encoded);
      shards[1] = null;

      final recovered = codec.decode(shards);
      expect(recovered[0], equals(data[0]));
      expect(recovered[1], equals(data[1]));
      expect(recovered[2], equals(data[2]));
    });

    test('recovers from 2 missing shards (3+2 codec)', () {
      final codec = ReedSolomonCodec(dataCount: 3, parityCount: 2);
      final data = [
        Uint8List.fromList([1, 2, 3, 4, 5]),
        Uint8List.fromList([6, 7, 8, 9, 10]),
        Uint8List.fromList([11, 12, 13, 14, 15]),
      ];
      final encoded = codec.encode(data);

      // Lose shards 0 and 2.
      final shards = List<Uint8List?>.from(encoded);
      shards[0] = null;
      shards[2] = null;

      final recovered = codec.decode(shards);
      expect(recovered[0], equals(data[0]));
      expect(recovered[1], equals(data[1]));
      expect(recovered[2], equals(data[2]));
    });

    test('throws TooManyDiskFailuresException when too many shards lost', () {
      final codec = ReedSolomonCodec(dataCount: 3, parityCount: 1);
      final data = [
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3, 4]),
        Uint8List.fromList([5, 6]),
      ];
      final encoded = codec.encode(data);

      // Lose 2 shards but only 1 is tolerated.
      final shards = List<Uint8List?>.from(encoded);
      shards[0] = null;
      shards[1] = null;

      expect(
        () => codec.decode(shards),
        throwsA(isA<TooManyDiskFailuresException>()),
      );
    });

    test('round-trip preserves data for various shard sizes', () {
      final codec = ReedSolomonCodec(dataCount: 4, parityCount: 2);
      for (final size in [1, 7, 16, 128, 255]) {
        final data = [
          for (var i = 0; i < 4; i++)
            Uint8List.fromList(
                List.generate(size, (j) => (i * 10 + j) % 256)),
        ];
        final encoded = codec.encode(data);
        final shards = List<Uint8List?>.from(encoded)
          ..[3] = null; // Lose shard 3
        final recovered = codec.decode(shards);
        for (var i = 0; i < 4; i++) {
          expect(recovered[i], equals(data[i]),
              reason: 'Shard $i mismatch at size $size');
        }
      }
    });
  });
}
