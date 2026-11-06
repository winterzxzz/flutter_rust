import 'package:fast_rust/fast_rust.dart';
import 'package:fast_rust_demo/benchmarks.dart';
import 'package:fast_rust_demo/main.dart';
import 'package:fast_rust_demo/pages/blur_page.dart';
import 'package:fast_rust_demo/pages/fractal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bottom-navigation tab, found by its icon (only the selected tab shows
/// its label).
Finder navTab(IconData icon) => find.descendant(
  of: find.byType(NavigationBar),
  matching: find.byIcon(icon),
);

/// Pumps frames while letting real async work (isolates, image decoding)
/// progress, until [done] holds or the timeout expires.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

String textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  test('Rust library is loaded in flutter test via native assets', () {
    expect(FastRust.abiVersion, 1);
    expect(FastRust.countPrimes(100), 25);
  });

  testWidgets('home shows the six tabs', (tester) async {
    await tester.pumpWidget(const FastRustDemo());
    // Only the selected tab shows its label; the rest are icons.
    expect(find.text('Benchmark'), findsOneWidget);
    expect(find.byIcon(Icons.blur_on), findsOneWidget); // Fractal
    expect(find.byIcon(Icons.image), findsOneWidget); // Live blur
    expect(find.byIcon(Icons.format_color_fill), findsOneWidget); // Paint
    expect(find.byIcon(Icons.palette), findsOneWidget); // Photo
    expect(find.byIcon(Icons.grain), findsOneWidget); // Sand
    expect(find.text('Run all'), findsOneWidget);
    // Heavy demos are built lazily, not at startup.
    expect(find.byType(FractalPage), findsNothing);
    expect(find.byType(BlurPage), findsNothing);
  });

  testWidgets('fractal renders with Rust on a background isolate', (
    tester,
  ) async {
    await tester.pumpWidget(const FastRustDemo());
    await tester.tap(navTab(Icons.blur_on));
    await tester.pump();
    await pumpUntil(tester, () => textOf(tester, 'fractal-ms') != '—');
    expect(textOf(tester, 'fractal-ms'), endsWith(' ms'));
    expect(find.byType(RawImage), findsWidgets);
  });

  testWidgets('live blur renders a frame', (tester) async {
    await tester.pumpWidget(const FastRustDemo());
    await tester.tap(navTab(Icons.image));
    await tester.pump();
    await pumpUntil(
      tester,
      () => !textOf(tester, 'blur-ms').startsWith('Working'),
    );
    expect(textOf(tester, 'blur-ms'), contains('ms per frame'));
  });

  testWidgets('paint page fills regions by tap and in auto mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const FastRustDemo());
    await tester.tap(navTab(Icons.format_color_fill));
    await tester.pump();
    await pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

    // A vertical drag across the picture paints (it must not scroll).
    final canvas = find.byKey(const Key('paint-canvas'));
    final box = tester.getRect(canvas);
    await tester.dragFrom(
      box.topCenter + Offset(box.width * 0.13, box.height * 0.1),
      Offset(0, box.height * 0.8),
    );
    await tester.pump();
    expect(textOf(tester, 'paint-ms'), matches(RegExp(r'^Filled \d+ px in')));
    expect(tester.getRect(canvas), box, reason: 'page did not scroll');

    // Spread mode: a tap starts a fill that keeps growing frame by frame.
    await tester.tap(find.byKey(const Key('paint-spread')));
    await tester.pump();
    await tester.tapAt(box.center + Offset(box.width * 0.2, box.height * 0.2));
    await tester.pump(const Duration(milliseconds: 16));
    expect(textOf(tester, 'paint-ms'), startsWith('Spread '));
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.tap(find.byKey(const Key('paint-spread')));
    await tester.pump();

    await tester.tap(find.text('Auto'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(textOf(tester, 'paint-fps'), endsWith('FPS'));
    expect(textOf(tester, 'paint-ms'), contains('regions/frame'));
    await tester.tap(find.text('Stop'));
    await tester.pump();
  });

  testWidgets('photo page recolors a region of the real photo, with undo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const FastRustDemo());
    await tester.tap(navTab(Icons.palette));
    await tester.pump();
    await pumpUntil(
      tester,
      () => find.byKey(const Key('photo-canvas')).evaluate().isNotEmpty,
    );

    // Spread mode (default): the colour flows out over several frames.
    // Max tolerance, so the region is large and takes many frames.
    await tester.drag(find.byType(Slider).first, const Offset(1000, 0));
    await tester.pump();
    final canvas = find.byKey(const Key('photo-canvas'));
    final box = tester.getRect(canvas);
    await tester.tapAt(
      box.topLeft + Offset(box.width * 0.05, box.height * 0.4),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final first = textOf(tester, 'photo-ms');
    expect(first, matches(RegExp(r'^Spread \d+ px · distances')));
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final last = textOf(tester, 'photo-ms');
    int px(String s) => int.parse(RegExp(r'(\d+) px').firstMatch(s)!.group(1)!);
    expect(px(last), greaterThan(px(first)), reason: 'the fill spread');

    // Instant mode: tap and drag recolor right away.
    await tester.tap(find.byKey(const Key('photo-spread')));
    await tester.pump();
    await tester.dragFrom(
      box.topLeft + Offset(box.width * 0.6, box.height * 0.35),
      Offset(0, box.height * 0.3),
    );
    await tester.pump();
    expect(
      textOf(tester, 'photo-ms'),
      matches(RegExp(r'^Recolored [1-9]\d* px in')),
    );
    expect(tester.getRect(canvas), box, reason: 'page did not scroll');

    // Two strokes, two undo steps.
    final undo = find.byTooltip('Undo');
    await tester.tap(undo);
    await tester.pump();
    await tester.tap(undo);
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.undo),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('photo page: splash and line-art modes', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const FastRustDemo());
    await tester.tap(find.byIcon(Icons.palette));
    await tester.pump();
    await pumpUntil(
      tester,
      () => find.byKey(const Key('photo-canvas')).evaluate().isNotEmpty,
    );
    final box = tester.getRect(find.byKey(const Key('photo-canvas')));
    // Instant mode keeps the test short.
    await tester.tap(find.byKey(const Key('photo-spread')));
    await tester.pump();

    await tester.tap(find.text('Splash'));
    await tester.pump();
    expect(textOf(tester, 'photo-ms'), 'Tap to bring the color back');
    await tester.tapAt(
      box.topLeft + Offset(box.width * 0.12, box.height * 0.88),
    );
    await tester.pump();
    expect(
      textOf(tester, 'photo-ms'),
      matches(RegExp(r'^Recolored [1-9]\d* px in')),
    );

    await tester.tap(find.text('Line art'));
    await tester.pump();
    // The page is built on a background isolate; the UI keeps running.
    expect(textOf(tester, 'photo-ms'), 'Building the coloring page…');
    await pumpUntil(
      tester,
      () => textOf(tester, 'photo-ms').startsWith('Page made by rust in '),
    );
    // Tap until a region (not an outline) is hit.
    for (final f in [0.3, 0.5, 0.7, 0.2, 0.8]) {
      await tester.tapAt(box.topLeft + Offset(box.width * f, box.height * f));
      await tester.pump();
      if (textOf(tester, 'photo-ms').startsWith('Recolored')) break;
    }
    expect(textOf(tester, 'photo-ms'), startsWith('Recolored'));
    await tester.tap(find.byKey(const Key('photo-reveal')));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.undo),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('sand page simulates and pours on drag', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const FastRustDemo());
    await tester.tap(navTab(Icons.grain));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(textOf(tester, 'sand-fps'), endsWith('FPS'));
    expect(textOf(tester, 'sand-ms'), matches(RegExp(r'^\d steps [\d.]+ ms')));
    expect(textOf(tester, 'sand-ms'), isNot(contains(' 0 moving')));
    final canvas = find.byKey(const Key('sand-canvas'));
    final rect = tester.getRect(canvas);
    final g = await tester.startGesture(rect.center);
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    expect(tester.getRect(canvas), rect, reason: 'page did not scroll');
    await tester.tap(find.text('Dart'));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(textOf(tester, 'sand-ms'), matches(RegExp(r'^\d steps [\d.]+ ms')));
  });

  test('benchmark case runs on an isolate', () async {
    final index = benchCases.indexWhere((c) => c.name == 'Prime sieve');
    final r = await runBenchCase(index, runs: 3);
    expect(r.dartMs, greaterThan(0));
    expect(r.rustMs, greaterThan(0));
    expect(r.speedup.isFinite, isTrue);
  });
}
