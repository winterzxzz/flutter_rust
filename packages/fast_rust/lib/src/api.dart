import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
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

void _checkAccum(Float64List accum, int width, int height) {
  RangeError.checkValueInInterval(width, 0, _maxU32, 'width');
  RangeError.checkValueInInterval(height, 0, _maxU32, 'height');
  if (accum.length != width * height * 3) {
    throw ArgumentError(
      'accum.length (${accum.length}) must equal width * height * 3 '
      '($width x $height)',
    );
  }
}

void _checkCells(Uint8List cells, int width, int height) {
  RangeError.checkValueInInterval(width, 0, _maxU32, 'width');
  RangeError.checkValueInInterval(height, 0, _maxU32, 'height');
  if (cells.length != width * height) {
    throw ArgumentError(
      'cells.length (${cells.length}) must equal width * height '
      '($width x $height)',
    );
  }
}

void _checkDistances(Uint32List distances, int width, int height) {
  if (distances.length != width * height) {
    throw ArgumentError(
      'distances.length (${distances.length}) must equal width * height '
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

/// A coloring page made from a photo by [FastRust.photoToColoringPage].
final class ColoringPage {
  const ColoringPage({
    required this.rgba,
    required this.labels,
    required this.palette,
    required this.width,
    required this.height,
  });

  /// Black outlines on white, RGBA8888.
  final Uint8List rgba;

  /// Colour cluster of every pixel, or [FastRust.lineLabel] on outlines.
  final Uint8List labels;

  /// Cluster colours as RGBA8888 (4 bytes per cluster): the photo's own
  /// colours, handy for a "reveal" or color-by-number mode.
  final Uint8List palette;

  final int width, height;
}

/// Camera for [FastRust.pathTrace], orbiting the built-in scene.
///
/// [toArray] turns it into the 19 numbers the tracer takes (origin, focus
/// plane corner and spans, lens axes, lens radius). The trigonometry
/// happens here, once, so Rust and [DartReference] trace from identical
/// numbers.
final class RayCamera {
  const RayCamera({
    this.yaw = 0.5,
    this.pitch = 0.22,
    this.distance = 10,
    this.fieldOfView = 30,
    this.aperture = 0.08,
    this.targetHeight = 0.8,
  });

  /// Angle around the vertical axis, in radians (0: looking along -z).
  final double yaw;

  /// Elevation above the floor, in radians.
  final double pitch;

  /// Distance from the look-at point; also the focus distance.
  final double distance;

  /// Vertical field of view, in degrees.
  final double fieldOfView;

  /// Lens diameter; 0 gives a pinhole camera (no depth of field).
  final double aperture;

  /// Height of the look-at point above the floor.
  final double targetHeight;

  RayCamera copyWith({double? yaw, double? pitch, double? distance}) =>
      RayCamera(
        yaw: yaw ?? this.yaw,
        pitch: pitch ?? this.pitch,
        distance: distance ?? this.distance,
        fieldOfView: fieldOfView,
        aperture: aperture,
        targetHeight: targetHeight,
      );

  /// The packed camera for a [width] x [height] image.
  Float64List toArray(int width, int height) {
    final cp = math.cos(pitch);
    final from = [
      distance * math.sin(yaw) * cp,
      targetHeight + distance * math.sin(pitch),
      distance * math.cos(yaw) * cp,
    ];
    final to = [0.0, targetHeight, 0.0];
    List<double> unit(List<double> v) {
      final l = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
      return [v[0] / l, v[1] / l, v[2] / l];
    }

    final w = unit([from[0] - to[0], from[1] - to[1], from[2] - to[2]]);
    final u = unit([w[2], 0.0, -w[0]]); // up x w, with up = (0, 1, 0)
    final v = [
      w[1] * u[2] - w[2] * u[1],
      w[2] * u[0] - w[0] * u[2],
      w[0] * u[1] - w[1] * u[0],
    ];
    final aspect = height == 0 ? 1.0 : width / height;
    final hh = math.tan(fieldOfView * math.pi / 360);
    final hw = aspect * hh;
    final f = distance;
    final hor = [u[0] * 2 * hw * f, u[1] * 2 * hw * f, u[2] * 2 * hw * f];
    final ver = [v[0] * 2 * hh * f, v[1] * 2 * hh * f, v[2] * 2 * hh * f];
    final ll = [
      for (var i = 0; i < 3; i++) from[i] - hor[i] / 2 - ver[i] / 2 - w[i] * f,
    ];
    return Float64List.fromList([
      ...from,
      ...ll,
      ...hor,
      ...ver,
      ...u,
      ...v,
      aperture / 2,
    ]);
  }
}

/// Cell values of the falling-sand grid used by [FastRust.sandStep].
abstract final class SandMaterial {
  static const empty = 0;
  static const wall = 1;
  static const sand = 2;
  static const water = 3;
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

  /// Largest accepted number of regions for [coloringPageRgba].
  static const maxColoringCells = 65536;

  /// Largest accepted pixel-block size for [coloringPageRgba].
  static const maxColoringBlock = 256;

  /// Largest accepted `grid squares × cells` for [coloringPageRgba]
  /// (`grid squares = ceil(width/block) × ceil(height/block)`); bounds the
  /// cost of the brute-force region search to about a second on a phone.
  static const maxColoringWork = 1 << 31;

  /// Renders a pixel-art coloring page: [cells] Voronoi regions drawn on a
  /// grid of [block]×[block] pixel squares, white with black outlines and a
  /// black frame. Same [seed], same page. Non-leaf, multi-threaded.
  /// Throws [ArgumentError] if the work exceeds [maxColoringWork].
  static Uint8List coloringPageRgba({
    required int width,
    required int height,
    int cells = 120,
    int block = 8,
    int seed = 1,
  }) {
    RangeError.checkValueInInterval(width, 0, _maxU32, 'width');
    RangeError.checkValueInInterval(height, 0, _maxU32, 'height');
    RangeError.checkValueInInterval(cells, 1, maxColoringCells, 'cells');
    RangeError.checkValueInInterval(block, 1, maxColoringBlock, 'block');
    final work =
        ((width + block - 1) ~/ block) *
        ((height + block - 1) ~/ block) *
        cells;
    if (work > maxColoringWork) {
      throw ArgumentError(
        'page too expensive: $work grid squares × cells > $maxColoringWork',
      );
    }
    final len = width * height * 4;
    final ptr = malloc<Uint8>(len == 0 ? 1 : len);
    try {
      _check(
        'coloringPageRgba',
        native.frColoringPageRgbaBlocking(
          ptr,
          width,
          height,
          cells,
          block,
          seed,
        ),
      );
      return Uint8List.fromList(ptr.asTypedList(len));
    } finally {
      malloc.free(ptr);
    }
  }

  /// [coloringPageRgba] on a background isolate.
  static Future<Uint8List> coloringPageRgbaAsync({
    required int width,
    required int height,
    int cells = 120,
    int block = 8,
    int seed = 1,
  }) => Isolate.run(
    () => coloringPageRgba(
      width: width,
      height: height,
      cells: cells,
      block: block,
      seed: seed,
    ),
  );

  /// Bucket fill: paints the 4-connected region around ([x], [y]) whose
  /// pixels are within [tolerance] (per channel, 0..255) of the start pixel
  /// with [color] (`0xRRGGBBAA`). Returns the number of painted pixels.
  /// With `tolerance == 0`, a region that already has [color] is left alone
  /// and 0 is returned; with a tolerance the region is always repainted.
  /// Zero-copy leaf call; a solid full-HD region takes a few milliseconds.
  static int floodFillRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    required int x,
    required int y,
    required int color,
    int tolerance = 0,
  }) {
    _checkImage(rgba, width, height);
    RangeError.checkValueInInterval(x, 0, width - 1, 'x');
    RangeError.checkValueInInterval(y, 0, height - 1, 'y');
    RangeError.checkValueInInterval(color, 0, _maxU32, 'color');
    RangeError.checkValueInInterval(tolerance, 0, 255, 'tolerance');
    if (width * height > _maxU32) {
      throw ArgumentError('image too large for flood fill: ${width}x$height');
    }
    final n = native.frFloodFillRgba(
      rgba.address,
      width,
      height,
      x,
      y,
      color,
      tolerance,
    );
    if (n < 0) throw FastRustException('floodFillRgba', n);
    return n;
  }

  /// Recolours a region of a photo while keeping its texture ("magic wand"
  /// plus tint).
  ///
  /// Selects the 4-connected region of [source] around ([x], [y]) whose RGB
  /// is within [tolerance] (per channel, 0..255) of the tapped pixel, and
  /// writes those pixels into [target] tinted with [color] (`0xRRGGBBAA`,
  /// alpha ignored). Each pixel keeps its own brightness, so hair, leaves
  /// or fabric stay detailed instead of turning into a flat blob.
  /// [strength] (0..255) blends from the original to the full tint.
  ///
  /// [source] is only read, so every tap selects against the original
  /// photo and the same region can be recoloured again. [source] and
  /// [target] must be distinct buffers of `width * height * 4` bytes.
  /// Returns the number of written pixels. Zero-copy leaf call.
  static int recolorRegionRgba(
    Uint8List source,
    Uint8List target, {
    required int width,
    required int height,
    required int x,
    required int y,
    required int color,
    int tolerance = 32,
    int strength = 255,
  }) {
    _checkImage(source, width, height);
    _checkImage(target, width, height);
    RangeError.checkValueInInterval(x, 0, width - 1, 'x');
    RangeError.checkValueInInterval(y, 0, height - 1, 'y');
    RangeError.checkValueInInterval(color, 0, _maxU32, 'color');
    RangeError.checkValueInInterval(tolerance, 0, 255, 'tolerance');
    RangeError.checkValueInInterval(strength, 0, 255, 'strength');
    if (width * height > _maxU32) {
      throw ArgumentError('image too large to recolor: ${width}x$height');
    }
    final n = native.frRecolorRegionRgba(
      source.address,
      target.address,
      width,
      height,
      x,
      y,
      color,
      tolerance,
      strength,
    );
    // Every other argument is checked above; Rust compares the addresses.
    if (n == -2) throw ArgumentError('source and target must not overlap');
    if (n < 0) throw FastRustException('recolorRegionRgba', n);
    return n;
  }

  /// Distance units of one orthogonal pixel step in [spreadDistancesRgba];
  /// a diagonal step costs 7, so the spreading fill grows as a round wave.
  static const spreadStep = 5;

  /// Value of [spreadDistancesRgba] for pixels outside the region.
  static const unreached = 0xFFFFFFFF;

  /// Largest `width * height` accepted by [spreadDistancesRgba], so the
  /// longest distance (7 units per diagonal pixel) stays below [unreached].
  static const maxSpreadPixels = 0xFFFFFFFF ~/ 7;

  /// Spreading fill, step 1 ("paint that flows").
  ///
  /// Selects the 4-connected region of [source] around ([x], [y]) whose RGB
  /// is within [tolerance] of the tapped pixel and writes each pixel's
  /// distance from the tap, measured along the region (it flows around
  /// obstacles), into [distances] in [spreadStep] units per pixel. Pixels
  /// outside the region get [unreached]. Returns the largest distance.
  ///
  /// Then call [paintByDistanceRgba] once per frame with a growing radius
  /// to animate the colour spreading out from the finger. Zero-copy leaf
  /// call, O(pixels). [distances] must be a separate buffer of
  /// `width * height` values, not a view over [source].
  static int spreadDistancesRgba(
    Uint8List source,
    Uint32List distances, {
    required int width,
    required int height,
    required int x,
    required int y,
    int tolerance = 32,
  }) {
    _checkImage(source, width, height);
    _checkDistances(distances, width, height);
    RangeError.checkValueInInterval(x, 0, width - 1, 'x');
    RangeError.checkValueInInterval(y, 0, height - 1, 'y');
    RangeError.checkValueInInterval(tolerance, 0, 255, 'tolerance');
    if (width * height > maxSpreadPixels) {
      throw ArgumentError('image too large to spread: ${width}x$height');
    }
    final n = native.frSpreadDistances(
      source.address,
      distances.address,
      width,
      height,
      x,
      y,
      tolerance,
    );
    // Every other argument is checked above; Rust compares the addresses.
    if (n == -2) throw ArgumentError('distances must not overlap source');
    if (n < 0) throw FastRustException('spreadDistancesRgba', n);
    return n;
  }

  /// Spreading fill, step 2: paints into [target] every pixel whose
  /// [distances] value `d` satisfies `from <= d < to`. Consecutive frames
  /// `0..r1`, `r1..r2`, ... paint each pixel exactly once.
  ///
  /// With [tint] the pixel becomes a brightness-preserving tint of [source]
  /// (as in [recolorRegionRgba], for photos); otherwise it becomes the flat
  /// [color] (`0xRRGGBBAA`, for line art). Returns the number of painted
  /// pixels. [target] must not overlap [source] or [distances]. Zero-copy
  /// leaf call, multi-threaded.
  static int paintByDistanceRgba(
    Uint8List source,
    Uint8List target,
    Uint32List distances, {
    required int width,
    required int height,
    required int from,
    required int to,
    required int color,
    int strength = 255,
    bool tint = false,
  }) {
    _checkImage(source, width, height);
    _checkImage(target, width, height);
    _checkDistances(distances, width, height);
    RangeError.checkValueInInterval(from, 0, _maxU32, 'from');
    RangeError.checkValueInInterval(to, 0, _maxU32, 'to');
    RangeError.checkValueInInterval(color, 0, _maxU32, 'color');
    RangeError.checkValueInInterval(strength, 0, 255, 'strength');
    final n = native.frPaintByDistance(
      source.address,
      target.address,
      distances.address,
      width,
      height,
      from,
      to,
      color,
      strength,
      tint ? 1 : 0,
    );
    if (n == -2) {
      throw ArgumentError('target must not overlap source or distances');
    }
    if (n < 0) throw FastRustException('paintByDistanceRgba', n);
    return n;
  }

  /// Largest accepted `colors` for [photoToColoringPage].
  static const maxPageColors = 32;

  /// Largest accepted `smooth` blur radius for [photoToColoringPage].
  static const maxPageSmooth = 16;

  /// Largest accepted `lineWidth` for [photoToColoringPage].
  static const maxPageLineWidth = 8;

  /// Value of [ColoringPage.labels] on outline pixels.
  static const lineLabel = 255;

  /// Turns a photo into a coloring page: black outlines around regions of
  /// similar colour on a white background, ready for [floodFillRgba] or the
  /// spreading fill.
  ///
  /// Steps (all in Rust, multi-threaded where possible): a box blur of
  /// radius [smooth] removes texture; k-means groups the pixels into
  /// [colors] clusters; two 3x3 majority filters remove speckles; regions
  /// smaller than [minRegion] pixels are merged into the neighbour they
  /// share the most border with; outlines [lineWidth] pixels wide are drawn
  /// where the cluster changes, plus a frame.
  ///
  /// Fewer [colors] and a larger [minRegion] give a simpler page. Non-leaf
  /// call on a native copy; use [photoToColoringPageAsync] on large photos.
  static ColoringPage photoToColoringPage(
    Uint8List rgba, {
    required int width,
    required int height,
    int colors = 10,
    int smooth = 2,
    int minRegion = 64,
    int lineWidth = 2,
  }) {
    _checkImage(rgba, width, height);
    RangeError.checkValueInInterval(colors, 1, maxPageColors, 'colors');
    RangeError.checkValueInInterval(smooth, 0, maxPageSmooth, 'smooth');
    RangeError.checkValueInInterval(minRegion, 0, _maxU32, 'minRegion');
    RangeError.checkValueInInterval(
      lineWidth,
      1,
      maxPageLineWidth,
      'lineWidth',
    );
    final n = width * height;
    final total = n * 4 * 2 + n + colors * 4;
    // calloc: a zero-sized image leaves out/labels/palette untouched.
    final ptr = calloc<Uint8>(total == 0 ? 1 : total);
    try {
      final src = ptr, out = ptr + n * 4, labels = ptr + n * 8;
      final palette = ptr + n * 9;
      src.asTypedList(n * 4).setAll(0, rgba);
      _check(
        'photoToColoringPage',
        native.frPhotoToColoringPageBlocking(
          src,
          out,
          labels,
          palette,
          width,
          height,
          colors,
          smooth,
          minRegion,
          lineWidth,
        ),
      );
      return ColoringPage(
        rgba: Uint8List.fromList(out.asTypedList(n * 4)),
        labels: Uint8List.fromList(labels.asTypedList(n)),
        palette: Uint8List.fromList(palette.asTypedList(colors * 4)),
        width: width,
        height: height,
      );
    } finally {
      calloc.free(ptr);
    }
  }

  /// [photoToColoringPage] on a background isolate.
  static Future<ColoringPage> photoToColoringPageAsync(
    Uint8List rgba, {
    required int width,
    required int height,
    int colors = 10,
    int smooth = 2,
    int minRegion = 64,
    int lineWidth = 2,
  }) {
    _checkImage(rgba, width, height);
    return Isolate.run(
      () => photoToColoringPage(
        rgba,
        width: width,
        height: height,
        colors: colors,
        smooth: smooth,
        minRegion: minRegion,
        lineWidth: lineWidth,
      ),
    );
  }

  /// Advances a falling-sand simulation by one step, in place.
  ///
  /// [cells] holds one [SandMaterial] value per cell, row by row. Sand falls,
  /// slides off slopes and sinks through water; water falls and spreads
  /// sideways; walls never move. Rows are scanned bottom-up and every
  /// particle moves at most once per step. Random choices are a hash of
  /// (x, y, [frame]), so a given grid and frame always give the same result.
  /// Returns the number of particles that moved. Zero-copy leaf call;
  /// single-threaded (the scan is sequential).
  static int sandStep(
    Uint8List cells, {
    required int width,
    required int height,
    required int frame,
  }) {
    _checkCells(cells, width, height);
    RangeError.checkValueInInterval(frame, 0, _maxU32, 'frame');
    final n = native.frSandStep(cells.address, width, height, frame);
    if (n == -2) {
      throw ArgumentError('cells must hold SandMaterial values (0..3)');
    }
    if (n < 0) throw FastRustException('sandStep', n);
    return n;
  }

  /// Renders a falling-sand grid into [rgba] (`width * height * 4` bytes).
  /// Zero-copy leaf call, multi-threaded.
  static void sandRenderRgba(
    Uint8List cells,
    Uint8List rgba, {
    required int width,
    required int height,
  }) {
    _checkCells(cells, width, height);
    _checkImage(rgba, width, height);
    final status = native.frSandRenderRgba(
      cells.address,
      rgba.address,
      width,
      height,
    );
    if (status == -2) throw ArgumentError('cells and rgba must not overlap');
    _check('sandRenderRgba', status);
  }

  /// Largest accepted `samples` per [pathTrace] call.
  static const maxRaySamples = 64;

  /// Largest accepted `maxDepth` (bounces per path) for [pathTrace].
  static const maxRayDepth = 16;

  /// Progressive path tracing of the built-in scene: glass, metal and
  /// diffuse spheres on a checkered floor under a sky.
  ///
  /// Adds [samples] paths per pixel to [accum] (`width * height * 3`
  /// doubles: running RGB sums, row 0 at the top). [firstSample] is the
  /// number of samples already in [accum]; it seeds the random streams, so
  /// pass the running total and the image converges instead of repeating.
  /// Call [pathResolveRgba] to display the average. Rows are traced on all
  /// CPU cores; the result does not depend on the thread count.
  ///
  /// Zero-copy leaf call: keep each call to about a frame of work (for
  /// example 1–2 samples on a few hundred thousand pixels). A leaf call
  /// pauses GC for the whole isolate group while it runs, even on a
  /// background isolate, so split long renders into many short calls.
  static void pathTrace(
    Float64List accum, {
    required int width,
    required int height,
    required Float64List camera,
    required int firstSample,
    int samples = 1,
    int maxDepth = 6,
  }) {
    _checkAccum(accum, width, height);
    if (camera.length != 19) {
      throw ArgumentError('camera must hold 19 values (RayCamera.toArray)');
    }
    RangeError.checkValueInInterval(firstSample, 0, _maxU32, 'firstSample');
    RangeError.checkValueInInterval(samples, 1, maxRaySamples, 'samples');
    RangeError.checkValueInInterval(maxDepth, 1, maxRayDepth, 'maxDepth');
    if (firstSample + samples > _maxU32) {
      throw RangeError('firstSample + samples exceeds 2^32 - 1');
    }
    final status = native.frPathTrace(
      accum.address,
      width,
      height,
      camera.address,
      firstSample,
      samples,
      maxDepth,
    );
    if (status == -2) {
      throw ArgumentError(
        'camera has non-finite values, or the buffers overlap or are too large',
      );
    }
    _check('pathTrace', status);
  }

  /// Writes the average of [sampleCount] accumulated samples into [rgba]
  /// (gamma 2, clamped). Zero-copy leaf call, multi-threaded.
  static void pathResolveRgba(
    Float64List accum,
    Uint8List rgba, {
    required int width,
    required int height,
    required int sampleCount,
  }) {
    _checkAccum(accum, width, height);
    _checkImage(rgba, width, height);
    RangeError.checkValueInInterval(sampleCount, 0, _maxU32, 'sampleCount');
    _check(
      'pathResolveRgba',
      native.frPathResolveRgba(
        accum.address,
        rgba.address,
        width,
        height,
        sampleCount,
      ),
    );
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
