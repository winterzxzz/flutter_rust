import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fast_rust/fast_rust.dart';
import 'package:flutter/material.dart';

import '../engine.dart';

/// Live box blur driven by a slider, executed synchronously on the UI
/// thread (a short zero-copy leaf call). A frame has a ~16 ms budget; the
/// measured time per frame is shown so you can compare engines on your
/// device (watch the spinner for stutter).
class BlurPage extends StatefulWidget {
  const BlurPage({super.key});

  @override
  State<BlurPage> createState() => _BlurPageState();
}

class _BlurPageState extends State<BlurPage> {
  static const _w = 1280, _h = 800;

  late final Uint8List _source = FastRust.mandelbrotRgba(
    width: _w,
    height: _h,
    centerX: -0.7453,
    centerY: 0.1127,
    scale: 0.0065 / _w,
    maxIterations: 600,
  );
  final Uint8List _work = Uint8List(_w * _h * 4);

  Engine _engine = Engine.rust;
  double _radius = 8;
  bool _grayscale = false;
  ui.Image? _image;
  double? _lastMs;
  bool _decoding = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _apply();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    if (_decoding) {
      _dirty = true;
      return;
    }
    _decoding = true;
    try {
      final radius = _radius.round();
      final sw = Stopwatch()..start();
      _work.setAll(0, _source);
      switch (_engine) {
        case Engine.rust:
          FastRust.boxBlurRgba(_work, width: _w, height: _h, radius: radius);
          if (_grayscale) FastRust.grayscaleRgba(_work);
        case Engine.dart:
          DartReference.boxBlurRgba(
            _work,
            width: _w,
            height: _h,
            radius: radius,
          );
          if (_grayscale) DartReference.grayscaleRgba(_work);
      }
      final ms = sw.elapsedMicroseconds / 1000;
      // decodeImageFromPixels copies the buffer, so _work can be reused.
      final image = await imageFromRgba(_work, _w, _h);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _lastMs = ms;
      });
    } finally {
      _decoding = false;
    }
    if (_dirty && mounted) {
      _dirty = false;
      _apply();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ms = _lastMs;
    final overBudget = ms != null && ms > 16.7;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            SegmentedButton<Engine>(
              segments: const [
                ButtonSegment(value: Engine.rust, label: Text('Rust')),
                ButtonSegment(value: Engine.dart, label: Text('Dart')),
              ],
              selected: {_engine},
              onSelectionChanged: (s) {
                setState(() => _engine = s.first);
                _apply();
              },
            ),
            const Spacer(),
            // Keeps animating only while the UI thread is free.
            const SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          ms == null
              ? 'Working…'
              : '${ms.toStringAsFixed(1)} ms per frame on the UI thread '
                    '(${overBudget ? 'over' : 'within'} the 16.7 ms budget)',
          key: const Key('blur-ms'),
          style: theme.textTheme.titleMedium?.copyWith(
            color: overBudget ? theme.colorScheme.error : null,
          ),
        ),
        Row(
          children: [
            Text('Radius ${_radius.round()}'),
            Expanded(
              child: Slider(
                value: _radius,
                min: 0,
                max: 40,
                onChanged: (v) {
                  setState(() => _radius = v);
                  _apply();
                },
              ),
            ),
          ],
        ),
        SwitchListTile(
          title: const Text('Grayscale'),
          value: _grayscale,
          onChanged: (v) {
            setState(() => _grayscale = v);
            _apply();
          },
        ),
        AspectRatio(
          aspectRatio: _w / _h,
          child: _image == null
              ? const Center(child: CircularProgressIndicator())
              : RawImage(image: _image, fit: BoxFit.contain),
        ),
        const SizedBox(height: 8),
        Text(
          '$_w×$_h RGBA, separable box blur. The source image is itself '
          'rendered by Rust.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
