import 'dart:typed_data';

/// Pure-Dart implementations of the same algorithms as [FastRust], written
/// idiomatically but with care for performance (typed data, no allocation
/// in hot loops). Used as a correctness oracle and as the benchmark
/// baseline. Exception: [sortFloat64] is Dart's own `List.sort`, which
/// differs from Rust's pdqsort (and orders negative NaN differently).
abstract final class DartReference {
  static void grayscaleRgba(Uint8List rgba) {
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final y =
          (77 * rgba[i] + 150 * rgba[i + 1] + 29 * rgba[i + 2] + 128) >> 8;
      rgba[i] = y;
      rgba[i + 1] = y;
      rgba[i + 2] = y;
    }
  }

  /// Same separable running-sum box blur as the Rust version, single thread.
  static void boxBlurRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    required int radius,
  }) {
    if (radius == 0 || width == 0 || height == 0) return;
    final stride = width * 4;
    final d = 2 * radius + 1;
    final half = d ~/ 2;
    final tmp = Uint8List(rgba.length);
    final lastX = width - 1;
    for (var y = 0; y < height; y++) {
      final row = y * stride;
      for (var c = 0; c < 4; c++) {
        var sum = rgba[row + c] * radius;
        for (var i = 0; i <= radius; i++) {
          sum += rgba[row + (i < lastX ? i : lastX) * 4 + c];
        }
        for (var x = 0; x < width; x++) {
          tmp[row + x * 4 + c] = (sum + half) ~/ d;
          final add = x + radius + 1;
          final sub = x - radius;
          sum +=
              rgba[row + (add < lastX ? add : lastX) * 4 + c] -
              rgba[row + (sub > 0 ? sub : 0) * 4 + c];
        }
      }
    }
    final lastY = height - 1;
    final sums = Int32List(stride);
    for (var k = 0; k < d; k++) {
      var y = k - radius;
      y = y < 0 ? 0 : (y > lastY ? lastY : y);
      final row = y * stride;
      for (var i = 0; i < stride; i++) {
        sums[i] += tmp[row + i];
      }
    }
    for (var y = 0; y < height; y++) {
      final out = y * stride;
      for (var i = 0; i < stride; i++) {
        rgba[out + i] = (sums[i] + half) ~/ d;
      }
      final addY = y + radius + 1;
      final subY = y - radius;
      final add = (addY < lastY ? addY : lastY) * stride;
      final sub = (subY > 0 ? subY : 0) * stride;
      for (var i = 0; i < stride; i++) {
        sums[i] += tmp[add + i] - tmp[sub + i];
      }
    }
  }

  static Uint8List mandelbrotRgba({
    required int width,
    required int height,
    double centerX = -0.5,
    double centerY = 0.0,
    required double scale,
    int maxIterations = 256,
  }) {
    final out = Uint8List(width * height * 4);
    final x0 = centerX - scale * width / 2.0;
    final y0 = centerY - scale * height / 2.0;
    var p = 0;
    for (var py = 0; py < height; py++) {
      final cy = y0 + py * scale;
      for (var px = 0; px < width; px++) {
        final cx = x0 + px * scale;
        var x = 0.0, y = 0.0, x2 = 0.0, y2 = 0.0;
        var i = 0;
        while (i < maxIterations && x2 + y2 <= 4.0) {
          y = 2.0 * x * y + cy;
          x = x2 - y2 + cx;
          x2 = x * x;
          y2 = y * y;
          i++;
        }
        if (i >= maxIterations) {
          out[p] = 0;
          out[p + 1] = 0;
          out[p + 2] = 0;
        } else {
          final t = i / maxIterations;
          final u = 1.0 - t;
          out[p] = (9.0 * u * t * t * t * 255.0).toInt();
          out[p + 1] = (15.0 * u * u * t * t * 255.0).toInt();
          out[p + 2] = (8.5 * u * u * u * t * 255.0).toInt();
        }
        out[p + 3] = 255;
        p += 4;
      }
    }
    return out;
  }

  static void sortFloat64(Float64List data) => data.sort();

  static int countPrimes(int limit) {
    if (limit < 2) return 0;
    final size = (limit - 1) ~/ 2 + 1;
    final composite = Uint8List(size);
    for (var i = 1; (2 * i + 1) * (2 * i + 1) <= limit; i++) {
      if (composite[i] == 0) {
        final p = 2 * i + 1;
        for (var j = p * p ~/ 2; j < size; j += p) {
          composite[j] = 1;
        }
      }
    }
    var count = 1;
    for (var i = 1; i < size; i++) {
      if (composite[i] == 0) count++;
    }
    return count;
  }

  static double dot(Float64List a, Float64List b) {
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  /// Same page generator as the Rust side, including its xorshift64 RNG.
  static Uint8List coloringPageRgba({
    required int width,
    required int height,
    int cells = 120,
    int block = 8,
    int seed = 1,
  }) {
    final out = Uint8List(width * height * 4);
    if (width == 0 || height == 0) return out;
    final gw = (width + block - 1) ~/ block;
    final gh = (height + block - 1) ~/ block;
    var state = (seed ^ 0x9E3779B97F4A7C15) | 1;
    int below(int n) {
      state ^= state << 13;
      state ^= state >>> 7;
      state ^= state << 17;
      // (state >> 1) as unsigned is non-negative in Dart's signed 64-bit int.
      return (state >>> 1) % n;
    }

    final sx = Int64List(cells), sy = Int64List(cells);
    for (var i = 0; i < cells; i++) {
      sx[i] = below(gw);
      sy[i] = below(gh);
    }
    final labels = Uint32List(gw * gh);
    for (var gy = 0; gy < gh; gy++) {
      for (var gx = 0; gx < gw; gx++) {
        var best = 0, bestD = -1;
        for (var i = 0; i < cells; i++) {
          final dx = sx[i] - gx, dy = sy[i] - gy;
          final d = dx * dx + dy * dy;
          if (bestD < 0 || d < bestD) {
            bestD = d;
            best = i;
          }
        }
        labels[gy * gw + gx] = best;
      }
    }
    var p = 0;
    for (var y = 0; y < height; y++) {
      final gy = y ~/ block;
      for (var x = 0; x < width; x++) {
        final gx = x ~/ block;
        final l = labels[gy * gw + gx];
        final edge =
            gx == 0 ||
            gy == 0 ||
            gx + 1 == gw ||
            gy + 1 == gh ||
            labels[gy * gw + gx + 1] != l ||
            labels[(gy + 1) * gw + gx] != l;
        final v = edge ? 0 : 255;
        out[p] = v;
        out[p + 1] = v;
        out[p + 2] = v;
        out[p + 3] = 255;
        p += 4;
      }
    }
    return out;
  }

  /// Same scanline flood fill as the Rust side (exact-match fast path
  /// without a visited map; visited map when [tolerance] > 0).
  static int floodFillRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    required int x,
    required int y,
    required int color,
    int tolerance = 0,
  }) {
    final c = [
      (color >> 24) & 0xff,
      (color >> 16) & 0xff,
      (color >> 8) & 0xff,
      color & 0xff,
    ];
    final s = (y * width + x) * 4;
    final t = [rgba[s], rgba[s + 1], rgba[s + 2], rgba[s + 3]];
    if (tolerance == 0) {
      if (t[0] == c[0] && t[1] == c[1] && t[2] == c[2] && t[3] == c[3]) {
        return 0;
      }
      if (rgba.offsetInBytes % 4 == 0) {
        // Compare whole pixels as 32-bit words, like Rust's [u8; 4] ==.
        final px = rgba.buffer.asUint32List(rgba.offsetInBytes, width * height);
        final bytes = ByteData(4);
        for (var i = 0; i < 4; i++) {
          bytes.setUint8(i, t[i]);
        }
        final target = bytes.getUint32(0, Endian.host);
        for (var i = 0; i < 4; i++) {
          bytes.setUint8(i, c[i]);
        }
        final fill = bytes.getUint32(0, Endian.host);
        return _scanline(
          width,
          height,
          x,
          y,
          (i) => px[i] == target,
          (from, to) => px.fillRange(from, to, fill),
        );
      }
    }
    bool near(int p) =>
        (rgba[p] - t[0]).abs() <= tolerance &&
        (rgba[p + 1] - t[1]).abs() <= tolerance &&
        (rgba[p + 2] - t[2]).abs() <= tolerance &&
        (rgba[p + 3] - t[3]).abs() <= tolerance;
    final visited = Uint8List(width * height);
    return _scanline(
      width,
      height,
      x,
      y,
      (i) => visited[i] == 0 && near(i * 4),
      (from, to) {
        for (var i = from; i < to; i++) {
          visited[i] = 1;
          rgba.setRange(i * 4, i * 4 + 4, c);
        }
      },
    );
  }

  static int _scanline(
    int width,
    int height,
    int x,
    int y,
    bool Function(int index) fillable,
    void Function(int from, int to) paint,
  ) {
    final stack = <int>[y * width + x];
    var painted = 0;
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      if (!fillable(i)) continue;
      final yy = i ~/ width;
      final row = yy * width;
      var lx = i - row;
      while (lx > 0 && fillable(row + lx - 1)) {
        lx--;
      }
      var rx = i - row;
      while (rx + 1 < width && fillable(row + rx + 1)) {
        rx++;
      }
      paint(row + lx, row + rx + 1);
      painted += rx - lx + 1;
      for (final ny in [yy - 1, yy + 1]) {
        if (ny < 0 || ny >= height) continue;
        final nrow = ny * width;
        var inRun = false;
        for (var k = lx; k <= rx; k++) {
          final m = fillable(nrow + k);
          if (m && !inRun) stack.add(nrow + k);
          inRun = m;
        }
      }
    }
    return painted;
  }
}
