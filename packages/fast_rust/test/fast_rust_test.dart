import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fast_rust/fast_rust.dart';
import 'package:test/test.dart';

Uint8List _randomBytes(int n, [int seed = 42]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  validationAndAsync();

  test('library loads through native assets', () {
    expect(FastRust.abiVersion, 1);
    expect(FastRust.threadCount, greaterThanOrEqualTo(1));
    expect(FastRust.add(40, 2), 42);
  });

  group('sha256', () {
    test('matches package:crypto across sizes', () {
      for (final n in [0, 1, 55, 56, 63, 64, 65, 1000, 1 << 20]) {
        final data = _randomBytes(n, n);
        expect(
          FastRust.sha256(data),
          crypto.sha256.convert(data).bytes,
          reason: 'n=$n',
        );
      }
    });

    test('works on a sublist view (offset address)', () {
      final data = _randomBytes(1000);
      final view = Uint8List.sublistView(data, 13, 777);
      expect(FastRust.sha256(view), crypto.sha256.convert(view).bytes);
    });
  });

  group('image', () {
    test('grayscale matches Dart reference', () {
      final a = _randomBytes(64 * 48 * 4);
      final b = Uint8List.fromList(a);
      FastRust.grayscaleRgba(a);
      DartReference.grayscaleRgba(b);
      expect(a, b);
    });

    test('box blur matches Dart reference bit-for-bit', () {
      for (final (w, h, r) in [(1, 1, 2), (17, 9, 3), (320, 240, 8)]) {
        final a = _randomBytes(w * h * 4, w);
        final b = Uint8List.fromList(a);
        FastRust.boxBlurRgba(a, width: w, height: h, radius: r);
        DartReference.boxBlurRgba(b, width: w, height: h, radius: r);
        expect(a, b, reason: '${w}x$h r=$r');
      }
    });

    test('async blur leaves input untouched', () async {
      final src = _randomBytes(100 * 80 * 4);
      final copy = Uint8List.fromList(src);
      final out = await FastRust.boxBlurRgbaAsync(
        src,
        width: 100,
        height: 80,
        radius: 4,
      );
      expect(src, copy);
      DartReference.boxBlurRgba(copy, width: 100, height: 80, radius: 4);
      expect(out, copy);
    });

    test('rejects mismatched dimensions', () {
      expect(
        () =>
            FastRust.boxBlurRgba(Uint8List(10), width: 2, height: 2, radius: 1),
        throwsArgumentError,
      );
      expect(() => FastRust.grayscaleRgba(Uint8List(5)), throwsArgumentError);
    });
  });

  group('mandelbrot', () {
    test('matches Dart reference', () {
      const args = (w: 200, h: 150, s: 0.015, it: 300);
      final rust = FastRust.mandelbrotRgba(
        width: args.w,
        height: args.h,
        scale: args.s,
        maxIterations: args.it,
      );
      final dart = DartReference.mandelbrotRgba(
        width: args.w,
        height: args.h,
        scale: args.s,
        maxIterations: args.it,
      );
      // Identical IEEE-754 ops in the same order: expect exact equality.
      expect(rust, dart);
    });

    test('async variant returns the same pixels', () async {
      final a = FastRust.mandelbrotRgba(width: 64, height: 64, scale: 0.05);
      final b = await FastRust.mandelbrotRgbaAsync(
        width: 64,
        height: 64,
        scale: 0.05,
      );
      expect(b, a);
    });

    test('invalid arguments raise FastRustException', () {
      expect(
        () => FastRust.mandelbrotRgba(width: 4, height: 4, scale: 0),
        throwsA(isA<FastRustException>()),
      );
    });
  });

  group('numeric', () {
    test('sort matches Dart sort', () {
      final r = Random(7);
      final a = Float64List.fromList(
        List.generate(100000, (_) => r.nextDouble() * 2e6 - 1e6),
      );
      final b = Float64List.fromList(a);
      FastRust.sortFloat64(a);
      b.sort();
      expect(a, b);
    });

    test('count primes', () {
      for (final n in [0, 1, 2, 3, 10, 100, 1000000]) {
        expect(FastRust.countPrimes(n), DartReference.countPrimes(n));
      }
      expect(FastRust.countPrimes(10000000), 664579);
    });

    test('dot product', () {
      final a = Float64List.fromList(List.generate(1001, (i) => i.toDouble()));
      final b = Float64List.fromList(List.filled(1001, 0.5));
      expect(FastRust.dot(a, b), closeTo(DartReference.dot(a, b), 1e-9));
      expect(() => FastRust.dot(a, Float64List(3)), throwsArgumentError);
    });
  });
}

void validationAndAsync() {
  group('validation', () {
    test('blur radius is bounded', () {
      final px = Uint8List(4 * 4 * 4);
      FastRust.boxBlurRgba(
        px,
        width: 4,
        height: 4,
        radius: FastRust.maxBlurRadius,
      );
      expect(
        () => FastRust.boxBlurRgba(
          px,
          width: 4,
          height: 4,
          radius: FastRust.maxBlurRadius + 1,
        ),
        throwsRangeError,
      );
      expect(
        () => FastRust.boxBlurRgba(px, width: 4, height: 4, radius: 1 << 32),
        throwsRangeError,
      );
    });

    test('zero-sized images are fine', () {
      FastRust.boxBlurRgba(Uint8List(0), width: 0, height: 5, radius: 3);
      expect(
        FastRust.mandelbrotRgba(width: 0, height: 10, scale: 0.1),
        isEmpty,
      );
    });

    test('maxIterations is bounded', () {
      for (final it in [0, -1, FastRust.maxIterations + 1, 1 << 32]) {
        expect(
          () => FastRust.mandelbrotRgba(
            width: 2,
            height: 2,
            scale: 0.1,
            maxIterations: it,
          ),
          throwsRangeError,
          reason: 'maxIterations=$it',
        );
      }
    });

    test('non-finite viewport is rejected natively', () {
      expect(
        () => FastRust.mandelbrotRgba(
          width: 2,
          height: 2,
          centerX: double.nan,
          scale: 0.1,
        ),
        throwsA(isA<FastRustException>()),
      );
    });

    test('countPrimes limit is bounded', () {
      expect(() => FastRust.countPrimes(-1), throwsRangeError);
      expect(
        () => FastRust.countPrimes(FastRust.maxPrimeLimit + 1),
        throwsRangeError,
      );
    });
  });

  group('async (non-leaf) variants', () {
    test('sha256Async matches sync', () async {
      final data = _randomBytes(100000);
      expect(await FastRust.sha256Async(data), FastRust.sha256(data));
      expect(
        await FastRust.sha256Async(Uint8List(0)),
        crypto.sha256.convert(const []).bytes,
      );
    });

    test('sortFloat64Async returns a sorted copy', () async {
      final r = Random(3);
      final data = Float64List.fromList(
        List.generate(5000, (_) => r.nextDouble() - 0.5),
      );
      final sorted = await FastRust.sortFloat64Async(data);
      expect(sorted, Float64List.fromList(data)..sort());
      expect(data, isNot(sorted)); // input untouched
    });
  });

  test('NaN ordering follows IEEE total order', () {
    final negNaN = ByteData(8)..setUint64(0, 0xFFF8000000000000);
    final data = Float64List.fromList([
      1.0,
      double.nan,
      negNaN.getFloat64(0),
      double.negativeInfinity,
      -0.0,
    ]);
    FastRust.sortFloat64(data);
    // Dart's isNegative is false for every NaN, so read the sign bit.
    bool signBit(double d) =>
        (ByteData(8)..setFloat64(0, d)).getUint8(0) >= 0x80;
    expect(data[0].isNaN && signBit(data[0]), isTrue);
    expect(data[1], double.negativeInfinity);
    expect(data[2].isNegative && data[2] == 0, isTrue);
    expect(data[3], 1.0);
    expect(data[4].isNaN && !signBit(data[4]), isTrue);
  });

  test('thread limit changes parallelism, not results', () {
    final src = _randomBytes(300 * 200 * 4);
    final a = Uint8List.fromList(src);
    final b = Uint8List.fromList(src);
    FastRust.setThreadLimit(1);
    expect(FastRust.threadCount, 1);
    FastRust.boxBlurRgba(a, width: 300, height: 200, radius: 7);
    FastRust.setThreadLimit(0);
    FastRust.boxBlurRgba(b, width: 300, height: 200, radius: 7);
    expect(a, b);
  });
}
