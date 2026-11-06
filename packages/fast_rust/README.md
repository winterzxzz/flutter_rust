# fast_rust

High-performance kernels written in Rust for Dart and Flutter, loaded through
*native assets* (a build hook runs `cargo` for you) and called with zero-copy FFI.

```dart
import 'package:fast_rust/fast_rust.dart';

final digest = FastRust.sha256(bytes);
FastRust.boxBlurRgba(pixels, width: w, height: h, radius: 8);
final img = await FastRust.mandelbrotRgbaAsync(width: 800, height: 600, scale: 3 / 800);
FastRust.floodFillRgba(page, width: 1024, height: 1024, x: 10, y: 20, color: 0x2A9D8FFF);
```

Requires Rust ≥ 1.88 and the Rust targets for your platforms (`rustup target add …`).

Full documentation lives in the [repository README](../../README.md): the API,
the leaf/non-leaf rule, the architecture, benchmarks, and how to add new
functions.

```sh
dart test                              # correctness tests
(cd rust && cargo test --release)      # Rust tests
dart run benchmark/benchmark.dart      # benchmarks
```
