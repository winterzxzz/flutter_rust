// Renders real screenshots of the demo app for the README (headless, via
// golden files). Not part of the normal test suite; run explicitly:
//
//   flutter test tool/screenshots_test.dart --update-goldens
//
// Output: ../../docs/images/screenshot-*.png

import 'dart:io';

import 'package:fast_rust_demo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bottom-navigation tab, found by its icon (only the selected tab shows
/// its label).
Finder navTab(IconData icon) => find.descendant(
  of: find.byType(NavigationBar),
  matching: find.byIcon(icon),
);

/// Loads Roboto and Material Icons from the Flutter SDK cache so text and
/// icons render as real glyphs instead of test boxes.
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

Future<void> _settle(WidgetTester tester, bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  // Let image decoding finish and the spinner settle on a frame.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump(const Duration(milliseconds: 16));
}

/// Real time passes (isolates, decoding) while frames and animations advance.
Future<void> _wait(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  setUpAll(_loadFonts);

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const FastRustDemo());
  }

  testWidgets('fractal', (tester) async {
    await phone(tester);
    await tester.tap(navTab(Icons.blur_on));
    await tester.pump();
    await _settle(tester, () => _text(tester, 'fractal-ms') != '—');
    // Zoom into the spiral at (-0.7453, 0.1127): first tap off-centre, then
    // keep zooming at the new centre.
    final view = find.byType(RawImage);
    final centre = tester.getCenter(view);
    final perPx = 3.2 / tester.getSize(view).width;
    await tester.tapAt(centre + Offset(-0.2453 / perPx, 0.1127 / perPx));
    await _wait(tester, 1500);
    for (var i = 0; i < 5; i++) {
      await tester.tapAt(centre);
      await _wait(tester, 1500);
    }
    await _wait(tester, 800);
    await expectLater(
      find.byType(FastRustDemo),
      matchesGoldenFile('../../../docs/images/screenshot-fractal.png'),
    );
  });

  testWidgets('live blur', (tester) async {
    await phone(tester);
    await tester.tap(navTab(Icons.image));
    await tester.pump();
    await _settle(
      tester,
      () => !_text(tester, 'blur-ms').startsWith('Working'),
    );
    // The first call pays one-off costs (thread start-up, page faults);
    // move the slider a few times so the shown time is a warm frame.
    final slider = find.byType(Slider);
    for (var i = 0; i < 6; i++) {
      await tester.drag(slider, Offset(i.isEven ? 30 : -20, 0));
      await _wait(tester, 300);
    }
    await _wait(tester, 800);
    await expectLater(
      find.byType(FastRustDemo),
      matchesGoldenFile('../../../docs/images/screenshot-blur.png'),
    );
  });

  testWidgets('paint', (tester) async {
    await phone(tester);
    await tester.tap(navTab(Icons.format_color_fill));
    await tester.pump();
    await _settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    // Colour the page with a burst of auto fills, then stop.
    await tester.tap(find.text('Auto'));
    await _wait(tester, 1200);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    // A real tap so the caption shows a measured single fill.
    final canvas = tester.getRect(find.byKey(const Key('paint-canvas')));
    for (final f in [0.37, 0.52, 0.61, 0.44, 0.73]) {
      await tester.tapAt(
        canvas.topLeft + Offset(canvas.width * f, canvas.height * (1 - f)),
      );
      await tester.pump();
      if (_text(tester, 'paint-ms').startsWith('Filled')) break;
    }
    await _wait(tester, 800);
    await expectLater(
      find.byType(FastRustDemo),
      matchesGoldenFile('../../../docs/images/screenshot-paint.png'),
    );
  });

  testWidgets('photo', (tester) async {
    await phone(tester);
    await tester.tap(navTab(Icons.palette));
    await tester.pump();
    await _settle(
      tester,
      () => find.byKey(const Key('photo-canvas')).evaluate().isNotEmpty,
    );
    final box = tester.getRect(find.byKey(const Key('photo-canvas')));
    Offset at(double fx, double fy) =>
        box.topLeft + Offset(box.width * fx, box.height * fy);
    Future<void> pick(int color) async {
      final swatches = find.byType(AnimatedContainer);
      await tester.tap(swatches.at(color));
      await tester.pump();
    }

    // Pink hair: short strokes on the strands away from the face.
    await pick(0);
    for (final (fx, fy) in [
      (0.66, 0.48),
      (0.70, 0.60),
      (0.74, 0.72),
      (0.32, 0.55),
      (0.30, 0.68),
      (0.58, 0.36),
    ]) {
      await tester.dragFrom(at(fx, fy), Offset(0, box.height * 0.06));
      await tester.pump();
    }
    await _wait(tester, 300);
    // Purple grass, tapped in a few places.
    await pick(6);
    for (final p in [at(0.1, 0.85), at(0.85, 0.85), at(0.2, 0.95)]) {
      await tester.tapAt(p);
      await tester.pump();
    }
    await _wait(tester, 800);
    await expectLater(
      find.byType(FastRustDemo),
      matchesGoldenFile('../../../docs/images/screenshot-photo.png'),
    );
  });

  Future<Rect> openPhoto(WidgetTester tester, String mode) async {
    await tester.tap(navTab(Icons.palette));
    await tester.pump();
    await _settle(
      tester,
      () => find.byKey(const Key('photo-canvas')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('photo-spread'))); // instant fills
    await tester.pump();
    await tester.tap(find.text(mode));
    await tester.pump();
    await _settle(
      tester,
      () => !_text(tester, 'photo-ms').startsWith('Building'),
    );
    return tester.getRect(find.byKey(const Key('photo-canvas')));
  }

  testWidgets('photo line art', (tester) async {
    await phone(tester);
    final box = await openPhoto(tester, 'Line art');
    final swatches = find.byType(AnimatedContainer);
    final rng = [0.21, 0.37, 0.52, 0.66, 0.81, 0.29, 0.45, 0.73, 0.14, 0.59];
    var c = 0;
    for (var i = 0; i < rng.length; i++) {
      for (var j = 0; j < 4; j++) {
        await tester.tap(swatches.at(c++ % 8));
        await tester.pump();
        await tester.tapAt(
          box.topLeft +
              Offset(box.width * rng[i], box.height * rng[(i + j * 3) % 10]),
        );
        await tester.pump();
      }
    }
    await _wait(tester, 800);
    await expectLater(
      find.byType(FastRustDemo),
      matchesGoldenFile('../../../docs/images/screenshot-lineart.png'),
    );
  });

  testWidgets('photo splash', (tester) async {
    await phone(tester);
    final box = await openPhoto(tester, 'Splash');
    // Bring back the hair and the apples' tree only.
    for (final (fx, fy) in [
      (0.64, 0.42),
      (0.70, 0.55),
      (0.72, 0.66),
      (0.34, 0.50),
      (0.31, 0.62),
      (0.56, 0.33),
      (0.47, 0.31),
    ]) {
      await tester.tapAt(box.topLeft + Offset(box.width * fx, box.height * fy));
      await tester.pump();
    }
    await _wait(tester, 800);
    await expectLater(
      find.byType(FastRustDemo),
      matchesGoldenFile('../../../docs/images/screenshot-splash.png'),
    );
  });

  testWidgets('sand', (tester) async {
    await phone(tester);
    await tester.tap(navTab(Icons.grain));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sand-rain')));
    await tester.pump();
    for (var i = 0; i < 160; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _wait(tester, 500);
    await expectLater(
      find.byType(FastRustDemo),
      matchesGoldenFile('../../../docs/images/screenshot-sand.png'),
    );
  });
}
