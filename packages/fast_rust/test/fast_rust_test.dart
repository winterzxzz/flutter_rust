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

  group('coloring', () {
    test('coloring page matches Dart reference', () {
      for (final (w, h, cells, block, seed) in [
        (64, 48, 12, 2, 7),
        (301, 199, 60, 5, 42),
        (16, 16, 1, 16, 3),
        // Seeds with the top bit set / negative in Dart's signed int.
        (40, 30, 7, 2, -1),
        (40, 30, 7, 2, 1 << 63),
      ]) {
        expect(
          FastRust.coloringPageRgba(
            width: w,
            height: h,
            cells: cells,
            block: block,
            seed: seed,
          ),
          DartReference.coloringPageRgba(
            width: w,
            height: h,
            cells: cells,
            block: block,
            seed: seed,
          ),
          reason: '${w}x$h cells=$cells block=$block',
        );
      }
    });

    test('flood fill matches Dart reference, pixel for pixel', () {
      const w = 240, h = 180;
      final page = FastRust.coloringPageRgba(
        width: w,
        height: h,
        cells: 50,
        block: 3,
      );
      final r = Random(5);
      final a = Uint8List.fromList(page);
      final b = Uint8List.fromList(page);
      for (var i = 0; i < 60; i++) {
        final x = r.nextInt(w), y = r.nextInt(h);
        final color = (r.nextInt(1 << 24) << 8) | 0xff;
        final tol = i.isEven ? 0 : 40;
        final na = FastRust.floodFillRgba(
          a,
          width: w,
          height: h,
          x: x,
          y: y,
          color: color,
          tolerance: tol,
        );
        final nb = DartReference.floodFillRgba(
          b,
          width: w,
          height: h,
          x: x,
          y: y,
          color: color,
          tolerance: tol,
        );
        expect(na, nb, reason: 'fill $i at ($x,$y)');
      }
      expect(a, b);
    });

    test('flood fill on an unaligned view uses the byte path correctly', () {
      const w = 50, h = 40;
      final page = FastRust.coloringPageRgba(
        width: w,
        height: h,
        cells: 9,
        block: 2,
      );
      // Offset by 1 byte: not 4-byte aligned, so no Uint32List fast path.
      final backing = Uint8List(page.length + 1)..setAll(1, page);
      final view = Uint8List.sublistView(backing, 1);
      final ref = Uint8List.fromList(page);
      for (final (x, y) in [(10, 10), (25, 20), (40, 33)]) {
        final a = DartReference.floodFillRgba(
          view,
          width: w,
          height: h,
          x: x,
          y: y,
          color: 0x336699ff,
        );
        final b = FastRust.floodFillRgba(
          ref,
          width: w,
          height: h,
          x: x,
          y: y,
          color: 0x336699ff,
        );
        expect(a, b);
      }
      expect(view, ref);
    });

    test('coloring page work is bounded', () {
      expect(
        () => FastRust.coloringPageRgba(
          width: 4096,
          height: 4096,
          cells: 65536,
          block: 1,
        ),
        throwsArgumentError,
      );
    });

    test('coloringPageRgbaAsync matches sync', () async {
      expect(
        await FastRust.coloringPageRgbaAsync(
          width: 80,
          height: 60,
          cells: 20,
          block: 4,
          seed: 9,
        ),
        FastRust.coloringPageRgba(
          width: 80,
          height: 60,
          cells: 20,
          block: 4,
          seed: 9,
        ),
      );
    });

    test('flood fill basics and validation', () {
      final px = Uint8List.fromList(List.filled(3 * 2 * 4, 255));
      expect(
        FastRust.floodFillRgba(
          px,
          width: 3,
          height: 2,
          x: 1,
          y: 1,
          color: 0x112233ff,
        ),
        6,
      );
      expect(px.sublist(0, 4), [0x11, 0x22, 0x33, 0xff]);
      // Same colour again: nothing to do.
      expect(
        FastRust.floodFillRgba(
          px,
          width: 3,
          height: 2,
          x: 0,
          y: 0,
          color: 0x112233ff,
        ),
        0,
      );
      expect(
        () => FastRust.floodFillRgba(
          px,
          width: 3,
          height: 2,
          x: 3,
          y: 0,
          color: 0,
        ),
        throwsRangeError,
      );
      expect(
        () => FastRust.floodFillRgba(
          px,
          width: 3,
          height: 2,
          x: 0,
          y: 0,
          color: 0,
          tolerance: 256,
        ),
        throwsRangeError,
      );
      expect(
        () => FastRust.coloringPageRgba(width: 4, height: 4, cells: 0),
        throwsRangeError,
      );
    });
  });

  group('photo recolor', () {
    // A fractal render is a good stand-in for a photo: smooth gradients,
    // fine detail and sharp edges.
    const w = 160, h = 120;
    final photo = FastRust.mandelbrotRgba(
      width: w,
      height: h,
      centerX: -0.7453,
      centerY: 0.1127,
      scale: 0.02 / w,
      maxIterations: 300,
    );

    test('matches Dart reference, pixel for pixel', () {
      final rng = Random(5);
      for (final tolerance in [0, 12, 40, 255]) {
        for (var k = 0; k < 8; k++) {
          final x = rng.nextInt(w), y = rng.nextInt(h);
          final color = rng.nextInt(1 << 32);
          final strength = [255, 180, 0][k % 3];
          final a = Uint8List.fromList(photo);
          final b = Uint8List.fromList(photo);
          final na = FastRust.recolorRegionRgba(
            photo,
            a,
            width: w,
            height: h,
            x: x,
            y: y,
            color: color,
            tolerance: tolerance,
            strength: strength,
          );
          final nb = DartReference.recolorRegionRgba(
            photo,
            b,
            width: w,
            height: h,
            x: x,
            y: y,
            color: color,
            tolerance: tolerance,
            strength: strength,
          );
          expect(na, nb, reason: 'count at ($x,$y) tol $tolerance');
          expect(na, greaterThan(0));
          expect(a, b, reason: 'pixels at ($x,$y) tol $tolerance');
        }
      }
      // tolerance 255 selects the whole image.
      final all = Uint8List(w * h * 4);
      expect(
        FastRust.recolorRegionRgba(
          photo,
          all,
          width: w,
          height: h,
          x: 0,
          y: 0,
          color: 0xff0000ff,
          tolerance: 255,
        ),
        w * h,
      );
    });

    test('keeps source untouched and preserves brightness order', () {
      final src = Uint8List.fromList(
        List.generate(4 * 4, (i) => i % 4 == 3 ? 255 : (i ~/ 4) * 60 + 20),
      ); // a 4x1 gray ramp: 20, 80, 140, 200
      final copy = Uint8List.fromList(src);
      final dst = Uint8List(16);
      final n = FastRust.recolorRegionRgba(
        src,
        dst,
        width: 4,
        height: 1,
        x: 0,
        y: 0,
        color: 0x3366ccff,
        tolerance: 255,
      );
      expect(n, 4);
      expect(src, copy);
      final lum = [
        for (var i = 0; i < 4; i++)
          77 * dst[i * 4] + 150 * dst[i * 4 + 1] + 29 * dst[i * 4 + 2],
      ];
      for (var i = 1; i < 4; i++) {
        expect(lum[i], greaterThan(lum[i - 1]));
      }
      expect(dst[6], greaterThan(dst[4]), reason: 'tinted blue, not gray');
    });

    test('validation', () {
      final a = Uint8List(16), b = Uint8List(16);
      expect(
        () => FastRust.recolorRegionRgba(
          a,
          a,
          width: 2,
          height: 2,
          x: 0,
          y: 0,
          color: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => FastRust.recolorRegionRgba(
          a,
          b,
          width: 2,
          height: 2,
          x: 2,
          y: 0,
          color: 0,
        ),
        throwsRangeError,
      );
      expect(
        () => FastRust.recolorRegionRgba(
          a,
          b,
          width: 2,
          height: 2,
          x: 0,
          y: 0,
          color: 0,
          strength: 256,
        ),
        throwsRangeError,
      );
      expect(
        () => FastRust.recolorRegionRgba(
          a,
          Uint8List(12),
          width: 2,
          height: 2,
          x: 0,
          y: 0,
          color: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('spreading fill', () {
    test('distances match the Dart reference and cover the fill region', () {
      const w = 120, h = 90;
      final page = FastRust.coloringPageRgba(
        width: w,
        height: h,
        cells: 14,
        block: 3,
        seed: 4,
      );
      final photo = FastRust.mandelbrotRgba(
        width: w,
        height: h,
        centerX: -0.7453,
        centerY: 0.1127,
        scale: 0.02 / w,
        maxIterations: 300,
      );
      final rng = Random(8);
      for (final (image, tolerance) in [(page, 0), (photo, 30), (photo, 90)]) {
        for (var k = 0; k < 6; k++) {
          final x = rng.nextInt(w), y = rng.nextInt(h);
          final a = Uint32List(w * h), b = Uint32List(w * h);
          final ma = FastRust.spreadDistancesRgba(
            image,
            a,
            width: w,
            height: h,
            x: x,
            y: y,
            tolerance: tolerance,
          );
          final mb = DartReference.spreadDistancesRgba(
            image,
            b,
            width: w,
            height: h,
            x: x,
            y: y,
            tolerance: tolerance,
          );
          expect(ma, mb);
          expect(a, b, reason: 'distances at ($x,$y) tol $tolerance');
          // Same pixels as a recolor with the same tolerance.
          final recolored = Uint8List(w * h * 4);
          final n = FastRust.recolorRegionRgba(
            image,
            recolored,
            width: w,
            height: h,
            x: x,
            y: y,
            color: 0xffffffff,
            tolerance: tolerance,
          );
          expect(a.where((d) => d != FastRust.unreached).length, n);

          // Painting in rings matches the reference and paints each pixel once.
          final ta = Uint8List(w * h * 4), tb = Uint8List(w * h * 4);
          var total = 0;
          for (var r = 0; r <= ma; r += 37) {
            for (final tint in [false, true]) {
              if (tint != (r ~/ 37).isOdd) continue;
              final pa = FastRust.paintByDistanceRgba(
                image,
                ta,
                a,
                width: w,
                height: h,
                from: r,
                to: r + 37,
                color: 0x8338ecff,
                tint: tint,
              );
              final pb = DartReference.paintByDistanceRgba(
                image,
                tb,
                b,
                width: w,
                height: h,
                from: r,
                to: r + 37,
                color: 0x8338ecff,
                tint: tint,
              );
              expect(pa, pb);
              total += pa;
            }
          }
          expect(total, n);
          expect(ta, tb);
        }
      }
    });

    test('spreads as a round wave in an open area', () {
      const w = 41, h = 41;
      final white = Uint8List.fromList(List.filled(w * h * 4, 255));
      final dist = Uint32List(w * h);
      final max = FastRust.spreadDistancesRgba(
        white,
        dist,
        width: w,
        height: h,
        x: 20,
        y: 20,
      );
      expect(max, 20 * 7);
      expect(dist[20 * w + 30], 50); // 10 px straight
      expect(dist[30 * w + 30], 70); // 10 px diagonal
    });

    test('validation', () {
      final img = Uint8List(16), out = Uint8List(16);
      expect(
        () => FastRust.spreadDistancesRgba(
          img,
          Uint32List(3),
          width: 2,
          height: 2,
          x: 0,
          y: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => FastRust.paintByDistanceRgba(
          img,
          img,
          Uint32List(4),
          width: 2,
          height: 2,
          from: 0,
          to: 1,
          color: 0,
        ),
        throwsArgumentError,
      );
      expect(
        FastRust.paintByDistanceRgba(
          img,
          out,
          Uint32List(4),
          width: 2,
          height: 2,
          from: 0,
          to: 1,
          color: 0x01020304,
        ),
        4,
      );
      expect(out.sublist(0, 4), [1, 2, 3, 4]);
      // distances aliasing an image is rejected, not undefined behaviour.
      final shared = Uint8List(16);
      expect(
        () => FastRust.spreadDistancesRgba(
          shared,
          Uint32List.view(shared.buffer),
          width: 2,
          height: 2,
          x: 0,
          y: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => FastRust.paintByDistanceRgba(
          img,
          shared,
          Uint32List.view(shared.buffer),
          width: 2,
          height: 2,
          from: 0,
          to: 1,
          color: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('photo to coloring page', () {
    const w = 150, h = 110;
    final photo = FastRust.mandelbrotRgba(
      width: w,
      height: h,
      centerX: -0.7453,
      centerY: 0.1127,
      scale: 0.02 / w,
      maxIterations: 300,
    );

    test('matches the Dart reference for several settings', () {
      for (final (colors, smooth, minRegion, lineWidth) in [
        (10, 2, 64, 2),
        (4, 0, 0, 1),
        (16, 4, 200, 3),
        (1, 1, 10, 1),
      ]) {
        final a = FastRust.photoToColoringPage(
          photo,
          width: w,
          height: h,
          colors: colors,
          smooth: smooth,
          minRegion: minRegion,
          lineWidth: lineWidth,
        );
        final b = DartReference.photoToColoringPage(
          photo,
          width: w,
          height: h,
          colors: colors,
          smooth: smooth,
          minRegion: minRegion,
          lineWidth: lineWidth,
        );
        final why =
            'colors $colors smooth $smooth min $minRegion lw $lineWidth';
        expect(a.palette, b.palette, reason: why);
        expect(a.labels, b.labels, reason: why);
        expect(a.rgba, b.rgba, reason: why);
      }
    });

    test('page is black and white, framed, and labels match the ink', () {
      final page = FastRust.photoToColoringPage(photo, width: w, height: h);
      final px = page.rgba;
      var ink = 0;
      for (var i = 0; i < w * h; i++) {
        final v = px[i * 4];
        expect(v == 0 || v == 255, isTrue);
        expect(px[i * 4 + 1], v);
        expect(px[i * 4 + 3], 255);
        expect(page.labels[i] == FastRust.lineLabel, v == 0);
        if (v == 0) ink++;
      }
      expect(px.sublist(0, 4), [0, 0, 0, 255], reason: 'frame');
      expect(ink, inInclusiveRange(w * h ~/ 20, w * h ~/ 2));
      // The page is fillable: a bucket fill stays inside one region.
      final x = page.labels.indexWhere((l) => l != FastRust.lineLabel);
      final n = FastRust.floodFillRgba(
        page.rgba,
        width: w,
        height: h,
        x: x % w,
        y: x ~/ w,
        color: 0xff0000ff,
      );
      expect(n, lessThan(w * h - ink));
    });

    test('async matches sync, and validation', () async {
      final a = await FastRust.photoToColoringPageAsync(
        photo,
        width: w,
        height: h,
      );
      final b = FastRust.photoToColoringPage(photo, width: w, height: h);
      expect(a.rgba, b.rgba);
      expect(
        () => FastRust.photoToColoringPage(
          photo,
          width: w,
          height: h,
          colors: 33,
        ),
        throwsRangeError,
      );
      expect(
        () => FastRust.photoToColoringPage(
          photo,
          width: w,
          height: h,
          lineWidth: 0,
        ),
        throwsRangeError,
      );
      final empty = FastRust.photoToColoringPage(
        Uint8List(0),
        width: 0,
        height: 0,
        colors: 3,
      );
      expect(empty.palette, Uint8List(12));
    });
  });

  group('falling sand', () {
    Uint8List world(int w, int h, int seed) {
      final rng = Random(seed);
      return Uint8List.fromList(
        List.generate(w * h, (i) {
          final r = rng.nextInt(10);
          return r < 3
              ? SandMaterial.sand
              : r < 5
              ? SandMaterial.water
              : r < 6
              ? SandMaterial.wall
              : SandMaterial.empty;
        }),
      );
    }

    test('steps match the Dart reference cell for cell', () {
      for (final (w, h) in [(64, 48), (97, 31), (1, 9), (5, 2)]) {
        final a = world(w, h, w + h), b = Uint8List.fromList(a);
        for (var f = 0; f < 60; f++) {
          final na = FastRust.sandStep(a, width: w, height: h, frame: f);
          final nb = DartReference.sandStep(b, width: w, height: h, frame: f);
          expect(na, nb, reason: '${w}x$h frame $f');
          expect(a, b, reason: '${w}x$h frame $f');
        }
      }
    });

    test('conserves material; sand alone comes to rest', () {
      const w = 40, h = 30;
      final cells = world(w, h, 3);
      int countOf(Uint8List c, int m) => c.where((v) => v == m).length;
      final before = [for (var m = 0; m < 4; m++) countOf(cells, m)];
      for (var f = 0; f < 300; f++) {
        FastRust.sandStep(cells, width: w, height: h, frame: f);
      }
      expect([for (var m = 0; m < 4; m++) countOf(cells, m)], before);

      // Water keeps sloshing on a flat floor; sand and walls settle.
      final dry = Uint8List.fromList(
        world(w, h, 4).map((c) => c == SandMaterial.water ? 0 : c).toList(),
      );
      var moved = 1, f = 0;
      while (moved > 0 && f < 2000) {
        moved = FastRust.sandStep(dry, width: w, height: h, frame: f++);
      }
      expect(f, lessThan(2000), reason: 'sand settles');
    });

    test('render matches the Dart reference, and validation', () {
      const w = 33, h = 21;
      final cells = world(w, h, 9);
      final a = Uint8List(w * h * 4), b = Uint8List(w * h * 4);
      FastRust.sandRenderRgba(cells, a, width: w, height: h);
      DartReference.sandRenderRgba(cells, b, width: w, height: h);
      expect(a, b);
      expect(
        () => FastRust.sandStep(
          Uint8List.fromList([0, 9]),
          width: 1,
          height: 2,
          frame: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => FastRust.sandStep(Uint8List(3), width: 2, height: 2, frame: 0),
        throwsArgumentError,
      );
    });
  });
}
