import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fast_rust/fast_rust.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../engine.dart';

/// Pixel-art coloring book. Tap or drag to bucket-fill regions; "Auto"
/// repaints many regions every frame and reports frames per second, which
/// makes the difference between the Rust and Dart fill visible.
class PaintPage extends StatefulWidget {
  const PaintPage({super.key});

  @override
  State<PaintPage> createState() => _PaintPageState();
}

class _PaintPageState extends State<PaintPage>
    with SingleTickerProviderStateMixin {
  static const _size = 1024, _block = 8, _cells = 140;
  static const palette = <Color>[
    Color(0xFFE63946),
    Color(0xFFF4A261),
    Color(0xFFE9C46A),
    Color(0xFF2A9D8F),
    Color(0xFF457B9D),
    Color(0xFF6D597A),
    Color(0xFFFF8FAB),
    Color(0xFF90BE6D),
  ];

  final _rng = Random(7);
  int _seed = 1;
  late Uint8List _page; // pristine page for "Clear"
  late Uint8List _canvas;
  Engine _engine = Engine.rust;
  int _colorIndex = 3;

  ui.Image? _image;
  bool _decoding = false, _dirty = false;

  // Last interaction metrics.
  double? _fillMs;
  int _filled = 0;

  // Auto mode.
  late final Ticker _ticker = createTicker(_onTick);
  double _regionsPerFrame = 40;
  final _frameTimes = <Duration>[];
  double _fps = 0;
  double _autoFillMs = 0;

  @override
  void initState() {
    super.initState();
    _newPage();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _image?.dispose();
    super.dispose();
  }

  void _newPage() {
    _page = FastRust.coloringPageRgba(
      width: _size,
      height: _size,
      cells: _cells,
      block: _block,
      seed: _seed,
    );
    _canvas = Uint8List.fromList(_page);
    _present();
  }

  static int _rgba(Color c) =>
      (c.toARGB32() << 8 | c.toARGB32() >>> 24) & 0xFFFFFFFF;

  /// Fills the region at canvas pixel (x, y); returns painted pixel count.
  int _fill(int x, int y, Color color) {
    final p = (y * _size + x) * 4;
    if (_canvas[p] == 0 && _canvas[p + 1] == 0 && _canvas[p + 2] == 0) {
      return 0; // outline: keep the drawing intact
    }
    final args = (x: x, y: y, color: _rgba(color));
    return switch (_engine) {
      Engine.rust => FastRust.floodFillRgba(
        _canvas,
        width: _size,
        height: _size,
        x: args.x,
        y: args.y,
        color: args.color,
      ),
      Engine.dart => DartReference.floodFillRgba(
        _canvas,
        width: _size,
        height: _size,
        x: args.x,
        y: args.y,
        color: args.color,
      ),
    };
  }

  void _fillAt(Offset local, Size size) {
    final x = (local.dx / size.width * _size).floor();
    final y = (local.dy / size.height * _size).floor();
    if (x < 0 || y < 0 || x >= _size || y >= _size) return;
    final sw = Stopwatch()..start();
    final n = _fill(x, y, palette[_colorIndex]);
    if (n == 0) return;
    setState(() {
      _fillMs = sw.elapsedMicroseconds / 1000;
      _filled = n;
    });
    _present();
  }

  /// Uploads the canvas as a new image; coalesces while a decode is running.
  Future<void> _present() async {
    if (_decoding) {
      _dirty = true;
      return;
    }
    _decoding = true;
    try {
      final image = await imageFromRgba(_canvas, _size, _size);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
      });
    } finally {
      _decoding = false;
    }
    if (_dirty && mounted) {
      _dirty = false;
      _present();
    }
  }

  void _toggleAuto() {
    setState(() {
      if (_ticker.isActive) {
        _ticker.stop();
      } else {
        _frameTimes.clear();
        _fps = 0;
        _ticker.start();
      }
    });
  }

  void _onTick(Duration elapsed) {
    // One batch per presented frame: wait while the previous upload runs.
    if (_decoding) return;
    final sw = Stopwatch()..start();
    for (var i = 0; i < _regionsPerFrame.round(); i++) {
      _fill(
        _rng.nextInt(_size),
        _rng.nextInt(_size),
        palette[_rng.nextInt(palette.length)],
      );
    }
    final ms = sw.elapsedMicroseconds / 1000;
    _frameTimes.add(elapsed);
    _frameTimes.removeWhere((t) => elapsed - t > const Duration(seconds: 1));
    setState(() {
      _autoFillMs = ms;
      _fps = _frameTimes.length.toDouble();
    });
    _present();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auto = _ticker.isActive;
    // Not scrollable on purpose: a scroll view would claim vertical drags
    // before the canvas does, so drag-to-paint would scroll instead.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SegmentedButton<Engine>(
                segments: const [
                  ButtonSegment(value: Engine.rust, label: Text('Rust')),
                  ButtonSegment(value: Engine.dart, label: Text('Dart')),
                ],
                selected: {_engine},
                onSelectionChanged: (s) => setState(() => _engine = s.first),
              ),
              const Spacer(),
              Text(
                auto ? '${_fps.toStringAsFixed(0)} FPS' : '',
                key: const Key('paint-fps'),
                style: theme.textTheme.titleLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            auto
                ? '${_regionsPerFrame.round()} regions/frame · '
                      '${_autoFillMs.toStringAsFixed(2)} ms fill per frame'
                : _fillMs == null
                ? 'Tap or drag on the picture to fill regions'
                : 'Filled $_filled px in ${_fillMs!.toStringAsFixed(2)} ms',
            key: const Key('paint-ms'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < palette.length; i++)
                GestureDetector(
                  onTap: () => setState(() => _colorIndex = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: palette[i],
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: i == _colorIndex
                            ? theme.colorScheme.onSurface
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = constraints.biggest;
                    return GestureDetector(
                      key: const Key('paint-canvas'),
                      onTapDown: (d) => _fillAt(d.localPosition, size),
                      onPanStart: (d) => _fillAt(d.localPosition, size),
                      onPanUpdate: (d) => _fillAt(d.localPosition, size),
                      child: _image == null
                          ? const Center(child: CircularProgressIndicator())
                          : RawImage(
                              image: _image,
                              fit: BoxFit.fill,
                              // Crisp pixel-art squares when scaled.
                              filterQuality: FilterQuality.none,
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
          Row(
            children: [
              const Text('Regions/frame'),
              Expanded(
                child: Slider(
                  value: _regionsPerFrame,
                  min: 1,
                  max: 200,
                  label: '${_regionsPerFrame.round()}',
                  onChanged: (v) => setState(() => _regionsPerFrame = v),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.icon(
                onPressed: _toggleAuto,
                icon: Icon(auto ? Icons.stop : Icons.auto_awesome),
                label: Text(auto ? 'Stop' : 'Auto'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  _canvas = Uint8List.fromList(_page);
                  _present();
                },
                icon: const Icon(Icons.layers_clear),
                label: const Text('Clear'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  _seed++;
                  _newPage();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('New page'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$_size×$_size canvas · $_cells regions on $_block px squares '
            '(generated by Rust) · fills run on the UI thread',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
