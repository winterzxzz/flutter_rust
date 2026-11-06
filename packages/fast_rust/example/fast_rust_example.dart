// A tour of fast_rust. Run it from the package directory:
//
//   dart run example/fast_rust_example.dart
//
// The first run compiles the Rust crate (needs Rust >= 1.88 on PATH).
// Each step runs the same work in Rust and in pure Dart (DartReference),
// checks that both give the same result, and prints both timings.

import 'dart:typed_data';

import 'package:fast_rust/fast_rust.dart';

void main() async {
  print(
    'fast_rust ABI ${FastRust.abiVersion}, '
    '${FastRust.threadCount} worker threads\n',
  );

  // 1. Recolor a region of a "photo" while keeping its texture.
  const w = 1280, h = 800;
  final photo = FastRust.mandelbrotRgba(
    width: w,
    height: h,
    centerX: -0.7453,
    centerY: 0.1127,
    scale: 0.0065 / w,
    maxIterations: 300,
  );
  final rustOut = Uint8List.fromList(photo);
  final dartOut = Uint8List.fromList(photo);
  late int painted;
  final rustMs = _time(() {
    painted = FastRust.recolorRegionRgba(
      photo, // read only: every tap selects against the original
      rustOut,
      width: w,
      height: h,
      x: 10,
      y: 10,
      color: 0xFF4D8DFF, // 0xRRGGBBAA
      tolerance: 40,
    );
  });
  final dartMs = _time(() {
    DartReference.recolorRegionRgba(
      photo,
      dartOut,
      width: w,
      height: h,
      x: 10,
      y: 10,
      color: 0xFF4D8DFF,
      tolerance: 40,
    );
  });
  _report(
    'Recolor $painted px of a ${w}x$h image',
    rustMs,
    dartMs,
    _same(rustOut, dartOut),
  );

  // 2. Bucket fill on a generated pixel-art coloring page.
  final page = FastRust.coloringPageRgba(width: 1024, height: 1024, seed: 3);
  final a = Uint8List.fromList(page), b = Uint8List.fromList(page);
  final fillRust = _time(
    () => FastRust.floodFillRgba(
      a,
      width: 1024,
      height: 1024,
      x: 512,
      y: 512,
      color: 0x2A9D8FFF,
    ),
  );
  final fillDart = _time(
    () => DartReference.floodFillRgba(
      b,
      width: 1024,
      height: 1024,
      x: 512,
      y: 512,
      color: 0x2A9D8FFF,
    ),
  );
  _report('Flood fill on a 1024x1024 page', fillRust, fillDart, _same(a, b));

  // 3. Box blur, multi-threaded, in place.
  final blurA = Uint8List.fromList(photo), blurB = Uint8List.fromList(photo);
  final blurRust = _time(
    () => FastRust.boxBlurRgba(blurA, width: w, height: h, radius: 12),
  );
  final blurDart = _time(
    () => DartReference.boxBlurRgba(blurB, width: w, height: h, radius: 12),
  );
  _report('Box blur r=12, ${w}x$h', blurRust, blurDart, _same(blurA, blurB));

  // 4. SHA-256 of 8 MiB.
  final data = Uint8List(8 << 20);
  for (var i = 0; i < data.length; i++) {
    data[i] = i * 31;
  }
  late Uint8List digest;
  final shaMs = _time(() => digest = FastRust.sha256(data));
  print(
    'SHA-256 of 8 MiB: ${_hex(digest).substring(0, 16)}… '
    'in ${shaMs.toStringAsFixed(2)} ms',
  );

  // 5. Heavy work off the UI isolate: the Async variants never block it.
  final sorted = await FastRust.sortFloat64Async(
    Float64List.fromList(List.generate(1000000, (i) => (i * 7919) % 1000003.0)),
  );
  print(
    'Sorted 1M doubles on a background isolate: '
    'first ${sorted.first}, last ${sorted.last}',
  );
  print('Primes <= 10,000,000: ${FastRust.countPrimes(10000000)}');
}

double _time(void Function() body) {
  final sw = Stopwatch()..start();
  body();
  return sw.elapsedMicroseconds / 1000;
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _report(String what, double rustMs, double dartMs, bool same) {
  print(
    '$what\n'
    '  Rust ${rustMs.toStringAsFixed(2)} ms · '
    'Dart ${dartMs.toStringAsFixed(2)} ms · '
    '${(dartMs / rustMs).toStringAsFixed(1)}x · '
    '${same ? 'identical output' : 'OUTPUT DIFFERS'}\n',
  );
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
