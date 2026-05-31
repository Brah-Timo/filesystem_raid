// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:filesystem_raid/filesystem_raid.dart';
import 'package:test/test.dart';

void main() {
  // ── XOR parity ────────────────────────────────────────────────────────────
  group('ParityCalculator – XOR', () {
    const calc = ParityCalculator();

    test('computes XOR parity of two chunks', () {
      final a = Uint8List.fromList([0x01, 0x02, 0x03]);
      final b = Uint8List.fromList([0x04, 0x05, 0x06]);
      final parity = calc.calculate([a, b]);

      expect(parity[0], equals(0x01 ^ 0x04));
      expect(parity[1], equals(0x02 ^ 0x05));
      expect(parity[2], equals(0x03 ^ 0x06));
    });

    test('computes XOR parity of three chunks', () {
      final chunks = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6]),
        Uint8List.fromList([7, 8, 9]),
      ];
      final parity = calc.calculate(chunks);

      expect(parity[0], equals(1 ^ 4 ^ 7));
      expect(parity[1], equals(2 ^ 5 ^ 8));
      expect(parity[2], equals(3 ^ 6 ^ 9));
    });

    test('parity of single chunk equals that chunk', () {
      final a = Uint8List.fromList([0xAA, 0xBB]);
      final parity = calc.calculate([a]);
      expect(parity, equals(a));
    });

    test('parity of empty list is empty', () {
      expect(calc.calculate([]).isEmpty, isTrue);
    });

    test('pads unequal-length chunks with zeros', () {
      final a = Uint8List.fromList([0xFF]);
      final b = Uint8List.fromList([0x0F, 0x0F]);
      final parity = calc.calculate([a, b]);
      // Length == max(1, 2) == 2
      expect(parity.length, equals(2));
      // byte 0: 0xFF ^ 0x0F = 0xF0
      expect(parity[0], equals(0xFF ^ 0x0F));
      // byte 1: 0x00 ^ 0x0F = 0x0F
      expect(parity[1], equals(0x0F));
    });

    test('verify returns true for consistent parity', () {
      final chunks = [
        Uint8List.fromList([10, 20]),
        Uint8List.fromList([30, 40]),
      ];
      final parity = calc.calculate(chunks);
      expect(calc.verify(chunks, parity), isTrue);
    });

    test('verify returns false for tampered parity', () {
      final chunks = [
        Uint8List.fromList([10, 20]),
        Uint8List.fromList([30, 40]),
      ];
      final parity = Uint8List.fromList([0, 0]); // wrong
      expect(calc.verify(chunks, parity), isFalse);
    });
  });

  // ── Single-chunk recovery ─────────────────────────────────────────────────
  group('ParityCalculator – recoverSingleChunk', () {
    const calc = ParityCalculator();

    test('recovers missing first chunk', () {
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList([4, 5, 6]);
      final c = Uint8List.fromList([7, 8, 9]);
      final parity = calc.calculate([a, b, c]);

      final recovered =
          calc.recoverSingleChunk(availableChunks: [b, c], parity: parity);

      expect(recovered, equals(a));
    });

    test('recovers missing middle chunk', () {
      final a = Uint8List.fromList([10, 20]);
      final b = Uint8List.fromList([30, 40]);
      final c = Uint8List.fromList([50, 60]);
      final parity = calc.calculate([a, b, c]);

      final recovered =
          calc.recoverSingleChunk(availableChunks: [a, c], parity: parity);

      expect(recovered, equals(b));
    });

    test('throws when no available chunks', () {
      final parity = Uint8List.fromList([1, 2, 3]);
      expect(
        () => calc.recoverSingleChunk(availableChunks: [], parity: parity),
        throwsA(isA<ParityException>()),
      );
    });
  });

  // ── Stripe recovery ───────────────────────────────────────────────────────
  group('ParityCalculator – recoverStripe', () {
    const calc = ParityCalculator();

    test('returns chunks unchanged when none missing', () {
      final a = Uint8List.fromList([1, 2]);
      final b = Uint8List.fromList([3, 4]);
      final parity = calc.calculate([a, b]);

      final result = calc.recoverStripe(chunks: [a, b], parity: parity);
      expect(result[0], equals(a));
      expect(result[1], equals(b));
    });

    test('recovers one missing chunk', () {
      final a = Uint8List.fromList([100, 200]);
      final b = Uint8List.fromList([150, 50]);
      final parity = calc.calculate([a, b]);

      final result = calc.recoverStripe(chunks: [null, b], parity: parity);
      expect(result[0], equals(a));
    });

    test('throws TooManyDiskFailuresException for two missing chunks', () {
      final parity = Uint8List(2);
      expect(
        () => calc.recoverStripe(
          chunks: [null, null],
          parity: parity,
        ),
        throwsA(isA<TooManyDiskFailuresException>()),
      );
    });
  });

  // ── Parity disk rotation ──────────────────────────────────────────────────
  group('ParityCalculator – parityDiskIndex', () {
    test('returns valid disk indexes for 3 disks', () {
      for (var stripe = 0; stripe < 9; stripe++) {
        final idx = ParityCalculator.parityDiskIndex(stripe, 3);
        expect(idx, greaterThanOrEqualTo(0));
        expect(idx, lessThan(3));
      }
    });

    test('rotates parity across all disks', () {
      final seen = <int>{};
      for (var stripe = 0; stripe < 3; stripe++) {
        seen.add(ParityCalculator.parityDiskIndex(stripe, 3));
      }
      expect(seen.length, equals(3), reason: 'All 3 disks should take parity turn');
    });
  });
}
