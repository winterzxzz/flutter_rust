# fast_rust_demo

A Flutter app that shows off the performance of [`fast_rust`](../../packages/fast_rust):

- **Benchmark**: runs Dart and Rust side by side on a background isolate and
  shows the speedup.
- **Fractal**: explore the Mandelbrot set; tap to zoom, switch between the Rust
  and Dart engines.
- **Paint**: a pixel-art coloring book; tap or drag to flood-fill regions, with
  an Auto mode and an FPS counter.
- **Live blur**: blurs a 1280×800 image on the UI thread as you move the slider,
  measured against the 16.7 ms frame budget.

```sh
flutter pub get
flutter test
flutter run --profile     # or --release; debug builds run Dart in JIT mode
```

Requires Rust and the Rust targets for your device. See *Requirements* in the
[repository README](../../README.md#3-requirements).
