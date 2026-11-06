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
}
