// Regenerates the README images from real output of this library.
//
//   dart build cli -t benchmark/benchmark.dart
//   ./build/cli/<os_arch>/bundle/bin/benchmark --json=../../docs/benchmark.json
//   dart run tool/readme_images.dart ../../docs
//
// Writes into <docs>/images/:
//   mandelbrot.png          rendered by FastRust.mandelbrotRgba
//   blur-before-after.png   source vs FastRust.boxBlurRgba
//   benchmark-light.svg     speedup chart from <docs>/benchmark.json
//   benchmark-dark.svg      same, for dark mode

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_rust/fast_rust.dart';

void main(List<String> args) {
  final docs = Directory(args.isEmpty ? '../../docs' : args.first);
  final images = Directory('${docs.path}/images')..createSync(recursive: true);

  final fractal = FastRust.mandelbrotRgba(
    width: 1600,
    height: 800,
    centerX: -0.7453,
    centerY: 0.1127,
    scale: 0.0065 / 1600,
    maxIterations: 600,
  );
  _writePng('${images.path}/mandelbrot.png', fractal, 1600, 800);

  _writePng(
    '${images.path}/blur-before-after.png',
    _beforeAfter(fractal, 1600, 800),
    1600,
    800,
  );

  final json = File('${docs.path}/benchmark.json');
  if (json.existsSync()) {
    final data = jsonDecode(json.readAsStringSync()) as Map<String, dynamic>;
    for (final dark in [false, true]) {
      final name = dark ? 'benchmark-dark.svg' : 'benchmark-light.svg';
      File('${images.path}/$name').writeAsStringSync(_chart(data, dark: dark));
    }
  } else {
    stderr.writeln('No ${json.path}; skipping charts.');
  }
  print('Images written to ${images.path}');
}

/// Left half untouched, right half blurred, 4 px white divider.
Uint8List _beforeAfter(Uint8List src, int w, int h) {
  final blurred = Uint8List.fromList(src);
  FastRust.boxBlurRgba(blurred, width: w, height: h, radius: 18);
  final out = Uint8List.fromList(src);
  final mid = w ~/ 2;
  for (var y = 0; y < h; y++) {
    final row = y * w * 4;
    out.setRange(row + mid * 4, row + w * 4, blurred, row + mid * 4);
    for (var x = mid - 2; x < mid + 2; x++) {
      out.setRange(row + x * 4, row + x * 4 + 4, const [255, 255, 255, 255]);
    }
  }
  return out;
}

// --- Minimal PNG encoder (RGBA8, no interlace) -----------------------------

void _writePng(String path, Uint8List rgba, int w, int h) {
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < h; y++) {
    raw.addByte(0); // filter: none
    raw.add(Uint8List.sublistView(rgba, y * w * 4, (y + 1) * w * 4));
  }
  final ihdr = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6); // color type RGBA
  final png = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', ihdr.buffer.asUint8List()))
    ..add(_chunk('IDAT', ZLibCodec(level: 9).encode(raw.takeBytes())))
    ..add(_chunk('IEND', const []));
  File(path).writeAsBytesSync(png.takeBytes());
}

Uint8List _chunk(String type, List<int> data) {
  final body = Uint8List(4 + data.length)
    ..setAll(0, ascii.encode(type))
    ..setAll(4, data);
  final out = ByteData(12 + data.length)..setUint32(0, data.length);
  final bytes = out.buffer.asUint8List()..setAll(4, body);
  out.setUint32(8 + data.length, _crc32(body));
  return bytes;
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

// --- Speedup chart (SVG) ---------------------------------------------------

const _labels = {
  'SHA-256': 'SHA-256 8 MiB',
  'Grayscale': 'Grayscale 1080p',
  'Box blur': 'Box blur 1080p',
  'Mandelbrot': 'Mandelbrot 800×600',
  'Flood fill': 'Flood fill 1080p',
  'Sort': 'Sort 1 triệu số',
  'Count primes': 'Sàng nguyên tố 20M',
  'Dot product': 'Tích vô hướng 1M',
};

String _label(String name) => _labels.entries
    .firstWhere(
      (e) => name.startsWith(e.key),
      orElse: () => MapEntry(name, name),
    )
    .value;

String _chart(Map<String, dynamic> data, {required bool dark}) {
  // Validated two-slot categorical palette (blue, orange) per mode.
  final c = dark
      ? (
          surface: '#1a1a19',
          text: '#f0efec',
          muted: '#c3c2b7',
          grid: '#383835',
          s1: '#3987e5',
          s2: '#d95926',
        )
      : (
          surface: '#fcfcfb',
          text: '#0b0b0b',
          muted: '#52514e',
          grid: '#e4e3df',
          s1: '#2a78d6',
          s2: '#eb6834',
        );
  final threads = data['threads'];
  final cases = (data['cases'] as List).cast<Map<String, dynamic>>();
  final rows = [
    for (final k in cases)
      (
        label: _label(k['name'] as String),
        one: (k['dartMs'] as num) / (k['rust1Ms'] as num),
        all: (k['dartMs'] as num) / (k['rustAllMs'] as num),
      ),
  ];
  final maxV = rows
      .expand((r) => [r.one, r.all])
      .reduce((a, b) => a > b ? a : b);
  final axisMax = (maxV / 5).ceil() * 5.0;

  const width = 900, left = 170, right = 60, top = 92, bar = 14, gap = 2;
  const group = bar * 2 + gap + 18;
  final plotW = width - left - right;
  final height = top + rows.length * group + 40;
  double x(num v) => left + v / axisMax * plotW;

  final b = StringBuffer()
    ..writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$width" '
      'height="$height" viewBox="0 0 $width $height" '
      'font-family="-apple-system, Segoe UI, Helvetica, Arial, sans-serif" '
      'role="img" aria-labelledby="t d">',
    )
    ..writeln(
      '<title id="t">fast_rust: Rust nhanh hơn Dart bao nhiêu lần</title>',
    )
    ..writeln(
      '<desc id="d">Hệ số tăng tốc của Rust so với Dart thuần, '
      'khi Rust chạy 1 luồng và $threads luồng.</desc>',
    )
    ..writeln('<rect width="100%" height="100%" rx="12" fill="${c.surface}"/>')
    ..writeln(
      '<text x="24" y="36" font-size="20" font-weight="600" '
      'fill="${c.text}">Rust nhanh hơn Dart bao nhiêu lần</text>',
    )
    ..writeln(
      '<text x="24" y="60" font-size="13" fill="${c.muted}">'
      'Hệ số = thời gian Dart ÷ thời gian Rust · AOT · '
      '${data['os']} · median 9 lần chạy</text>',
    );

  // Legend.
  void legend(double lx, String color, String text) {
    b
      ..writeln(
        '<rect x="$lx" y="72" width="12" height="12" rx="3" fill="$color"/>',
      )
      ..writeln(
        '<text x="${lx + 18}" y="82" font-size="13" '
        'fill="${c.text}">$text</text>',
      );
  }

  legend(width - 330.0, c.s1, 'Rust 1 luồng');
  legend(width - 200.0, c.s2, 'Rust $threads luồng');

  // Grid + axis labels.
  final plotBottom = top + rows.length * group - 10;
  for (var v = 0.0; v <= axisMax; v += 5) {
    b
      ..writeln(
        '<line x1="${x(v)}" y1="${top - 6}" x2="${x(v)}" y2="$plotBottom" '
        'stroke="${c.grid}" stroke-width="1"/>',
      )
      ..writeln(
        '<text x="${x(v)}" y="${plotBottom + 18}" font-size="12" '
        'text-anchor="middle" fill="${c.muted}">${v.toInt()}×</text>',
      );
  }
  // "Same as Dart" reference at 1x.
  b
    ..writeln(
      '<line x1="${x(1)}" y1="${top - 6}" x2="${x(1)}" y2="$plotBottom" '
      'stroke="${c.muted}" stroke-width="1" stroke-dasharray="3 3"/>',
    )
    ..writeln(
      '<text x="${x(1) + 4}" y="${top - 10}" font-size="11" '
      'fill="${c.muted}">1× = ngang Dart</text>',
    );

  // Bars: square at the baseline, 4 px rounded data end.
  String barPath(double y, double v) {
    final x0 = x(0), x1 = x(v), r = (x1 - x0).clamp(0, 4).toDouble();
    return 'M$x0 $y H${x1 - r} Q$x1 $y $x1 ${y + r} V${y + bar - r} '
        'Q$x1 ${y + bar} ${x1 - r} ${y + bar} H$x0 Z';
  }

  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final y = top + i * group.toDouble();
    b.writeln(
      '<text x="${left - 12}" y="${y + bar + 5}" font-size="13" '
      'text-anchor="end" fill="${c.text}">${r.label}</text>',
    );
    for (final (k, v, color) in [(0, r.one, c.s1), (1, r.all, c.s2)]) {
      final by = y + k * (bar + gap);
      b
        ..writeln('<path d="${barPath(by, v)}" fill="$color"/>')
        ..writeln(
          '<text x="${x(v) + 6}" y="${by + bar - 3}" font-size="12" '
          'fill="${c.text}">${v.toStringAsFixed(1)}×</text>',
        );
    }
  }
  b.writeln('</svg>');
  return b.toString();
}
