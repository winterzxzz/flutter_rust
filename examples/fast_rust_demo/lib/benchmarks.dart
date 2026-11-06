import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fast_rust/fast_rust.dart';

/// One benchmark: the same work done by Dart and by Rust.
class BenchCase {
  final String name;
  final String detail;

  /// Builds fresh input and returns `(dart, rust)` closures over it.
  final (void Function(), void Function()) Function() setUp;

  const BenchCase(this.name, this.detail, this.setUp);
}

class BenchResult {
  final String name;
  final double dartMs;
  final double rustMs;

  const BenchResult(this.name, this.dartMs, this.rustMs);

  double get speedup => dartMs / rustMs;
}

Uint8List _bytes(int n) {
  final r = Random(1);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Float64List _doubles(int n, int seed) {
  final r = Random(seed);
  return Float64List.fromList(List.generate(n, (_) => r.nextDouble()));
}

final benchCases = <BenchCase>[
  BenchCase('Box blur', '1920×1080 RGBA, radius 12', () {
    // Cost does not depend on pixel values: reuse one buffer, no copy.
    final work = _bytes(1920 * 1080 * 4);
    return (
      () => DartReference.boxBlurRgba(
        work,
        width: 1920,
        height: 1080,
        radius: 12,
      ),
      () => FastRust.boxBlurRgba(work, width: 1920, height: 1080, radius: 12),
    );
  }),
  BenchCase('Grayscale', '1920×1080 RGBA', () {
    final work = _bytes(1920 * 1080 * 4);
    return (
      () => DartReference.grayscaleRgba(work),
      () => FastRust.grayscaleRgba(work),
    );
  }),
  BenchCase('Mandelbrot', '800×600, 500 iterations', () {
    return (
      () => DartReference.mandelbrotRgba(
        width: 800,
        height: 600,
        scale: 3.0 / 800,
        maxIterations: 500,
      ),
      () => FastRust.mandelbrotRgba(
        width: 800,
        height: 600,
        scale: 3.0 / 800,
        maxIterations: 500,
      ),
    );
  }),
  BenchCase('Sort', '1,000,000 doubles (Dart: List.sort)', () {
    final src = _doubles(1000000, 2);
    final work = Float64List(src.length);
    return (
      () => (work..setAll(0, src)).sort(),
      () => FastRust.sortFloat64(work..setAll(0, src)),
    );
  }),
  BenchCase('SHA-256', '8 MiB buffer (Dart: package:crypto)', () {
    final data = _bytes(8 << 20);
    return (() => crypto.sha256.convert(data), () => FastRust.sha256(data));
  }),
  BenchCase('Prime sieve', 'count primes ≤ 20,000,000', () {
    return (
      () => DartReference.countPrimes(20000000),
      () => FastRust.countPrimes(20000000),
    );
  }),
];

double _medianMs(void Function() body, int runs) {
  body(); // warm-up
  final times = <double>[];
  final sw = Stopwatch();
  for (var i = 0; i < runs; i++) {
    sw
      ..reset()
      ..start();
    body();
    sw.stop();
    times.add(sw.elapsedMicroseconds / 1000);
  }
  times.sort();
  return times[times.length ~/ 2];
}

/// Runs one case on a background isolate so the UI thread is free. The
/// sync Rust calls are leaf calls (~20 ms each on a desktop, longer on
/// phones), which can delay a UI-isolate GC while they run.
Future<BenchResult> runBenchCase(int index, {int runs = 5}) {
  return Isolate.run(() {
    final c = benchCases[index];
    final (dart, rust) = c.setUp();
    return BenchResult(c.name, _medianMs(dart, runs), _medianMs(rust, runs));
  });
}
