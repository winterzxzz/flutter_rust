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

  test('benchmark case runs on an isolate', () async {
    final index = benchCases.indexWhere((c) => c.name == 'Prime sieve');
    final r = await runBenchCase(index, runs: 3);
    expect(r.dartMs, greaterThan(0));
    expect(r.rustMs, greaterThan(0));
    expect(r.speedup.isFinite, isTrue);
  });
}
