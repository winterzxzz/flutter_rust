import 'dart:ui' as ui;

import 'package:fast_rust/fast_rust.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../spread.dart';

/// Recolours a real photo. A tap selects the connected region whose colour
/// is close to the tapped pixel (like a magic wand) and tints it while each
/// pixel keeps its brightness, so hair, leaves and grass keep their detail.
///
/// The photo is decoded once into RGBA bytes. Every tap or drag step runs
/// one zero-copy [FastRust.recolorRegionRgba] call on the UI thread, which
/// reads the original pixels and writes the canvas.
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

    final color = _rgba(palette[_colorIndex]);
    final tolerance = _tolerance.round(), strength = _strength.round();
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
    if (_source == null) return;
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
    _lastSeed = seed;
    final spread = Spread.start(
      _engine,
      _source!,
      _canvas,
      width: _width,
      height: _height,
      x: x,
      y: y,
      color: _rgba(palette[_colorIndex]),
      tolerance: _tolerance.round(),
      strength: _strength.round(),
      tint: true,
    );
    _spreads.add((spread: spread, born: _ticker.isActive ? _now : null));
    _lastMs = spread.setupMs;
    if (!_ticker.isActive) _ticker.start();
  }

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
    _canvas = Uint8List.fromList(source);
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
                ? 'Tap the hair, the sky or the grass to recolor it'
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
          _SliderRow(
            label: 'Tolerance',
            value: _tolerance,
            max: 128,
            onChanged: (v) => setState(() => _tolerance = v),
          ),
          _SliderRow(
            label: 'Strength',
            value: _strength,
            max: 255,
            onChanged: (v) => setState(() => _strength = v),
          ),
          Row(
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
              const SizedBox(width: 8),
              GestureDetector(
                onTapDown: (_) => setState(() => _showOriginal = true),
                onTapUp: (_) => setState(() => _showOriginal = false),
                onTapCancel: () => setState(() => _showOriginal = false),
                child: const Chip(
                  avatar: Icon(Icons.compare, size: 18),
                  label: Text('Hold: original'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            ready
                ? '$_width×$_height photo · selection reads the original '
                      'pixels, tint keeps brightness'
                : 'Decoding photo…',
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
  });

  final String label;
  final double value, max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 76, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            max: max,
            label: '${value.round()}',
            divisions: max.round(),
            onChanged: onChanged,
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
