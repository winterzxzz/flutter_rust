import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Which implementation runs a kernel.
enum Engine { rust, dart }

/// Wraps raw RGBA8888 pixels into a [ui.Image] without re-encoding.
Future<ui.Image> imageFromRgba(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
