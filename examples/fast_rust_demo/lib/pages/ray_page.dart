import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fast_rust/fast_rust.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../engine.dart';

/// Real-time path tracing of a scene of glass, metal and diffuse spheres.
/// Every frame adds 1–4 samples per pixel to a running average, so the
/// picture starts noisy and sharpens within a second or two. Drag to orbit
/// the camera (the average restarts); switch to Dart to compare.
class RayPage extends StatefulWidget {
  const RayPage({super.key});

  @override
  State<RayPage> createState() => _RayPageState();
}

class _RayPageState extends State<RayPage> with SingleTickerProviderStateMixin {
  static const size = 360, maxSamples = 2048;

  final _accum = Float64List(size * size * 3);
  final _rgba = Uint8List(size * size * 4);
  late final Ticker _ticker;

  Engine _engine = Engine.rust;
  RayCamera _camera = const RayCamera();
  late Float64List _cameraArray = _camera.toArray(size, size);
  bool _depthOfField = true;
  double _perFrame = 1;
  int _samples = 0;
  bool _finalShown = false; // converged and the final average is on screen

  ui.Image? _image;
  bool _decoding = false;

  final _frameTimes = <Duration>[];
  double _fps = 0, _traceMs = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _image?.dispose();
    super.dispose();
  }

  void _restart() {
    _cameraArray = _camera.toArray(size, size);
    _accum.fillRange(0, _accum.length, 0);
    _samples = 0;
    _finalShown = false;
  }

  void _setCamera(RayCamera camera) {
    _camera = camera;
    _restart();
  }

  void _onTick(Duration elapsed) {
    _frameTimes.add(elapsed);
    _frameTimes.removeWhere((t) => elapsed - t > const Duration(seconds: 1));
    _fps = _frameTimes.length.toDouble();
    if (_samples >= maxSamples) {
      // Converged: upload the final average once, then stay idle.
      if (!_finalShown && !_decoding) {
        _finalShown = true;
        _present().then((_) {
          if (mounted) setState(() {});
        });
      }
      return;
    }
    final n = _perFrame.round();
    final sw = Stopwatch()..start();
    switch (_engine) {
      case Engine.rust:
        FastRust.pathTrace(
          _accum,
          width: size,
          height: size,
          camera: _cameraArray,
          firstSample: _samples,
          samples: n,
        );
      case Engine.dart:
        DartReference.pathTrace(
          _accum,
          width: size,
          height: size,
          camera: _cameraArray,
          firstSample: _samples,
          samples: n,
        );
    }
    _traceMs = sw.elapsedMicroseconds / 1000;
    _samples += n;
    if (!_decoding) _present();
    setState(() {});
  }

  Future<void> _present() async {
    _decoding = true;
    switch (_engine) {
      case Engine.rust:
        FastRust.pathResolveRgba(
          _accum,
          _rgba,
          width: size,
          height: size,
          sampleCount: _samples,
        );
      case Engine.dart:
        DartReference.pathResolveRgba(
          _accum,
          _rgba,
          width: size,
          height: size,
          sampleCount: _samples,
        );
    }
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

  void _orbit(Offset delta, Size box) {
    _setCamera(
      _camera.copyWith(
        yaw: _camera.yaw - delta.dx / box.width * 3,
        pitch: (_camera.pitch + delta.dy / box.height * 1.5).clamp(0.02, 1.3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rays = size * size * _perFrame.round();
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
                key: const Key('ray-fps'),
                style: theme.textTheme.titleLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$_samples samples · ${_traceMs.toStringAsFixed(1)} ms/frame',
            key: const Key('ray-ms'),
            style: theme.textTheme.titleMedium,
            maxLines: 1,
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
                      key: const Key('ray-canvas'),
                      onPanUpdate: (d) => _orbit(d.delta, box),
                      onDoubleTap: () => _setCamera(
                        RayCamera(aperture: _depthOfField ? 0.08 : 0),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _image == null
                            ? const ColoredBox(color: Color(0xFFDDE6F5))
                            : RawImage(
                                image: _image,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.medium,
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
              const SizedBox(width: 112, child: Text('Samples/frame')),
              Expanded(
                child: Slider(
                  value: _perFrame,
                  min: 1,
                  max: 4,
                  divisions: 3,
                  label: '${_perFrame.round()}',
                  onChanged: (v) => setState(() => _perFrame = v),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilterChip(
                key: const Key('ray-dof'),
                avatar: const Icon(Icons.camera, size: 18),
                label: const Text('Depth of field'),
                selected: _depthOfField,
                onSelected: (v) => setState(() {
                  _depthOfField = v;
                  _setCamera(
                    RayCamera(
                      yaw: _camera.yaw,
                      pitch: _camera.pitch,
                      distance: _camera.distance,
                      aperture: v ? 0.08 : 0,
                    ),
                  );
                }),
              ),
              OutlinedButton.icon(
                onPressed: () => setState(_restart),
                icon: const Icon(Icons.refresh),
                label: const Text('Restart'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$size×$size · ${(rays / 1000).round()}k camera rays per frame, up '
            'to 6 bounces · drag to orbit, double-tap to reset',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
