import 'dart:typed_data';

import 'api.dart' show ColoringPage;

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

  /// Same luminance-preserving tint as the Rust side, bit for bit.
  static void _tint(Uint8List src, int p, Uint8List dst, List<int> c, int s) {
    final l = (77 * src[p] + 150 * src[p + 1] + 29 * src[p + 2]) >> 8;
    for (var k = 0; k < 3; k++) {
      final ch = c[k];
      var shaded = l < 128 ? ch * l ~/ 127 : ch + (255 - ch) * (l - 128) ~/ 127;
      if (shaded > 255) shaded = 255;
      dst[p + k] = (src[p + k] * (255 - s) + shaded * s + 127) ~/ 255;
    }
    dst[p + 3] = src[p + 3];
  }

  /// Same selection and tint as [FastRust.recolorRegionRgba].
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
    final c = [(color >> 24) & 0xff, (color >> 16) & 0xff, (color >> 8) & 0xff];
    final s = (y * width + x) * 4;
    final t0 = source[s], t1 = source[s + 1], t2 = source[s + 2];
    final visited = Uint8List(width * height);
    return _scanline(
      width,
      height,
      x,
      y,
      (i) {
        if (visited[i] != 0) return false;
        final p = i * 4;
        return (source[p] - t0).abs() <= tolerance &&
            (source[p + 1] - t1).abs() <= tolerance &&
            (source[p + 2] - t2).abs() <= tolerance;
      },
      (from, to) {
        for (var i = from; i < to; i++) {
          visited[i] = 1;
          _tint(source, i * 4, target, c, strength);
        }
      },
    );
  }

  /// Same geodesic distances as [FastRust.spreadDistancesRgba] (Dijkstra
  /// with 5/7 chamfer steps; shortest distances are unique, so the result
  /// matches Rust exactly).
  static int spreadDistancesRgba(
    Uint8List source,
    Uint32List distances, {
    required int width,
    required int height,
    required int x,
    required int y,
    int tolerance = 32,
  }) {
    const unreached = 0xFFFFFFFF, ring = 8;
    distances.fillRange(0, distances.length, unreached);
    final s = (y * width + x) * 4;
    final t0 = source[s], t1 = source[s + 1], t2 = source[s + 2];
    bool ok(int nx, int ny) {
      if (nx < 0 || ny < 0 || nx >= width || ny >= height) return false;
      final p = (ny * width + nx) * 4;
      return (source[p] - t0).abs() <= tolerance &&
          (source[p + 1] - t1).abs() <= tolerance &&
          (source[p + 2] - t2).abs() <= tolerance;
    }

    final buckets = List.generate(ring, (_) => <int>[]);
    distances[y * width + x] = 0;
    buckets[0].add(y * width + x);
    var pending = 1, d = 0, max = 0;
    while (pending > 0) {
      final bucket = buckets[d % ring];
      while (bucket.isNotEmpty) {
        final i = bucket.removeLast();
        pending--;
        if (distances[i] != d) continue;
        max = d;
        final px = i % width, py = i ~/ width;
        void relax(int nx, int ny, int step) {
          final j = ny * width + nx, nd = d + step;
          if (nd < distances[j]) {
            distances[j] = nd;
            buckets[nd % ring].add(j);
            pending++;
          }
        }

        final l = ok(px - 1, py), r = ok(px + 1, py);
        final u = ok(px, py - 1), dn = ok(px, py + 1);
        if (l) relax(px - 1, py, 5);
        if (r) relax(px + 1, py, 5);
        if (u) relax(px, py - 1, 5);
        if (dn) relax(px, py + 1, 5);
        if ((l || u) && ok(px - 1, py - 1)) relax(px - 1, py - 1, 7);
        if ((r || u) && ok(px + 1, py - 1)) relax(px + 1, py - 1, 7);
        if ((l || dn) && ok(px - 1, py + 1)) relax(px - 1, py + 1, 7);
        if ((r || dn) && ok(px + 1, py + 1)) relax(px + 1, py + 1, 7);
      }
      d++;
    }
    return max;
  }

  /// Same as [FastRust.paintByDistanceRgba].
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
    final c = [
      (color >> 24) & 0xff,
      (color >> 16) & 0xff,
      (color >> 8) & 0xff,
      color & 0xff,
    ];
    var n = 0;
    for (var i = 0; i < width * height; i++) {
      final d = distances[i];
      if (d < from || d >= to) continue;
      if (tint) {
        _tint(source, i * 4, target, c, strength);
      } else {
        target.setRange(i * 4, i * 4 + 4, c);
      }
      n++;
    }
    return n;
  }

  /// Same pipeline as [FastRust.photoToColoringPage], single-threaded.
  static ColoringPage photoToColoringPage(
    Uint8List rgba, {
    required int width,
    required int height,
    int colors = 10,
    int smooth = 2,
    int minRegion = 64,
    int lineWidth = 2,
  }) {
    final n = width * height;
    final k = colors.clamp(1, 32);
    final out = Uint8List(n * 4);
    final labelsOut = Uint8List(n);
    final palette = Uint8List(k * 4);
    if (n == 0) {
      return ColoringPage(
        rgba: out,
        labels: labelsOut,
        palette: palette,
        width: width,
        height: height,
      );
    }
    final work = Uint8List.fromList(rgba);
    boxBlurRgba(
      work,
      width: width,
      height: height,
      radius: smooth.clamp(0, 16),
    );

    int luma(int p) =>
        (77 * work[p] + 150 * work[p + 1] + 29 * work[p + 2]) >> 8;

    // Initial centroids from luminance quantiles.
    final count = List<int>.filled(256, 0);
    final sum = List<int>.filled(256 * 3, 0);
    for (var i = 0; i < n; i++) {
      final p = i * 4, l = luma(p);
      count[l]++;
      sum[l * 3] += work[p];
      sum[l * 3 + 1] += work[p + 1];
      sum[l * 3 + 2] += work[p + 2];
    }
    final cr = List<int>.filled(k, 0), cg = List<int>.filled(k, 0);
    final cb = List<int>.filled(k, 0);
    var l = 0, seen = 0;
    for (var part = 0; part < k; part++) {
      final end = n * (part + 1) ~/ k;
      var cnt = 0, sr = 0, sg = 0, sb = 0;
      while (l < 256 && seen + count[l] <= end) {
        cnt += count[l];
        sr += sum[l * 3];
        sg += sum[l * 3 + 1];
        sb += sum[l * 3 + 2];
        seen += count[l];
        l++;
      }
      if (cnt == 0) {
        final g = l < 255 ? l : 255;
        cr[part] = g;
        cg[part] = g;
        cb[part] = g;
      } else {
        cr[part] = sr ~/ cnt;
        cg[part] = sg ~/ cnt;
        cb[part] = sb ~/ cnt;
      }
    }

    final labels = Uint8List(n);
    void assign() {
      for (var i = 0; i < n; i++) {
        final p = i * 4;
        var best = -1, bestD = 0;
        for (var c = 0; c < k; c++) {
          final dr = work[p] - cr[c], dg = work[p + 1] - cg[c];
          final db = work[p + 2] - cb[c];
          final d = dr * dr + dg * dg + db * db;
          if (best < 0 || d < bestD) {
            best = c;
            bestD = d;
          }
        }
        labels[i] = best;
      }
    }

    for (var it = 0; it < 6; it++) {
      assign();
      final cnt = List<int>.filled(k, 0);
      final sr = List<int>.filled(k, 0), sg = List<int>.filled(k, 0);
      final sb = List<int>.filled(k, 0);
      for (var i = 0; i < n; i++) {
        final c = labels[i], p = i * 4;
        cnt[c]++;
        sr[c] += work[p];
        sg[c] += work[p + 1];
        sb[c] += work[p + 2];
      }
      for (var c = 0; c < k; c++) {
        if (cnt[c] > 0) {
          cr[c] = sr[c] ~/ cnt[c];
          cg[c] = sg[c] ~/ cnt[c];
          cb[c] = sb[c] ~/ cnt[c];
        }
      }
    }
    assign();

    // Majority filter, twice.
    final hist = List<int>.filled(k, 0);
    for (var pass = 0; pass < 2; pass++) {
      final prev = Uint8List.fromList(labels);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          hist.fillRange(0, k, 0);
          for (var dy = -1; dy <= 1; dy++) {
            final yy = (y + dy).clamp(0, height - 1);
            for (var dx = -1; dx <= 1; dx++) {
              final xx = (x + dx).clamp(0, width - 1);
              hist[prev[yy * width + xx]]++;
            }
          }
          final cur = prev[y * width + x];
          var max = 0;
          for (final h in hist) {
            if (h > max) max = h;
          }
          labels[y * width + x] = hist[cur] == max ? cur : hist.indexOf(max);
        }
      }
    }

    // Merge small regions in scan order of their first pixel; repeat until
    // stable (at most 8 passes), like the Rust side.
    for (var pass = 0; minRegion > 1 && pass < 8; pass++) {
      var changed = false;
      final comp = Int32List(n)..fillRange(0, n, -1);
      final members = <List<int>>[];
      for (var start = 0; start < n; start++) {
        if (comp[start] >= 0) continue;
        final id = members.length, lab = labels[start];
        final list = <int>[];
        final stack = <int>[start];
        comp[start] = id;
        while (stack.isNotEmpty) {
          final i = stack.removeLast();
          list.add(i);
          final x = i % width, y = i ~/ width;
          void visit(int j) {
            if (comp[j] < 0 && labels[j] == lab) {
              comp[j] = id;
              stack.add(j);
            }
          }

          if (x > 0) visit(i - 1);
          if (x + 1 < width) visit(i + 1);
          if (y > 0) visit(i - width);
          if (y + 1 < height) visit(i + width);
        }
        members.add(list);
      }
      for (final pixels in members) {
        if (pixels.length >= minRegion) continue;
        pixels.sort();
        final own = labels[pixels[0]];
        hist.fillRange(0, k, 0);
        for (final i in pixels) {
          final x = i % width, y = i ~/ width;
          void count(int j) {
            final lj = labels[j];
            if (lj != own) hist[lj]++;
          }

          if (x > 0) count(i - 1);
          if (x + 1 < width) count(i + 1);
          if (y > 0) count(i - width);
          if (y + 1 < height) count(i + width);
        }
        var max = 0;
        for (final h in hist) {
          if (h > max) max = h;
        }
        if (max == 0) continue;
        final target = hist.indexOf(max);
        for (final i in pixels) {
          labels[i] = target;
        }
        changed = true;
      }
      if (!changed) break;
    }

    // Outlines.
    final lw = lineWidth.clamp(1, 8);
    final a = (lw - 1) ~/ 2, b = lw - 1 - a;
    final seeds = Uint8List(n);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x, lab = labels[i];
        if ((x + 1 < width && labels[i + 1] != lab) ||
            (y + 1 < height && labels[i + width] != lab)) {
          seeds[i] = 1;
        }
      }
    }
    final horiz = Uint8List(n);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final lo = x - b < 0 ? 0 : x - b;
        final hi = x + a > width - 1 ? width - 1 : x + a;
        for (var xx = lo; xx <= hi; xx++) {
          if (seeds[y * width + xx] != 0) {
            horiz[y * width + x] = 1;
            break;
          }
        }
      }
    }
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var line = x < lw || y < lw || x + lw >= width || y + lw >= height;
        if (!line) {
          final lo = y - b < 0 ? 0 : y - b;
          final hi = y + a > height - 1 ? height - 1 : y + a;
          for (var yy = lo; yy <= hi; yy++) {
            if (horiz[yy * width + x] != 0) {
              line = true;
              break;
            }
          }
        }
        final i = y * width + x, p = i * 4;
        final v = line ? 0 : 255;
        out[p] = v;
        out[p + 1] = v;
        out[p + 2] = v;
        out[p + 3] = 255;
        labelsOut[i] = line ? 255 : labels[i];
      }
    }
    for (var c = 0; c < k; c++) {
      palette[c * 4] = cr[c];
      palette[c * 4 + 1] = cg[c];
      palette[c * 4 + 2] = cb[c];
      palette[c * 4 + 3] = 255;
    }
    return ColoringPage(
      rgba: out,
      labels: labelsOut,
      palette: palette,
      width: width,
      height: height,
    );
  }

  /// Same 32-bit hash as the Rust sand kernel.
  static int _sandHash(int x, int y, int frame) {
    var h =
        ((x * 0x9E3779B1) ^ (y * 0x85EBCA77) ^ (frame * 0xC2B2AE3D)) &
        0xFFFFFFFF;
    h ^= h >>> 15;
    h = (h * 0x2C1B3C6D) & 0xFFFFFFFF;
    h ^= h >>> 12;
    return h;
  }

  /// Same rules and scan order as [FastRust.sandStep].
  static int sandStep(
    Uint8List cells, {
    required int width,
    required int height,
    required int frame,
  }) {
    if (width == 0 || height < 2) return 0;
    const empty = 0, sand = 2, water = 3, movedBit = 0x80;
    var moved = 0;
    final rightward = frame % 2 == 0;
    for (var y = height - 2; y >= 0; y--) {
      for (var k = 0; k < width; k++) {
        final x = rightward ? k : width - 1 - k;
        final i = y * width + x;
        final c = cells[i];
        if (c & movedBit != 0) continue;
        final kind = c & 0x7F;
        if (kind != sand && kind != water) continue;
        final below = i + width;
        bool free(int t) => t == empty || (kind == sand && t == water);
        var target = -1;
        if (free(cells[below])) {
          target = below;
        } else {
          final h = _sandHash(x, y, frame);
          final firstLeft = h & 1 == 0;
          for (final left in [firstLeft, !firstLeft]) {
            if (left && x > 0 && free(cells[below - 1])) {
              target = below - 1;
              break;
            }
            if (!left && x + 1 < width && free(cells[below + 1])) {
              target = below + 1;
              break;
            }
          }
          if (target < 0 && kind == water) {
            final firstLeft = h & 2 == 0;
            for (final left in [firstLeft, !firstLeft]) {
              if (left && x > 0 && cells[i - 1] == empty) {
                target = i - 1;
                break;
              }
              if (!left && x + 1 < width && cells[i + 1] == empty) {
                target = i + 1;
                break;
              }
            }
          }
        }
        if (target >= 0) {
          final displaced = cells[target];
          cells[i] = displaced == empty ? empty : displaced | movedBit;
          cells[target] = kind | movedBit;
          moved++;
        }
      }
    }
    for (var i = 0; i < cells.length; i++) {
      cells[i] &= 0x7F;
    }
    return moved;
  }

  /// Same colours as [FastRust.sandRenderRgba].
  static void sandRenderRgba(
    Uint8List cells,
    Uint8List rgba, {
    required int width,
    required int height,
  }) {
    for (var i = 0; i < width * height; i++) {
      final v = _sandHash(i, 0x51ED, 7) & 31;
      final p = i * 4;
      switch (cells[i] & 0x7F) {
        case 1:
          rgba[p] = 90 + v;
          rgba[p + 1] = 92 + v;
          rgba[p + 2] = 104 + v;
        case 2:
          rgba[p] = 214 + v ~/ 2;
          rgba[p + 1] = 178 + v ~/ 2;
          rgba[p + 2] = 92 + v;
        case 3:
          rgba[p] = 40;
          rgba[p + 1] = 110 + v ~/ 2;
          rgba[p + 2] = 230;
        default:
          rgba[p] = 16;
          rgba[p + 1] = 20;
          rgba[p + 2] = 32;
      }
      rgba[p + 3] = 255;
    }
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
