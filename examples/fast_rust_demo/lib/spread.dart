import 'dart:typed_data';

import 'package:fast_rust/fast_rust.dart';

import 'engine.dart';

/// One running "paint that flows" animation: the geodesic distances from
/// the tap are computed once, then each frame paints the next ring.
class Spread {
  Spread._(
    this._engine,
    this._source,
    this._target,
    this._dist,
    this.width,
    this.height,
    this.max,
    this.color,
    this.strength,
    this.tint,
  );

  /// Computes the distances for a tap at ([x], [y]) and records how long
  /// that pass took in [setupMs]. Nothing is painted until [advanceTo].
  static Spread start(
    Engine engine,
    Uint8List source,
    Uint8List target, {
    required int width,
    required int height,
    required int x,
    required int y,
    required int color,
    required int tolerance,
    int strength = 255,
    bool tint = false,
  }) {
    final dist = Uint32List(width * height);
    final sw = Stopwatch()..start();
    final max = switch (engine) {
      Engine.rust => FastRust.spreadDistancesRgba(
        source,
        dist,
        width: width,
        height: height,
        x: x,
        y: y,
        tolerance: tolerance,
      ),
      Engine.dart => DartReference.spreadDistancesRgba(
        source,
        dist,
        width: width,
        height: height,
        x: x,
        y: y,
        tolerance: tolerance,
      ),
    };
    final spread = Spread._(
      engine,
      source,
      target,
      dist,
      width,
      height,
      max,
      color,
      strength,
      tint,
    );
    spread.setupMs = sw.elapsedMicroseconds / 1000;
    return spread;
  }

  final Engine _engine;
  final Uint8List _source, _target;
  final Uint32List _dist;
  final int width, height, max, color, strength;
  final bool tint;

  double setupMs = 0;
  double paintMs = 0; // time of the last frame's paint call
  int painted = 0;
  int _radius = 0;

  bool get done => _radius > max;

  /// Paints every pixel closer than [radius] (distance units) that is not
  /// painted yet.
  void advanceTo(int radius) {
    if (done || radius <= _radius) return;
    final to = radius > max ? max + 1 : radius;
    final sw = Stopwatch()..start();
    final n = switch (_engine) {
      Engine.rust => FastRust.paintByDistanceRgba(
        _source,
        _target,
        _dist,
        width: width,
        height: height,
        from: _radius,
        to: to,
        color: color,
        strength: strength,
        tint: tint,
      ),
      Engine.dart => DartReference.paintByDistanceRgba(
        _source,
        _target,
        _dist,
        width: width,
        height: height,
        from: _radius,
        to: to,
        color: color,
        strength: strength,
        tint: tint,
      ),
    };
    paintMs = sw.elapsedMicroseconds / 1000;
    painted += n;
    _radius = to;
  }

  void finish() => advanceTo(max + 1);
}
