// Records real footage of the demo app for the README video (headless).
// Not part of the normal test suite; run explicitly:
//
//   flutter test tool/video_test.dart
//   tool/make_video.sh            # encodes the frames to MP4 and GIF
//
// Frames: build/video_frames/frame_00000.png ... at 30 fps of app time.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:fast_rust_demo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bottom-navigation tab, found by its icon (only the selected tab shows
/// its label).
Finder navTab(IconData icon) => find.descendant(
  of: find.byType(NavigationBar),
  matching: find.byIcon(icon),
);

const _frame = Duration(microseconds: 33333); // 30 fps
final _boundary = GlobalKey();
final _touch = ValueNotifier<Offset?>(null);
var _index = 0;
late Directory _out;

Future<void> _loadFonts() async {
  var dir = File(Platform.resolvedExecutable).parent;
  while (!Directory(
    '${dir.path}/bin/cache/artifacts/material_fonts',
  ).existsSync()) {
    if (dir.parent.path == dir.path) {
      throw StateError('Flutter SDK material_fonts not found');
    }
    dir = dir.parent;
  }
  final fonts = '${dir.path}/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String name) async =>
      ByteData.sublistView(await File('$fonts/$name').readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold']) {
    roboto.addFont(read('Roboto-$w.ttf'));
  }
  await roboto.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(read('MaterialIcons-Regular.otf'))).load();
}

/// The app plus a finger indicator, inside one repaint boundary.
class _Recorder extends StatelessWidget {
  const _Recorder();

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _boundary,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            const FastRustDemo(),
            ValueListenableBuilder<Offset?>(
              valueListenable: _touch,
              builder: (context, p, _) => p == null
                  ? const SizedBox.shrink()
                  : Positioned(
                      left: p.dx - 22,
                      top: p.dy - 22,
                      child: IgnorePointer(
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.35),
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: const [
                              BoxShadow(color: Colors.black38, blurRadius: 8),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Advances app time by one frame, lets real async work (image uploads)
/// finish, and saves the frame.
Future<void> _shoot(WidgetTester tester, {int frames = 1}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(_frame);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    });
    await tester.pump();
    await tester.runAsync(() async {
      final boundary =
          _boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final name = 'frame_${(_index++).toString().padLeft(5, '0')}.png';
      await File('${_out.path}/$name').writeAsBytes(png!.buffer.asUint8List());
    });
  }
}

double _seconds(double s) => s * 30;

Future<void> _hold(WidgetTester tester, double seconds) =>
    _shoot(tester, frames: _seconds(seconds).round());

/// A visible tap: the indicator appears, the tap lands, and it fades out.
Future<void> _tap(WidgetTester tester, Offset at, {double after = 0.3}) async {
  _touch.value = at;
  await _shoot(tester, frames: 4);
  await tester.tapAt(at);
  await _shoot(tester, frames: 3);
  _touch.value = null;
  await _hold(tester, after);
}

/// A visible drag in [steps] moves.
Future<void> _drag(WidgetTester tester, Offset from, Offset by) async {
  const steps = 18;
  _touch.value = from;
  await _shoot(tester, frames: 3);
  final gesture = await tester.startGesture(from);
  for (var i = 1; i <= steps; i++) {
    final p = from + by * (i / steps);
    _touch.value = p;
    await gesture.moveTo(p);
    await _shoot(tester);
  }
  await gesture.up();
  _touch.value = null;
  await _shoot(tester, frames: 6);
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    _out = Directory('build/video_frames');
    if (_out.existsSync()) _out.deleteSync(recursive: true);
    _out.createSync(recursive: true);
  });

  testWidgets('demo video', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const _Recorder());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );

    // Scene 1: photo recoloring with the spreading fill.
    await _tap(tester, tester.getCenter(navTab(Icons.palette)), after: 0.1);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await _hold(tester, 0.8);
    final photo = tester.getRect(find.byKey(const Key('photo-canvas')));
    Offset p(double fx, double fy) =>
        photo.topLeft + Offset(photo.width * fx, photo.height * fy);
    Future<void> swatch(int i) async {
      await _tap(
        tester,
        tester.getCenter(find.byType(AnimatedContainer).at(i)),
        after: 0.1,
      );
    }

    await swatch(0); // pink hair: brush strokes that flow along the strands
    await _drag(
      tester,
      p(0.64, 0.42),
      Offset(photo.width * 0.1, photo.height * 0.3),
    );
    await _drag(
      tester,
      p(0.34, 0.46),
      Offset(-photo.width * 0.02, photo.height * 0.28),
    );
    await _drag(tester, p(0.56, 0.33), Offset(photo.width * 0.12, 0));
    await _hold(tester, 0.8);
    await swatch(6); // purple grass
    await _tap(tester, p(0.12, 0.88), after: 1.0);
    await _tap(tester, p(0.85, 0.9), after: 1.0);
    await swatch(5); // blue road
    await _tap(tester, p(0.9, 0.67), after: 1.2);
    // Hold to compare with the original.
    final hold = tester.getCenter(find.text('Hold: original'));
    _touch.value = hold;
    final g = await tester.startGesture(hold);
    await _hold(tester, 1.0);
    await g.up();
    _touch.value = null;
    await _hold(tester, 1.0);

    // Scene 2: color splash, the photo turns gray and taps bring color back.
    await _tap(tester, tester.getCenter(find.text('Splash')), after: 0.6);
    for (final (fx, fy) in [(0.64, 0.42), (0.70, 0.58), (0.34, 0.50)]) {
      await _tap(tester, p(fx, fy), after: 0.7);
    }
    await _drag(
      tester,
      p(0.56, 0.33),
      Offset(photo.width * 0.16, photo.height * 0.36),
    );
    await _hold(tester, 0.8);

    // Scene 3: the photo becomes a coloring page; fills flow region by
    // region, then Reveal paints it in the photo's own colors.
    await _tap(tester, tester.getCenter(find.text('Line art')), after: 0.1);
    // Wait (real time) for the background isolate to build the page.
    String caption() =>
        tester.widget<Text>(find.byKey(const Key('photo-ms'))).data!;
    while (caption().startsWith('Building')) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await _hold(tester, 0.7);
    var c = 0;
    for (final (fx, fy) in [
      (0.20, 0.55),
      (0.55, 0.62),
      (0.80, 0.20),
      (0.35, 0.15),
      (0.75, 0.80),
      (0.15, 0.90),
    ]) {
      await swatch(c++ % 8);
      await _tap(tester, p(fx, fy), after: 0.7);
    }
    await _hold(tester, 0.5);
    await _tap(
      tester,
      tester.getCenter(find.byKey(const Key('photo-reveal'))),
      after: 1.5,
    );

    // Scene 4: falling sand, a million cells stepped by Rust every frame.
    await _tap(tester, tester.getCenter(navTab(Icons.grain)), after: 0.6);
    final sand = tester.getRect(find.byKey(const Key('sand-canvas')));
    Offset r(double fx, double fy) =>
        sand.topLeft + Offset(sand.width * fx, sand.height * fy);
    await _drag(tester, r(0.15, 0.08), Offset(sand.width * 0.3, 0));
    await _tap(tester, tester.getCenter(find.text('Water')), after: 0.1);
    await _drag(tester, r(0.9, 0.08), Offset(-sand.width * 0.3, 0));
    await _tap(
      tester,
      tester.getCenter(find.byKey(const Key('sand-rain'))),
      after: 3.0,
    );
    await _tap(tester, tester.getCenter(find.text('Dart')), after: 1.5);
    await _tap(tester, tester.getCenter(find.text('Rust')), after: 1.0);

    // Scene 5: pixel-art coloring page, spreading then instant fills.
    await _tap(
      tester,
      tester.getCenter(navTab(Icons.format_color_fill)),
      after: 0.1,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await _hold(tester, 0.5);
    await _tap(tester, tester.getCenter(find.text('Spread')), after: 0.2);
    final page = tester.getRect(find.byKey(const Key('paint-canvas')));
    Offset q(double fx, double fy) =>
        page.topLeft + Offset(page.width * fx, page.height * fy);
    var color = 0;
    for (final (fx, fy) in [(0.3, 0.3), (0.7, 0.35), (0.5, 0.7), (0.2, 0.8)]) {
      await swatch(color++ % 8);
      await _tap(tester, q(fx, fy), after: 0.8);
    }
    await _tap(tester, tester.getCenter(find.text('Spread')), after: 0.1);
    await swatch(3);
    await _drag(
      tester,
      q(0.1, 0.12),
      Offset(page.width * 0.8, page.height * 0.1),
    );
    await _tap(tester, tester.getCenter(find.text('Auto')), after: 2.0);
    await _tap(tester, tester.getCenter(find.text('Stop')), after: 0.8);

    // Scene 6: fractal zoom rendered by multi-threaded Rust.
    await _tap(tester, tester.getCenter(navTab(Icons.blur_on)), after: 0.1);
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    final view = find.byType(RawImage);
    final centre = tester.getCenter(view);
    final perPx = 3.2 / tester.getSize(view).width;
    await _tap(
      tester,
      centre + Offset(-0.2453 / perPx, 0.1127 / perPx),
      after: 0,
    );
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      await _hold(tester, 0.4);
      await _tap(tester, centre, after: 0);
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    await _hold(tester, 1.5);
    debugPrint('Saved $_index frames to ${_out.path}');
  });
}
