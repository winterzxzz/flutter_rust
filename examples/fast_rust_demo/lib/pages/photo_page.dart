import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:fast_rust/fast_rust.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../spread.dart';

/// What a tap does on the photo.
enum PhotoMode {
  /// Tint the tapped region, keeping its brightness and texture.
  recolor,

  /// Color splash: the photo starts gray, a tap brings back the original
  /// colors of the tapped region.
  splash,

  /// The photo turned into a coloring page by Rust; taps fill regions with
  /// a flat color.
  lineArt,
}

/// Three ways to paint on a real photo, all on its decoded RGBA bytes:
///
/// * **Recolor**: a tap selects the connected region whose colour is close
///   to the tapped pixel (like a magic wand) and tints it while each pixel
///   keeps its brightness, so hair, leaves and grass keep their detail.
/// * **Splash**: the canvas starts as [FastRust.grayscaleRgba] of the photo;
///   the same selection with `strength: 0` copies the original colours back.
/// * **Line art**: [FastRust.photoToColoringPage] turns the photo into black
///   outlines on white; taps fill its regions with a flat colour.
///
/// Every tap or drag step is one zero-copy Rust call on the UI thread, which
/// reads a pristine source buffer and writes the canvas. With **Spread** on,
/// the colour flows out from the finger frame by frame instead.
class PhotoPage extends StatefulWidget {
  const PhotoPage({super.key, this.asset = 'assets/photo.jpg'});

  final String asset;

  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage>
    with SingleTickerProviderStateMixin {
  static const palette = <Color>[
    Color(0xFFFF4D8D),
    Color(0xFFE63946),
    Color(0xFFF4A261),
    Color(0xFFFFD166),
    Color(0xFF2A9D8F),
    Color(0xFF3A86FF),
    Color(0xFF8338EC),
    Color(0xFF6C4F3D),
  ];
  static const _maxUndo = 20;

  int _width = 0, _height = 0;
  Uint8List? _source; // decoded photo, never modified
  late Uint8List _canvas;
  final _undo = <Uint8List>[];

  Engine _engine = Engine.rust;
  int _colorIndex = 0;
  double _tolerance = 28;
  double _strength = 230;
  bool _showOriginal = false;

  PhotoMode _mode = PhotoMode.recolor;
  ColoringPage? _page; // line-art mode
  double _detail = 6; // colors for the coloring page
  double? _pageMs;
  Engine _pageEngine = Engine.rust;
  bool _building = false; // coloring page being built in the background

  ui.Image? _image, _original;
  bool _decoding = false, _dirty = false;

  double? _lastMs;
  int _lastPixels = 0;
  Offset? _lastPoint; // drag: skip events that stay on the same pixel

  // Spreading fill: colour flows out from the finger.
  bool _spreadMode = true;
  // Running fills with the ticker time they started at (null: next tick).
  final _spreads = <({Spread spread, Duration? born})>[];
  Duration _now = Duration.zero;
  Offset? _lastSeed; // drag: start a new fill every few pixels
  int _strokePixels = 0;
  late final Ticker _ticker;
  static const _spreadSpeed = 450 * FastRust.spreadStep; // units per second

  @override
  void initState() {
    super.initState();
    // Created eagerly: a lazy ticker first touched in dispose() would look
    // up TickerMode on a deactivated element.
    _ticker = createTicker(_onTick);
    _load();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _image?.dispose();
    _original?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bytes = await rootBundle.load(widget.asset);
    final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (!mounted || data == null) {
      image.dispose();
      return;
    }
    setState(() {
      _width = image.width;
      _height = image.height;
      _source = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      _canvas = Uint8List.fromList(_source!);
      _original = image;
    });
    _present();
  }

  static int _rgba(Color c) =>
      (c.toARGB32() << 8 | c.toARGB32() >>> 24) & 0xFFFFFFFF;

  /// Buffer the selection reads: the photo, or the clean coloring page.
  Uint8List get _selectSource =>
      _mode == PhotoMode.lineArt ? _page!.rgba : _source!;

  int get _paintTolerance =>
      _mode == PhotoMode.lineArt ? 0 : _tolerance.round();

  int get _paintStrength => _mode == PhotoMode.splash ? 0 : _strength.round();

  /// The canvas a mode starts from (and Reset returns to).
  Uint8List _base() => switch (_mode) {
    PhotoMode.recolor => Uint8List.fromList(_source!),
    PhotoMode.splash => _grayCopy(),
    PhotoMode.lineArt => Uint8List.fromList(_page!.rgba),
  };

  Uint8List _grayCopy() {
    final out = Uint8List.fromList(_source!);
    _gray(out);
    return out;
  }

  void _gray(Uint8List rgba) => switch (_engine) {
    Engine.rust => FastRust.grayscaleRgba(rgba),
    Engine.dart => DartReference.grayscaleRgba(rgba),
  };

  // A strong blur and merging regions under 0.2% of the photo give a page
  // with shapes big enough to color with a finger.
  static const _pageSmooth = 5;
  int get _pageMinRegion => _width * _height ~/ 500;

  /// Builds the coloring page on a background isolate, so the UI keeps
  /// running even with the slower Dart engine.
  Future<void> _makePage() async {
    setState(() => _building = true);
    final args = (
      src: _source!,
      width: _width,
      height: _height,
      colors: _detail.round(),
      smooth: _pageSmooth,
      minRegion: _pageMinRegion,
      engine: _engine,
    );
    final (ColoringPage, double) result;
    try {
      result = await _buildPageInBackground(args);
    } finally {
      _building = false;
    }
    final (page, ms) = result;
    if (!mounted) return;
    _page = page;
    _pageMs = ms;
    _pageEngine = args.engine;
  }

  Future<void> _setMode(PhotoMode mode) async {
    if (_source == null || _building) return;
    _finishSpread();
    setState(() {
      _mode = mode;
      _lastMs = null;
    });
    if (mode == PhotoMode.lineArt && _page == null) await _makePage();
    if (!mounted || _mode != mode) return;
    _undo.clear();
    _canvas = _base();
    setState(() => _lastMs = null);
    _present();
  }

  Future<void> _regeneratePage() async {
    if (_mode != PhotoMode.lineArt || _building) return;
    _finishSpread();
    setState(() => _lastMs = null);
    await _makePage();
    if (!mounted || _mode != PhotoMode.lineArt) return;
    _undo.clear();
    _canvas = _base();
    setState(() => _lastMs = null);
    _present();
  }

  /// Paints every region of the coloring page in the photo's own colors,
  /// like a finished paint-by-numbers.
  void _reveal() {
    final page = _page;
    if (page == null) return;
    _finishSpread();
    _snapshot();
    final labels = page.labels, pal = page.palette;
    for (var i = 0; i < labels.length; i++) {
      final l = labels[i];
      if (l == FastRust.lineLabel) continue;
      _canvas.setRange(i * 4, i * 4 + 3, pal, l * 4);
    }
    setState(() {});
    _present();
  }

  void _snapshot() {
    _undo.add(Uint8List.fromList(_canvas));
    if (_undo.length > _maxUndo) _undo.removeAt(0);
  }

  void _recolorAt(Offset local, Size size) {
    final source = _source;
    if (source == null) return;
    final x = (local.dx / size.width * _width).floor();
    final y = (local.dy / size.height * _height).floor();
    if (x < 0 || y < 0 || x >= _width || y >= _height) return;
    final point = Offset(x.toDouble(), y.toDouble());
    if (point == _lastPoint) return;
    _lastPoint = point;

    if (_mode == PhotoMode.lineArt) {
      // Flat fill of one page region, at once.
      if (_page!.labels[y * _width + x] == FastRust.lineLabel) return;
      final spread = _newSpread(x, y);
      spread.finish();
      setState(() {
        _lastMs = spread.setupMs + spread.paintMs;
        _lastPixels = spread.painted;
      });
      _present();
      return;
    }
    final color = _rgba(palette[_colorIndex]);
    final tolerance = _paintTolerance, strength = _paintStrength;
    final sw = Stopwatch()..start();
    final n = switch (_engine) {
      Engine.rust => FastRust.recolorRegionRgba(
        source,
        _canvas,
        width: _width,
        height: _height,
        x: x,
        y: y,
        color: color,
        tolerance: tolerance,
        strength: strength,
      ),
      Engine.dart => DartReference.recolorRegionRgba(
        source,
        _canvas,
        width: _width,
        height: _height,
        x: x,
        y: y,
        color: color,
        tolerance: tolerance,
        strength: strength,
      ),
    };
    setState(() {
      _lastMs = sw.elapsedMicroseconds / 1000;
      _lastPixels = n;
    });
    _present();
  }

  void _startStroke(Offset local, Size size) {
    if (_source == null || _building) return;
    _finishSpread();
    _snapshot();
    _lastPoint = null;
    _lastSeed = null;
    _strokePixels = 0;
    if (_spreadMode) {
      _startSpread(local, size);
    } else {
      _recolorAt(local, size);
    }
  }

  void _dragStroke(Offset local, Size size) {
    if (_building) return;
    if (_spreadMode) {
      _startSpread(local, size);
    } else {
      _recolorAt(local, size);
    }
  }

  /// Starts a fill flowing out from [local]; during a drag only every few
  /// pixels, like paint dripping from a brush.
  void _startSpread(Offset local, Size size) {
    final x = (local.dx / size.width * _width).floor();
    final y = (local.dy / size.height * _height).floor();
    if (x < 0 || y < 0 || x >= _width || y >= _height) return;
    final seed = Offset(x.toDouble(), y.toDouble());
    if (_lastSeed != null && (seed - _lastSeed!).distance < 6) return;
    if (_mode == PhotoMode.lineArt &&
        _page!.labels[y * _width + x] == FastRust.lineLabel) {
      return; // on an outline
    }
    _lastSeed = seed;
    final spread = _newSpread(x, y);
    _spreads.add((spread: spread, born: _ticker.isActive ? _now : null));
    _lastMs = spread.setupMs;
    if (!_ticker.isActive) _ticker.start();
  }

  Spread _newSpread(int x, int y) => Spread.start(
    _engine,
    _selectSource,
    _canvas,
    width: _width,
    height: _height,
    x: x,
    y: y,
    color: _rgba(palette[_colorIndex]),
    tolerance: _paintTolerance,
    strength: _paintStrength,
    tint: _mode != PhotoMode.lineArt,
  );

  void _onTick(Duration elapsed) {
    _now = elapsed;
    var frameMs = 0.0;
    for (var i = 0; i < _spreads.length; i++) {
      final (:spread, :born) = _spreads[i];
      if (born == null) _spreads[i] = (spread: spread, born: elapsed);
      final t = (elapsed - (born ?? elapsed)).inMicroseconds / 1e6;
      final before = spread.painted;
      spread.advanceTo((t * _spreadSpeed).round() + 1);
      _strokePixels += spread.painted - before;
      frameMs += spread.paintMs;
    }
    _spreads.removeWhere((r) => r.spread.done);
    if (_spreads.isEmpty) _ticker.stop();
    _showSpread(frameMs);
  }

  void _finishSpread() {
    if (_spreads.isEmpty) return;
    _ticker.stop();
    for (final r in _spreads) {
      final before = r.spread.painted;
      r.spread.finish();
      _strokePixels += r.spread.painted - before;
    }
    _spreads.clear();
    _showSpread(_spreadFrameMs);
  }

  void _showSpread(double frameMs) {
    setState(() {
      _lastPixels = _strokePixels;
      _spreadFrameMs = frameMs;
    });
    _present();
  }

  double _spreadFrameMs = 0;

  /// Uploads the canvas as a new image; coalesces while a decode is running.
  Future<void> _present() async {
    if (_decoding) {
      _dirty = true;
      return;
    }
    _decoding = true;
    try {
      final image = await imageFromRgba(_canvas, _width, _height);
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

  void _undoLast() {
    _finishSpread();
    if (_undo.isEmpty) return;
    _canvas = _undo.removeLast();
    setState(() {});
    _present();
  }

  void _reset() {
    final source = _source;
    if (source == null) return;
    _finishSpread();
    _snapshot();
    _canvas = _base();
    setState(() => _lastMs = null);
    _present();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _image != null && _source != null;
    // Not scrollable: a scroll view would claim vertical drags first.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<PhotoMode>(
            key: const Key('photo-mode'),
            segments: const [
              ButtonSegment(
                value: PhotoMode.recolor,
                label: Text('Recolor'),
                icon: Icon(Icons.brush),
              ),
              ButtonSegment(
                value: PhotoMode.splash,
                label: Text('Splash'),
                icon: Icon(Icons.water_drop),
              ),
              ButtonSegment(
                value: PhotoMode.lineArt,
                label: Text('Line art'),
                icon: Icon(Icons.draw),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => _setMode(s.first),
          ),
          const SizedBox(height: 8),
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
              IconButton(
                tooltip: 'Undo',
                onPressed: _undo.isEmpty ? null : _undoLast,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'Reset',
                onPressed: ready ? _reset : null,
                icon: const Icon(Icons.restart_alt),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _lastMs == null
                ? switch (_mode) {
                    PhotoMode.recolor =>
                      'Tap the hair, the sky or the grass to recolor it',
                    PhotoMode.splash => 'Tap to bring the color back',
                    PhotoMode.lineArt =>
                      _building || _pageMs == null
                          ? 'Building the coloring page…'
                          : 'Page made by ${_pageEngine.name} in '
                                '${_pageMs!.toStringAsFixed(1)} ms · '
                                'tap a region to fill it',
                  }
                : _spreadMode
                ? 'Spread $_lastPixels px · distances '
                      '${_lastMs!.toStringAsFixed(2)} ms · frame '
                      '${_spreadFrameMs.toStringAsFixed(2)} ms'
                : 'Recolored $_lastPixels px in '
                      '${_lastMs!.toStringAsFixed(2)} ms',
            key: const Key('photo-ms'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_mode != PhotoMode.splash)
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
              child: !ready
                  ? const CircularProgressIndicator()
                  : AspectRatio(
                      aspectRatio: _width / _height,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.biggest;
                          return GestureDetector(
                            key: const Key('photo-canvas'),
                            // One undo step per touch: down starts the
                            // stroke (tap or drag), updates extend it.
                            onPanDown: (d) =>
                                _startStroke(d.localPosition, size),
                            onPanUpdate: (d) =>
                                _dragStroke(d.localPosition, size),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: RawImage(
                                image: _showOriginal ? _original : _image,
                                fit: BoxFit.fill,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 4),
          if (_mode == PhotoMode.lineArt)
            _SliderRow(
              label: 'Detail',
              value: _detail,
              min: 3,
              max: 20,
              onChanged: (v) => setState(() => _detail = v),
              onChangeEnd: (_) => _regeneratePage(),
            )
          else
            _SliderRow(
              label: 'Tolerance',
              value: _tolerance,
              max: 128,
              onChanged: (v) => setState(() => _tolerance = v),
            ),
          if (_mode == PhotoMode.recolor)
            _SliderRow(
              label: 'Strength',
              value: _strength,
              max: 255,
              onChanged: (v) => setState(() => _strength = v),
            )
          else
            const SizedBox(height: 48),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilterChip(
                key: const Key('photo-spread'),
                label: const Text('Spread'),
                tooltip: 'Animate the color flowing out from the tap',
                selected: _spreadMode,
                onSelected: (v) => setState(() {
                  _finishSpread();
                  _spreadMode = v;
                }),
              ),
              GestureDetector(
                onTapDown: (_) => setState(() => _showOriginal = true),
                onTapUp: (_) => setState(() => _showOriginal = false),
                onTapCancel: () => setState(() => _showOriginal = false),
                child: const Chip(
                  avatar: Icon(Icons.compare, size: 18),
                  label: Text('Hold: original'),
                ),
              ),
              if (_mode == PhotoMode.lineArt) ...[
                ActionChip(
                  key: const Key('photo-reveal'),
                  avatar: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Reveal'),
                  onPressed: _reveal,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            !ready
                ? 'Decoding photo…'
                : switch (_mode) {
                    PhotoMode.recolor =>
                      '$_width×$_height photo · selection reads the original '
                          'pixels, tint keeps brightness',
                    PhotoMode.splash =>
                      '$_width×$_height photo · grayscale canvas, taps copy '
                          'the original colors back',
                    PhotoMode.lineArt =>
                      '$_width×$_height photo to ${_detail.round()} colors '
                          '· blur, k-means, cleanup, outlines in Rust',
                  },
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.max,
    required this.onChanged,
    this.min = 0,
    this.onChangeEnd,
  });

  final String label;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 76, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            label: '${value.round()}',
            divisions: (max - min).round(),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(
          width: 32,
          child: Text('${value.round()}', textAlign: TextAlign.end),
        ),
      ],
    );
  }
}

typedef _PageArgs = ({
  Uint8List src,
  int width,
  int height,
  int colors,
  int smooth,
  int minRegion,
  Engine engine,
});

/// Top-level so the closure sent to the isolate captures only [a], not the
/// State (a closure made inside a State method captures `this`, which
/// cannot be sent to another isolate).
Future<(ColoringPage, double)> _buildPageInBackground(_PageArgs a) =>
    Isolate.run(() => _buildPage(a));

/// Builds the page and measures how long it took.
(ColoringPage, double) _buildPage(_PageArgs a) {
  final sw = Stopwatch()..start();
  final page = switch (a.engine) {
    Engine.rust => FastRust.photoToColoringPage(
      a.src,
      width: a.width,
      height: a.height,
      colors: a.colors,
      smooth: a.smooth,
      minRegion: a.minRegion,
    ),
    Engine.dart => DartReference.photoToColoringPage(
      a.src,
      width: a.width,
      height: a.height,
      colors: a.colors,
      smooth: a.smooth,
      minRegion: a.minRegion,
    ),
  };
  return (page, sw.elapsedMicroseconds / 1000);
}
