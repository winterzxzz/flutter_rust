import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fast_rust/fast_rust.dart';
import 'package:flutter/material.dart';

import '../engine.dart';

/// Renders on a background isolate and returns pixels plus compute time.
///
/// Top-level on purpose: a closure created inside a State method shares that
/// method's context, which holds `this` (the State, its Element tree, ...),
/// and Isolate.run would fail with "object is unsendable".
Future<(Uint8List, double)> _renderInBackground(
  Engine engine,
  int w,
  int h,
  double cx,
  double cy,
  double scale,
  int iter,
) => Isolate.run(() => _renderTimed(engine, w, h, cx, cy, scale, iter));

(Uint8List, double) _renderTimed(
  Engine engine,
  int w,
  int h,
  double cx,
  double cy,
  double scale,
  int iter,
) {
  final sw = Stopwatch()..start();
  final Uint8List px = switch (engine) {
    Engine.rust => FastRust.mandelbrotRgba(
      width: w,
      height: h,
      centerX: cx,
      centerY: cy,
      scale: scale,
      maxIterations: iter,
    ),
    Engine.dart => DartReference.mandelbrotRgba(
      width: w,
      height: h,
      centerX: cx,
      centerY: cy,
      scale: scale,
      maxIterations: iter,
    ),
  };
  return (px, sw.elapsedMicroseconds / 1000);
}

/// Interactive Mandelbrot explorer. Tap to zoom in at a point. Rendering
/// happens on a background isolate for both engines (Rust via a non-leaf
/// call, so the UI isolate's GC is never blocked) and the timing shown is
/// pure compute time.
class FractalPage extends StatefulWidget {
  const FractalPage({super.key});

  @override
  State<FractalPage> createState() => _FractalPageState();
}

class _FractalPageState extends State<FractalPage> {
  static const _maxSide = 1200;

  Engine _engine = Engine.rust;
  double _cx = -0.5, _cy = 0.0;
  double _span = 3.2; // width of the view in the complex plane
  int _maxIter = 400;

  ui.Image? _image;
  double? _lastMs;
  bool _busy = false;
  bool _dirty = false;
  String? _error;
  Size _pixelSize = Size.zero;

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _render() async {
    if (_pixelSize.isEmpty) return;
    if (_busy) {
      _dirty = true; // coalesce: re-render once the current frame is done
      return;
    }
    _busy = true;
    try {
      final w = _pixelSize.width.round();
      final h = _pixelSize.height.round();
      final scale = _span / w;
      final (pixels, ms) = await _renderInBackground(
        _engine,
        w,
        h,
        _cx,
        _cy,
        scale,
        _maxIter,
      );
      final image = await imageFromRgba(pixels, w, h);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _lastMs = ms;
        _error = null;
      });
    } catch (e) {
      // e.g. a viewport zoomed out to infinity; keep the page usable.
      if (mounted) setState(() => _error = '$e');
    } finally {
      _busy = false;
    }
    if (_dirty && mounted) {
      _dirty = false;
      _render();
    }
  }

  void _zoomAt(Offset local, Size size, double factor) {
    final perPx = _span / size.width;
    _cx += (local.dx - size.width / 2) * perPx;
    _cy += (local.dy - size.height / 2) * perPx;
    _span = (_span * factor).clamp(1e-13, 8.0);
    _render();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              SegmentedButton<Engine>(
                segments: const [
                  ButtonSegment(value: Engine.rust, label: Text('Rust')),
                  ButtonSegment(value: Engine.dart, label: Text('Dart')),
                ],
                selected: {_engine},
                onSelectionChanged: (s) {
                  setState(() => _engine = s.first);
                  _render();
                },
              ),
              const Spacer(),
              Text(
                _lastMs == null ? '—' : '${_lastMs!.toStringAsFixed(1)} ms',
                key: const Key('fractal-ms'),
                style: theme.textTheme.titleLarge,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Text('Iterations'),
              Expanded(
                child: Slider(
                  value: _maxIter.toDouble(),
                  min: 50,
                  max: 3000,
                  divisions: 59,
                  label: '$_maxIter',
                  onChanged: (v) {
                    setState(() => _maxIter = v.round());
                    _render();
                  },
                ),
              ),
              IconButton(
                tooltip: 'Reset view',
                icon: const Icon(Icons.restart_alt),
                onPressed: () {
                  _cx = -0.5;
                  _cy = 0;
                  _span = 3.2;
                  _render();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              // Render at device resolution, capped to keep Dart usable.
              final k = math.min(dpr, _maxSide / math.max(size.width, 1));
              final px = Size(
                (size.width * k).floorToDouble(),
                (size.height * k).floorToDouble(),
              );
              if (px != _pixelSize) {
                _pixelSize = px;
                WidgetsBinding.instance.addPostFrameCallback((_) => _render());
              }
              return GestureDetector(
                onTapUp: (d) => _zoomAt(d.localPosition, size, 0.4),
                onLongPressStart: (d) => _zoomAt(d.localPosition, size, 2.5),
                child: SizedBox.expand(
                  child: _image == null
                      ? const Center(child: CircularProgressIndicator())
                      : RawImage(image: _image, fit: BoxFit.fill),
                ),
              );
            },
          ),
        ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            'Tap to zoom in · long-press to zoom out · '
            'zoom ${(3.2 / _span).toStringAsExponential(1)}×',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
