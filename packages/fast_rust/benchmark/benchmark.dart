// Dart vs Rust on identical algorithms and inputs.
//
//   dart run benchmark/benchmark.dart              # JIT (like debug builds)
//   dart build cli -t benchmark/benchmark.dart     # AOT (like release builds)
//   .../bundle/bin/benchmark --json=results.json   # also write raw results
//
// Each case is warmed up, then timed repeatedly; the median is reported.
// Rust is measured on 1 thread (per-core speed) and on all threads.
// Blur and grayscale run repeatedly on the same buffer: their cost does not
// depend on pixel values, so no per-run copy pollutes the timing. Sort must
// start unsorted, so both sides pay the same 8 MB copy per run.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fast_rust/fast_rust.dart';

double _medianMs(void Function() body, {int runs = 9}) {
  for (var i = 0; i < 2; i++) {
    body(); // warm-up (JIT compilation, page faults)
  }
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

final _rows = <List<String>>[];
final _results = <Map<String, Object>>[];

/// Times Dart, Rust on one thread, and Rust on all threads.
void _case(String name, void Function() dart, void Function() rust) {
  final d = _medianMs(dart);
  FastRust.setThreadLimit(1);
  final r1 = _medianMs(rust);
  FastRust.setThreadLimit(0);
  final r = _medianMs(rust);
  _results.add({'name': name, 'dartMs': d, 'rust1Ms': r1, 'rustAllMs': r});
  _rows.add([
    name,
    d.toStringAsFixed(2),
    r1.toStringAsFixed(2),
    '${(d / r1).toStringAsFixed(1)}x',
    r.toStringAsFixed(2),
    '${(d / r).toStringAsFixed(1)}x',
  ]);
}

void main(List<String> args) {
  final rnd = Random(1);
  print('fast_rust benchmark — Rust threads: ${FastRust.threadCount}\n');

  // FFI call overhead: 1M trivial calls.
  final ns =
      _medianMs(() {
        var acc = 0;
        for (var i = 0; i < 1000000; i++) {
          acc = FastRust.add(acc, i);
        }
        if (acc == 42) print('');
      }) *
      1e6 /
      1000000;
  print('FFI call overhead (leaf call): ${ns.toStringAsFixed(1)} ns/call\n');

  final bytes = Uint8List.fromList(
    List.generate(8 << 20, (_) => rnd.nextInt(256)),
  );
  _case(
    'SHA-256 8 MiB (vs package:crypto)',
    () => crypto.sha256.convert(bytes),
    () => FastRust.sha256(bytes),
  );

  const w = 1920, h = 1080;
  final image = Uint8List.fromList(
    List.generate(w * h * 4, (i) => (i * 31) & 0xff),
  );
  final work = Uint8List.fromList(image);
  _case(
    'Grayscale 1920x1080',
    () => DartReference.grayscaleRgba(work),
    () => FastRust.grayscaleRgba(work),
  );
  _case(
    'Box blur 1920x1080 r=12',
    () => DartReference.boxBlurRgba(work, width: w, height: h, radius: 12),
    () => FastRust.boxBlurRgba(work, width: w, height: h, radius: 12),
  );

  _case(
    'Mandelbrot 800x600 x500 iter',
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

  // Bucket fill of a whole 1920x1080 region; alternate colours so every
  // run repaints all 2M pixels.
  final canvas = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
  var flip = false;
  int nextColor() => (flip = !flip) ? 0xff0000ff : 0x00ff00ff;
  _case(
    'Flood fill 1920x1080 region',
    () => DartReference.floodFillRgba(
      canvas,
      width: w,
      height: h,
      x: w ~/ 2,
      y: h ~/ 2,
      color: nextColor(),
    ),
    () => FastRust.floodFillRgba(
      canvas,
      width: w,
      height: h,
      x: w ~/ 2,
      y: h ~/ 2,
      color: nextColor(),
    ),
  );

  // Photo recoloring and the spreading fill on a 1920x1080 "photo" (the
  // canvas above: one solid region, so the whole frame is selected).
  final recolored = Uint8List(w * h * 4);
  _case(
    'Photo recolor 1920x1080 region',
    () => DartReference.recolorRegionRgba(
      canvas,
      recolored,
      width: w,
      height: h,
      x: w ~/ 2,
      y: h ~/ 2,
      color: 0xff4d8dff,
    ),
    () => FastRust.recolorRegionRgba(
      canvas,
      recolored,
      width: w,
      height: h,
      x: w ~/ 2,
      y: h ~/ 2,
      color: 0xff4d8dff,
    ),
  );
  final distances = Uint32List(w * h);
  _case(
    'Spread fill distances 1920x1080',
    () => DartReference.spreadDistancesRgba(
      canvas,
      distances,
      width: w,
      height: h,
      x: w ~/ 2,
      y: h ~/ 2,
    ),
    () => FastRust.spreadDistancesRgba(
      canvas,
      distances,
      width: w,
      height: h,
      x: w ~/ 2,
      y: h ~/ 2,
    ),
  );

  // Photo to coloring page on the 1920x1080 Mandelbrot render ("photo").
  final photo = FastRust.mandelbrotRgba(
    width: w,
    height: h,
    centerX: -0.7453,
    centerY: 0.1127,
    scale: 0.0065 / w,
    maxIterations: 300,
  );
  // Same settings as the demo app: 6 colors, blur 5, merge under 0.2%.
  _case(
    'Photo to coloring page 1920x1080',
    () => DartReference.photoToColoringPage(
      photo,
      width: w,
      height: h,
      colors: 6,
      smooth: 5,
      minRegion: w * h ~/ 500,
    ),
    () => FastRust.photoToColoringPage(
      photo,
      width: w,
      height: h,
      colors: 6,
      smooth: 5,
      minRegion: w * h ~/ 500,
    ),
  );

  // Falling sand: one step of a 1024x1024 grid that starts as random
  // empty/wall/sand/water (25% each) and settles over the runs.
  const sw = 1024;
  final sandRng = Random(5);
  final sandStart = Uint8List.fromList(
    List.generate(sw * sw, (_) => sandRng.nextInt(4)),
  );
  final sandA = Uint8List.fromList(sandStart);
  final sandB = Uint8List.fromList(sandStart);
  var frameA = 0, frameB = 0;
  _case(
    'Falling sand step 1024x1024',
    () => DartReference.sandStep(sandB, width: sw, height: sw, frame: frameB++),
    () => FastRust.sandStep(sandA, width: sw, height: sw, frame: frameA++),
  );

  final doubles = Float64List.fromList(
    List.generate(1000000, (_) => rnd.nextDouble()),
  );
  final sortWork = Float64List(doubles.length);
  _case(
    'Sort 1M doubles (Dart List.sort)',
    () => (sortWork..setAll(0, doubles)).sort(),
    () => FastRust.sortFloat64(sortWork..setAll(0, doubles)),
  );

  _case(
    'Count primes <= 20M',
    () => DartReference.countPrimes(20000000),
    () => FastRust.countPrimes(20000000),
  );

  final other = Float64List.fromList(
    List.generate(1000000, (_) => rnd.nextDouble()),
  );
  _case(
    'Dot product 1M doubles',
    () => DartReference.dot(doubles, other),
    () => FastRust.dot(doubles, other),
  );

  final header = [
    'Case',
    'Dart ms',
    'Rust 1T',
    'x',
    'Rust ${FastRust.threadCount}T',
    'x',
  ];
  final widths = List.generate(
    header.length,
    (c) => [header, ..._rows].map((r) => r[c].length).reduce(max),
  );
  String fmt(List<String> r) => [
    for (var c = 0; c < r.length; c++)
      c == 0 ? r[c].padRight(widths[c]) : r[c].padLeft(widths[c]),
  ].join('  ');
  print(fmt(header));
  print(widths.map((n) => '-' * n).join('  '));
  _rows.map(fmt).forEach(print);

  for (final arg in args) {
    if (arg.startsWith('--json=')) {
      final file = File(arg.substring('--json='.length));
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'threads': FastRust.threadCount,
          'callOverheadNs': ns,
          'os': Platform.operatingSystem,
          'cases': _results,
        }),
      );
      print('\nWrote ${file.path}');
    }
  }
}
