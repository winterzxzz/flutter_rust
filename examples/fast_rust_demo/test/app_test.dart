import 'package:fast_rust/fast_rust.dart';
import 'package:fast_rust_demo/benchmarks.dart';
import 'package:fast_rust_demo/main.dart';
import 'package:fast_rust_demo/pages/blur_page.dart';
import 'package:fast_rust_demo/pages/fractal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  testWidgets('home shows the three demos', (tester) async {
    await tester.pumpWidget(const FastRustDemo());
    expect(find.text('Benchmark'), findsOneWidget);
    expect(find.text('Fractal'), findsOneWidget);
    expect(find.text('Live blur'), findsOneWidget);
    expect(find.text('Paint'), findsOneWidget);
    expect(find.text('Run all'), findsOneWidget);
    // Heavy demos are built lazily, not at startup.
    expect(find.byType(FractalPage), findsNothing);
    expect(find.byType(BlurPage), findsNothing);
  });

  testWidgets('fractal renders with Rust on a background isolate', (
    tester,
  ) async {
    await tester.pumpWidget(const FastRustDemo());
    await tester.tap(find.text('Fractal'));
    await tester.pump();
    await pumpUntil(tester, () => textOf(tester, 'fractal-ms') != '—');
    expect(textOf(tester, 'fractal-ms'), endsWith(' ms'));
    expect(find.byType(RawImage), findsWidgets);
  });

  testWidgets('live blur renders a frame', (tester) async {
    await tester.pumpWidget(const FastRustDemo());
    await tester.tap(find.text('Live blur'));
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
    await tester.tap(find.text('Paint'));
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

  test('benchmark case runs on an isolate', () async {
    final index = benchCases.indexWhere((c) => c.name == 'Prime sieve');
    final r = await runBenchCase(index, runs: 3);
    expect(r.dartMs, greaterThan(0));
    expect(r.rustMs, greaterThan(0));
    expect(r.speedup.isFinite, isTrue);
  });
}
