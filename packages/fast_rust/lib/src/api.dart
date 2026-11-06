import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as native;

/// Raised when the native library rejects a call.
final class FastRustException implements Exception {
  final String function;
  final int status;

  const FastRustException(this.function, this.status);

  @override
  String toString() =>
      'FastRustException: $function failed with '
      '${switch (status) {
        -1 => 'null pointer',
        -2 => 'invalid argument',
        -3 => 'out of memory',
        _ => 'status $status',
      }}';
}

void _check(String function, int status) {
  if (status != 0) throw FastRustException(function, status);
}

const _maxU32 = 0xFFFFFFFF;

void _checkImage(Uint8List rgba, int width, int height) {
  RangeError.checkValueInInterval(width, 0, _maxU32, 'width');
  RangeError.checkValueInInterval(height, 0, _maxU32, 'height');
  if (rgba.length != width * height * 4) {
    throw ArgumentError(
      'rgba.length (${rgba.length}) must equal width * height * 4 '
      '($width x $height)',
    );
  }
}

/// Runs [body] with a native copy of [data], then copies the result back
/// into a new Dart list. Native memory lets the call be non-leaf.
Uint8List _onNativeCopy(Uint8List data, void Function(Pointer<Uint8>) body) {
  final ptr = malloc<Uint8>(data.isEmpty ? 1 : data.length);
  try {
    final view = ptr.asTypedList(data.length)..setAll(0, data);
    body(ptr);
    return Uint8List.fromList(view);
  } finally {
    malloc.free(ptr);
  }
}

/// Entry point for the Rust-backed kernels.
///
/// **Sync methods** are zero-copy leaf calls on your Dart buffers. They are
/// the fastest option, but block the calling isolate and pause GC for every
/// isolate in the group while they run — keep them to calls of a few
/// milliseconds (e.g. per-frame work like [boxBlurRgba] on a preview).
///
/// **`...Async` methods** run on a background isolate using a native copy
/// of the data and a non-leaf call, so neither the UI thread nor the GC is
/// blocked. Use them for anything longer.
abstract final class FastRust {
  /// Largest accepted [boxBlurRgba] radius.
  static const maxBlurRadius = 1024;

  /// Largest accepted `maxIterations` for [mandelbrotRgba].
  static const maxIterations = 1 << 20;

  /// Largest accepted [countPrimes] limit (the sieve needs `limit/2` bytes).
  static const maxPrimeLimit = (1 << 31) - 1;

  /// Version of the native ABI; changes on any breaking FFI change.
  static int get abiVersion => native.frAbiVersion();

  /// Worker threads Rust uses for the parallel kernels.
  static int get threadCount => native.frThreadCount();

  /// Caps Rust worker threads for all isolates (`0` restores the default:
  /// one per CPU core, at most 16).
  static void setThreadLimit(int limit) {
    RangeError.checkValueInInterval(limit, 0, _maxU32, 'limit');
    native.frSetThreadLimit(limit);
  }

  /// Adds two integers in Rust. Only useful to measure per-call overhead.
  static int add(int a, int b) => native.frAddI64(a, b);

  /// SHA-256 digest of [data] (32 bytes). Zero-copy leaf call.
  static Uint8List sha256(Uint8List data) {
    final out = Uint8List(32);
    _check('sha256', native.frSha256(data.address, data.length, out.address));
    return out;
  }

  /// [sha256] on a background isolate with a non-leaf call.
  static Future<Uint8List> sha256Async(Uint8List data) => Isolate.run(() {
    final ptr = malloc<Uint8>(data.length + 32);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      final out = ptr + data.length;
      _check('sha256', native.frSha256Blocking(ptr, data.length, out));
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      malloc.free(ptr);
    }
  });

  /// Converts an RGBA8888 image to grayscale in place. Alpha is kept.
  static void grayscaleRgba(Uint8List rgba) {
    if (rgba.length % 4 != 0) {
      throw ArgumentError.value(rgba.length, 'rgba.length', 'not RGBA');
    }
    _check('grayscaleRgba', native.frGrayscaleRgba(rgba.address, rgba.length));
  }

  /// Box-blurs an RGBA8888 image in place using all CPU cores. Cost is
  /// O(pixels) for any [radius] in `0..maxBlurRadius`.
  static void boxBlurRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    required int radius,
  }) {
    _checkImage(rgba, width, height);
    RangeError.checkValueInInterval(radius, 0, maxBlurRadius, 'radius');
    _check(
      'boxBlurRgba',
      native.frBoxBlurRgba(rgba.address, width, height, radius),
    );
  }

  /// Like [boxBlurRgba] but on a background isolate with a non-leaf call;
  /// returns a new blurred image and leaves [rgba] untouched.
  static Future<Uint8List> boxBlurRgbaAsync(
    Uint8List rgba, {
    required int width,
    required int height,
    required int radius,
  }) {
    _checkImage(rgba, width, height);
    RangeError.checkValueInInterval(radius, 0, maxBlurRadius, 'radius');
    return Isolate.run(
      () => _onNativeCopy(rgba, (ptr) {
        _check(
          'boxBlurRgba',
          native.frBoxBlurRgbaBlocking(ptr, width, height, radius),
        );
      }),
    );
  }

  /// Renders the Mandelbrot set as RGBA8888 using all CPU cores.
  ///
  /// [scale] is the size of one pixel in the complex plane. Non-leaf call
  /// into native memory.
  static Uint8List mandelbrotRgba({
    required int width,
    required int height,
    double centerX = -0.5,
    double centerY = 0.0,
    required double scale,
    int maxIterations = 256,
  }) {
    RangeError.checkValueInInterval(width, 0, _maxU32, 'width');
    RangeError.checkValueInInterval(height, 0, _maxU32, 'height');
    RangeError.checkValueInInterval(
      maxIterations,
      1,
      FastRust.maxIterations,
      'maxIterations',
    );
    final len = width * height * 4;
    final ptr = malloc<Uint8>(len == 0 ? 1 : len);
    try {
      _check(
        'mandelbrotRgba',
        native.frMandelbrotRgbaBlocking(
          ptr,
          width,
          height,
          centerX,
          centerY,
          scale,
          maxIterations,
        ),
      );
      // Copy into the Dart heap (~1 ms for 4 MB). A finalizer-owned
      // external list would avoid it, but is freed when a worker isolate
      // exits and so cannot be returned from Isolate.run.
      return Uint8List.fromList(ptr.asTypedList(len));
    } finally {
      malloc.free(ptr);
    }
  }

  /// [mandelbrotRgba] on a background isolate.
  static Future<Uint8List> mandelbrotRgbaAsync({
    required int width,
    required int height,
    double centerX = -0.5,
    double centerY = 0.0,
    required double scale,
    int maxIterations = 256,
  }) => Isolate.run(
    () => mandelbrotRgba(
      width: width,
      height: height,
      centerX: centerX,
      centerY: centerY,
      scale: scale,
      maxIterations: maxIterations,
    ),
  );

  /// Sorts [data] ascending in place by IEEE-754 total order:
  /// -NaN < -inf < ... < -0.0 < 0.0 < ... < inf < NaN.
  /// (Dart's `List.sort` instead puts every NaN last.) Zero-copy leaf call.
  static void sortFloat64(Float64List data) {
    _check('sortFloat64', native.frSortF64(data.address, data.length));
  }

  /// [sortFloat64] on a background isolate; returns a sorted copy.
  static Future<Float64List> sortFloat64Async(Float64List data) =>
      Isolate.run(() {
        final ptr = malloc<Double>(data.isEmpty ? 1 : data.length);
        try {
          final view = ptr.asTypedList(data.length)..setAll(0, data);
          _check('sortFloat64', native.frSortF64Blocking(ptr, data.length));
          return Float64List.fromList(view);
        } finally {
          malloc.free(ptr);
        }
      });

  /// Number of primes `<= limit` (`0..maxPrimeLimit`). Non-leaf call.
  static int countPrimes(int limit) {
    RangeError.checkValueInInterval(limit, 0, maxPrimeLimit, 'limit');
    final count = native.frCountPrimesBlocking(limit);
    // u64::MAX reads as -1: the sieve could not be allocated.
    if (count < 0) throw const FastRustException('countPrimes', -3);
    return count;
  }

  /// Dot product of two equally long vectors. Zero-copy leaf call.
  static double dot(Float64List a, Float64List b) {
    if (a.length != b.length) {
      throw ArgumentError('length mismatch: ${a.length} != ${b.length}');
    }
    final out = Float64List(1);
    _check('dot', native.frDotF64(a.address, b.address, a.length, out.address));
    return out[0];
  }
}
