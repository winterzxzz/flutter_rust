import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fast_rust/fast_rust.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../engine.dart';

/// Falling-sand playground on a 1024×1024 grid (about a million cells).
/// Drag to pour sand or water, draw walls or erase. Every frame runs one
/// [FastRust.sandStep] and one [FastRust.sandRenderRgba] (or the Dart
/// versions), so the FPS counter shows the difference directly.
class SandPage extends StatefulWidget {
  const SandPage({super.key});

  @override
  State<SandPage> createState() => _SandPageState();
}

class _SandPageState extends State<SandPage>
    with SingleTickerProviderStateMixin {
  static const size = 1024;
  static const _materials = [
    (SandMaterial.sand, 'Sand', Icons.grain, Color(0xFFE0B860)),
    (SandMaterial.water, 'Water', Icons.water_drop, Color(0xFF2E7DF0)),
    (SandMaterial.wall, 'Wall', Icons.square, Color(0xFF6A6E80)),
    (SandMaterial.empty, 'Erase', Icons.cleaning_services, Color(0xFF9E9E9E)),
  ];

  final _cells = Uint8List(size * size);
  final _rgba = Uint8List(size * size * 4);
  final _rng = Random(11);
  late final Ticker _ticker;

  Engine _engine = Engine.rust;
  int _material = SandMaterial.sand;
  double _brush = 14;
  bool _rain = false;
  double _speed = 3; // simulation steps per frame
  int _frame = 0;

  Offset? _finger; // grid coordinates while touching
  ui.Image? _image;
  bool _decoding = false;

  final _frameTimes = <Duration>[];
  double _fps = 0, _stepMs = 0, _renderMs = 0;
  int _moved = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _scene();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _image?.dispose();
    super.dispose();
  }

  /// Ramps, a cup and a sand pile to play with.
  void _scene() {
    _cells.fillRange(0, _cells.length, SandMaterial.empty);
    void wall(int x0, int y0, int x1, int y1, int thick) {
      final steps = max((x1 - x0).abs(), (y1 - y0).abs());
      for (var s = 0; s <= steps; s++) {
        final x = x0 + (x1 - x0) * s ~/ max(steps, 1);
        final y = y0 + (y1 - y0) * s ~/ max(steps, 1);
        _disc(x, y, thick, SandMaterial.wall, overwrite: true);
      }
    }

    wall(120, 300, 520, 420, 6);
    wall(900, 520, 480, 640, 6);
    wall(300, 820, 300, 960, 6);
    wall(300, 960, 720, 960, 6);
    wall(720, 820, 720, 960, 6);
    for (var y = 40; y < 280; y++) {
      for (var x = 160; x < 460; x++) {
        if (_rng.nextInt(2) == 0) _cells[y * size + x] = SandMaterial.sand;
      }
    }
    for (var y = 60; y < 300; y++) {
      for (var x = 600; x < 900; x++) {
        if (_rng.nextInt(2) == 0) _cells[y * size + x] = SandMaterial.water;
      }
    }
  }

  void _disc(int cx, int cy, int r, int m, {bool overwrite = false}) {
    for (var dy = -r; dy <= r; dy++) {
      final y = cy + dy;
      if (y < 0 || y >= size) continue;
      for (var dx = -r; dx <= r; dx++) {
        final x = cx + dx;
        if (x < 0 || x >= size || dx * dx + dy * dy > r * r) continue;
        final i = y * size + x;
        if (overwrite) {
          _cells[i] = m;
        } else if (_cells[i] == SandMaterial.empty && _rng.nextInt(3) == 0) {
          _cells[i] = m; // sprinkle, so poured grains look loose
        }
      }
    }
  }

  void _pour() {
    final f = _finger;
    if (f != null) {
      final solid =
          _material == SandMaterial.wall || _material == SandMaterial.empty;
      _disc(
        f.dx.round(),
        f.dy.round(),
        _brush.round(),
        _material,
        overwrite: solid,
      );
    }
    if (_rain) {
      // Two streams: sand on the left half, water on the right.
      for (var k = 0; k < 80; k++) {
        final sand = k.isEven;
        final x = (sand ? 0 : size ~/ 2) + _rng.nextInt(size ~/ 2);
        if (_cells[x] == SandMaterial.empty) {
          _cells[x] = sand ? SandMaterial.sand : SandMaterial.water;
        }
      }
    }
  }

  void _onTick(Duration elapsed) {
    final sw = Stopwatch()..start();
    // Several steps per frame: grains fall that many cells per frame.
    for (var s = 0; s < _speed.round(); s++) {
      _pour();
      _moved = switch (_engine) {
        Engine.rust => FastRust.sandStep(
          _cells,
          width: size,
          height: size,
          frame: _frame,
        ),
        Engine.dart => DartReference.sandStep(
          _cells,
          width: size,
          height: size,
          frame: _frame,
        ),
      };
      _frame++;
    }
    _stepMs = sw.elapsedMicroseconds / 1000;
    _frameTimes.add(elapsed);
    _frameTimes.removeWhere((t) => elapsed - t > const Duration(seconds: 1));
    _fps = _frameTimes.length.toDouble();
    if (!_decoding) _present();
    setState(() {});
  }

  Future<void> _present() async {
    _decoding = true;
    final sw = Stopwatch()..start();
    switch (_engine) {
      case Engine.rust:
        FastRust.sandRenderRgba(_cells, _rgba, width: size, height: size);
      case Engine.dart:
        DartReference.sandRenderRgba(_cells, _rgba, width: size, height: size);
    }
    _renderMs = sw.elapsedMicroseconds / 1000;
    try {
      final image = await imageFromRgba(_rgba, size, size);
      if (!mounted) {
        image.dispose();
        return;
      }
      _image?.dispose();
      _image = image;
    } finally {
      _decoding = false;
    }
  }

  Offset _toGrid(Offset local, Size box) =>
      Offset(local.dx / box.width * size, local.dy / box.height * size);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                '${_fps.toStringAsFixed(0)} FPS',
                key: const Key('sand-fps'),
                style: theme.textTheme.titleLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${_speed.round()} steps ${_stepMs.toStringAsFixed(2)} ms · render '
            '${_renderMs.toStringAsFixed(2)} ms · $_moved moving',
            key: const Key('sand-ms'),
            style: theme.textTheme.titleMedium,
            // One line: a caption that wraps as numbers grow would shift
            // the canvas under the finger.
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (m, label, icon, color) in _materials)
                ChoiceChip(
                  avatar: Icon(icon, size: 18, color: color),
                  label: Text(label),
                  selected: _material == m,
                  onSelected: (_) => setState(() => _material = m),
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
                    final box = constraints.biggest;
                    return GestureDetector(
                      key: const Key('sand-canvas'),
                      onPanDown: (d) => _finger = _toGrid(d.localPosition, box),
                      onPanUpdate: (d) =>
                          _finger = _toGrid(d.localPosition, box),
                      onPanEnd: (_) => _finger = null,
                      onPanCancel: () => _finger = null,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _image == null
                            ? const ColoredBox(color: Color(0xFF101420))
                            : RawImage(
                                image: _image,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.none,
                              ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 56, child: Text('Brush')),
              Expanded(
                child: Slider(
                  value: _brush,
                  min: 2,
                  max: 40,
                  onChanged: (v) => setState(() => _brush = v),
                ),
              ),
              const SizedBox(width: 56, child: Text('Speed')),
              Expanded(
                child: Slider(
                  value: _speed,
                  min: 1,
                  max: 6,
                  divisions: 5,
                  label: '${_speed.round()} steps/frame',
                  onChanged: (v) => setState(() => _speed = v),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilterChip(
                key: const Key('sand-rain'),
                avatar: const Icon(Icons.thunderstorm, size: 18),
                label: const Text('Rain'),
                selected: _rain,
                onSelected: (v) => setState(() => _rain = v),
              ),
              OutlinedButton.icon(
                onPressed: () => setState(_scene),
                icon: const Icon(Icons.landscape),
                label: const Text('Scene'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    setState(() => _cells.fillRange(0, _cells.length, 0)),
                icon: const Icon(Icons.layers_clear),
                label: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$size×$size cells (1M) · steps and render run on the UI thread',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
