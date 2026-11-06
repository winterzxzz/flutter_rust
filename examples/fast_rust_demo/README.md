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
- **Photo**: three ways to paint on a real photo:
  - *Recolor* tints a region and keeps its texture.
  - *Splash* turns the photo gray, and taps bring the color back.
  - *Line art* turns the photo into a coloring page that you fill. *Reveal*
    shows the photo's own colors.

  The *Spread* switch makes the color flow out from your finger.
- **Ray**: real-time path tracing of glass, metal and diffuse spheres. The
  image sharpens as samples accumulate; drag to orbit.
- **Sand**: a falling-sand simulation of a million cells. Pour sand or water,
  draw walls, or turn on rain, and watch the FPS when you switch to Dart.

The demo video and screenshots in the repository README are recorded headless:

```sh
flutter test tool/screenshots_test.dart --update-goldens   # docs/images/screenshot-*.png
flutter test tool/video_test.dart && tool/make_video.sh    # docs/video/demo.{mp4,gif}, needs ffmpeg
```

```sh
flutter pub get
flutter test
flutter run --profile     # or --release; debug builds run Dart in JIT mode
```

Requires Rust and the Rust targets for your device. See *Requirements* in the
[repository README](../../README.md#3-requirements).
