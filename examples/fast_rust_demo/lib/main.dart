import 'package:flutter/material.dart';

import 'pages/benchmark_page.dart';
import 'pages/blur_page.dart';
import 'pages/fractal_page.dart';

void main() => runApp(const FastRustDemo());

class FastRustDemo extends StatelessWidget {
  const FastRustDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fast_rust demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepOrange,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  /// Pages are built on first visit so heavy demos don't run at startup
  /// (and don't compete with the benchmark for CPU), then kept alive.
  final _visited = <int>{0};

  static const _pages = [BenchmarkPage(), FractalPage(), BlurPage()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < _pages.length; i++)
              _visited.contains(i) ? _pages[i] : const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() {
          _index = i;
          _visited.add(i);
        }),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.speed), label: 'Benchmark'),
          NavigationDestination(icon: Icon(Icons.blur_on), label: 'Fractal'),
          NavigationDestination(icon: Icon(Icons.image), label: 'Live blur'),
        ],
      ),
    );
  }
}
