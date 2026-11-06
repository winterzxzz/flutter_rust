import 'package:fast_rust/fast_rust.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../benchmarks.dart';

/// Runs every [benchCases] entry (Dart vs Rust) on a background isolate and
/// shows median timings side by side.
class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  final _results = <int, BenchResult>{};
  int? _running;

  Future<void> _runAll() async {
    setState(_results.clear);
    for (var i = 0; i < benchCases.length; i++) {
      setState(() => _running = i);
      final result = await runBenchCase(i);
      if (!mounted) return;
      setState(() => _results[i] = result);
    }
    setState(() => _running = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Dart vs Rust', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Same input; same algorithm except where noted. Rust uses '
          '${FastRust.threadCount} threads for blur, grayscale and '
          'Mandelbrot (Dart: 1 thread). Runs off the UI isolate.',
          style: theme.textTheme.bodyMedium,
        ),
        if (kDebugMode)
          Card(
            color: theme.colorScheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Debug build: Dart runs in JIT mode. Use --profile or '
                '--release for representative numbers.',
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _running == null ? _runAll : null,
          icon: const Icon(Icons.play_arrow),
          label: Text(_running == null ? 'Run all' : 'Running…'),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < benchCases.length; i++)
          _BenchTile(
            benchCase: benchCases[i],
            result: _results[i],
            running: _running == i,
          ),
      ],
    );
  }
}

class _BenchTile extends StatelessWidget {
  final BenchCase benchCase;
  final BenchResult? result;
  final bool running;

  const _BenchTile({
    required this.benchCase,
    required this.result,
    required this.running,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    benchCase.name,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (running)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (r != null)
                  Text(
                    '${r.speedup.toStringAsFixed(1)}× faster',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            Text(benchCase.detail, style: theme.textTheme.bodySmall),
            if (r != null) ...[
              const SizedBox(height: 8),
              _Bar(
                label: 'Dart',
                ms: r.dartMs,
                max: r.dartMs > r.rustMs ? r.dartMs : r.rustMs,
                color: theme.colorScheme.outline,
              ),
              _Bar(
                label: 'Rust',
                ms: r.rustMs,
                max: r.dartMs > r.rustMs ? r.dartMs : r.rustMs,
                color: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  final String label;
  final double ms;
  final double max;
  final Color color;

  const _Bar({
    required this.label,
    required this.ms,
    required this.max,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 40, child: Text(label)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: max == 0 ? 0 : ms / max,
                minHeight: 14,
                color: color,
                backgroundColor: color.withValues(alpha: 0.12),
              ),
            ),
          ),
          SizedBox(
            width: 84,
            child: Text(
              '${ms.toStringAsFixed(2)} ms',
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
