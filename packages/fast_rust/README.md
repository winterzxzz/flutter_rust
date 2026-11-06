# fast_rust: Rust-speed image processing for Flutter and Dart

[![pub package](https://img.shields.io/pub/v/fast_rust.svg)](https://pub.dev/packages/fast_rust)
[![platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Linux%20%7C%20Windows-blue.svg)](https://pub.dev/packages/fast_rust)
[![license: MIT](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/winterzxzz/flutter_rust/blob/main/LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/winterzxzz/flutter_rust?style=social)](https://github.com/winterzxzz/flutter_rust)

![fast_rust: a Flutter + Rust FFI library that speeds up Flutter apps](https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/images/banner.png)

**fast_rust** moves CPU-heavy pixel and data work from Dart into Rust and
calls it through `dart:ffi` `@Native` functions. Rust reads and writes your
`Uint8List` in place, so nothing is copied or serialized. A build hook
(*native assets*) runs `cargo` for you on `flutter run`, `flutter build` and
`flutter test`. There is no codegen and no Gradle, CMake or Podspec to edit.

It is built for apps that edit pixels: **recolor regions of a real photo**
while keeping its texture, **turn a photo into a coloring page**, do a
**color splash**, **flood-fill** a coloring book, animate a fill that
**spreads out from the finger**, and **blur** images in real time. It also renders
**real-time 3D path tracing** on every core, runs a **falling-sand
simulation** of a million cells, and covers SHA-256, sorting and number
crunching. Every Rust kernel has a pure-Dart
twin (`DartReference`), and the tests check that both give identical output
(sorting differs only in where NaN goes).

- [Demo](#demo)
- [Features](#features)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Recolor a photo](#recolor-a-photo)
- [Spreading fill](#spreading-fill-paint-that-flows)
- [Photo to coloring page](#photo-to-coloring-page)
- [Color splash](#color-splash)
- [Falling sand](#falling-sand)
- [Path tracing](#path-tracing)
- [Coloring book flood fill](#coloring-book-flood-fill)
- [Other kernels](#other-kernels)
- [Sync or async](#sync-or-async)
- [Benchmarks](#benchmarks)
- [FAQ](#faq)
- [Limitations](#limitations)

## Demo

<p align="center">
  <img src="https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/video/demo.gif" width="300" alt="fast_rust demo: recoloring a photo with a spreading fill, color splash, turning the photo into a coloring page, falling sand, real-time path tracing, a pixel-art coloring page and a Rust-rendered fractal">
</p>

Real footage of the [demo app](https://github.com/winterzxzz/flutter_rust/tree/main/examples/fast_rust_demo),
recorded headless with `flutter test`. Full-quality video:
[demo.mp4](https://github.com/winterzxzz/flutter_rust/raw/main/docs/video/demo.mp4).

| Path tracing | Photo to coloring page | Color splash | Falling sand |
| :---: | :---: | :---: | :---: |
| <img src="https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/images/screenshot-ray.png" width="200" alt="Real-time path tracing of glass, metal and diffuse spheres in Flutter, rendered by multi-threaded Rust"> | <img src="https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/images/screenshot-lineart.png" width="200" alt="A photo turned into a coloring page by Rust in Flutter, partly filled"> | <img src="https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/images/screenshot-splash.png" width="200" alt="Color splash in Flutter: the photo is gray except the hair, restored by a Rust region selection"> | <img src="https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/images/screenshot-sand.png" width="200" alt="Falling-sand simulation of a million cells stepped by Rust in Flutter"> |

| Recolor a photo | Coloring book | Fractal explorer | Live blur |
| :---: | :---: | :---: | :---: |
| <img src="https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/images/screenshot-photo.png" width="200" alt="Flutter app recoloring hair pink and grass purple in a photo with Rust, texture preserved"> | <img src="https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/images/screenshot-paint.png" width="200" alt="Flutter pixel-art coloring book using a Rust flood fill"> | <img src="https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/images/screenshot-fractal.png" width="200" alt="Mandelbrot set rendered by multi-threaded Rust in Flutter"> | <img src="https://raw.githubusercontent.com/winterzxzz/flutter_rust/main/docs/images/screenshot-blur.png" width="200" alt="Real-time 1280x800 box blur in Flutter with Rust"> |

## Features

### Pixel editing
- **`recolorRegionRgba`**: magic-wand selection plus a brightness-preserving
  tint. Tap the hair in a photo and it turns pink, with every strand still
  visible. Selection always reads the original photo, so you can recolor the
  same region again and again.
- **`spreadDistancesRgba` + `paintByDistanceRgba`**: a *spreading fill*. The
  color flows out from the tap as a round wave, follows the region's shape and
  goes around obstacles. It works for photos (tint) and line art (flat color).
- **`floodFillRgba`**: a scanline paint bucket with a per-channel tolerance.
  It fills a solid 2-megapixel region in about 3 ms; a few-thousand-pixel
  region takes about 0.1 ms, fast enough to fill on every `onPanUpdate`.
- **`photoToColoringPage`**: turns any photo into a coloring page: black
  outlines around regions of similar colour, closed and ready to fill. It also
  returns the photo's palette and a label map, for a "reveal" or
  color-by-number mode.
- **Color splash**: gray out a photo with `grayscaleRgba`, then bring the
  colour back region by region with `recolorRegionRgba(strength: 0)`.
- **`coloringPageRgba`**: generates pixel-art coloring pages (Voronoi regions,
  black outlines) from a seed.

### 3D rendering
- **`pathTrace` + `pathResolveRgba`**: a progressive path tracer for a
  built-in scene of glass, metal and diffuse spheres, with soft shadows,
  reflections, refraction and depth of field. Every call adds samples to a
  running average on all cores; `RayCamera` orbits the scene.

### Simulation
- **`sandStep` + `sandRenderRgba`**: a deterministic falling-sand cellular
  automaton. Sand piles up and sinks through water, water flows and levels
  out, and walls hold.

### Image processing
- **`boxBlurRgba`**: multi-threaded box blur, O(pixels) for any radius.
- **`grayscaleRgba`**: BT.601 grayscale, alpha kept.
- **`mandelbrotRgba`**: multi-threaded fractal renderer.

### Data
- **`sha256`**, **`sortFloat64`** (IEEE-754 total order), **`countPrimes`**,
  **`dot`**.

### Engineering
- Zero-copy **leaf** calls on your buffers (about 1.5 ns per call), plus
  **`...Async`** variants that run on a background isolate and block neither the
  UI nor the GC.
- Real multi-threading with a load-balancing work queue (Mandelbrot: 7.3×
  faster on an Apple M4).
- The Rust crate has **zero dependencies** and builds offline.
- 79 tests across Rust, Dart and Flutter. Rust output matches `DartReference`
  bit for bit (except NaN placement when sorting), and SHA-256 matches
  `package:crypto`.

## Installation

```sh
flutter pub add fast_rust     # or: dart pub add fast_rust
```

The build hook compiles the bundled Rust crate on your machine, so you need:

1. **Rust ≥ 1.88** from [rustup.rs](https://rustup.rs). `cargo` must be on
   `PATH`; the hook also looks in `~/.cargo/bin`.
2. The **Rust targets** for the platforms you build:

   ```sh
   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android   # Android
   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios             # iOS
   rustup target add aarch64-apple-darwin x86_64-apple-darwin                             # macOS
   ```

3. Android also needs the NDK installed through Android Studio.

The first build compiles Rust, which takes a few seconds. Later builds are
incremental. The package needs Dart 3.10 or newer (Flutter 3.38 or newer).

## Quick start

```dart
import 'package:fast_rust/fast_rust.dart';

// Hash 8 MiB in one zero-copy call.
final digest = FastRust.sha256(bytes);

// Blur an RGBA8888 image in place on every CPU core.
FastRust.boxBlurRgba(pixels, width: w, height: h, radius: 8);

// Paint bucket: returns the number of painted pixels.
FastRust.floodFillRgba(page, width: w, height: h, x: 10, y: 20, color: 0x2A9D8FFF);

// Heavy work off the UI isolate.
final fractal = await FastRust.mandelbrotRgbaAsync(width: 800, height: 600, scale: 3 / 800);
```

Colors are `0xRRGGBBAA`. Images are RGBA8888 `Uint8List`s of length
`width × height × 4`.

## Recolor a photo

Decode the photo into RGBA bytes once, keep that buffer untouched, and paint
into a copy:

```dart
import 'dart:ui' as ui;
import 'package:fast_rust/fast_rust.dart';
import 'package:flutter/services.dart';

final codec = await ui.instantiateImageCodec(
  (await rootBundle.load('assets/photo.jpg')).buffer.asUint8List(),
);
final image = (await codec.getNextFrame()).image;
final source = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
    .buffer
    .asUint8List();
final canvas = Uint8List.fromList(source);

// In onTapDown: convert the tap to pixel coordinates, then
final painted = FastRust.recolorRegionRgba(
  source,             // read only: every tap selects against the original
  canvas,             // receives the tinted pixels
  width: image.width,
  height: image.height,
  x: px,
  y: py,
  color: 0xFF4D8DFF,  // pink
  tolerance: 28,      // 0..255 per channel; higher selects more
  strength: 230,      // 0..255; how strongly to tint
);

// Show it: ui.decodeImageFromPixels(canvas, w, h, ui.PixelFormat.rgba8888, ...)
```

How it works:

1. **Select.** A scanline flood fill over `source` takes every 4-connected
   pixel whose RGB is within `tolerance` of the tapped pixel.
2. **Tint.** Each selected pixel keeps its own luminance. Dark pixels map
   toward black, mid tones to the new color, and highlights toward white, so
   texture survives.

Integer math only, so `DartReference.recolorRegionRgba` gives the same bytes.

## Spreading fill ("paint that flows")

Instead of recoloring a region all at once, compute each pixel's distance from
the tap once, then paint one more ring every frame:

```dart
final dist = Uint32List(width * height);
final maxDist = FastRust.spreadDistancesRgba(
  source, dist, width: width, height: height, x: px, y: py, tolerance: 28,
);
var painted = 0;

// In a Ticker callback, with `elapsed` since the tap:
final radius = (elapsed.inMicroseconds / 1e6 * 450 * FastRust.spreadStep).round() + 1;
FastRust.paintByDistanceRgba(
  source, canvas, dist,
  width: width, height: height,
  from: painted,             // the previous radius: no pixel is painted twice
  to: radius,
  color: 0xFF4D8DFF,
  tint: true,                // false = flat color, for line art
);
painted = radius;            // stop once painted > maxDist
```

Distances are **geodesic**: they are measured along the region, so the color
flows around obstacles instead of jumping over them. They use Dijkstra with a
bucket queue and 5/7 chamfer steps for orthogonal/diagonal moves, which makes
the wave round rather than diamond-shaped. A diagonal step is only taken next
to an orthogonal one, so the color never leaks through a one-pixel diagonal gap
in an outline. The pass is O(pixels). Pixels outside the region get
`FastRust.unreached`.

## Photo to coloring page

```dart
final page = await FastRust.photoToColoringPageAsync(
  photoRgba,
  width: w,
  height: h,
  colors: 6,                // fewer colors = fewer, bigger regions
  smooth: 5,                // blur radius that removes texture first
  minRegion: w * h ~/ 500,  // merge regions under 0.2% of the photo
  lineWidth: 2,
);

// page.rgba: black outlines on white. Fill it like any coloring page:
FastRust.floodFillRgba(page.rgba, width: w, height: h, x: tapX, y: tapY,
    color: 0xE63946FF);

// page.labels / page.palette: each pixel's color cluster and the photo's
// own colors, so you can "reveal" the finished picture.
```

How it works, all in Rust:

1. **Box blur** with radius `smooth` removes fine texture.
2. **k-means** (6 rounds) groups the pixels into `colors` clusters. It is
   seeded from luminance quantiles, so the result is deterministic.
3. **Two 3×3 majority filters** remove speckles.
4. **Small regions merge.** Any region smaller than `minRegion` pixels joins
   the neighbor it shares the longest border with. This repeats until no
   region changes, at most 8 passes.
5. **Outlines** of `lineWidth` pixels are drawn where the cluster changes,
   plus a frame.

The steps are multi-threaded where possible. With the settings above, a
1920×1080 image takes about 116 ms in Rust and 730 ms in Dart.

## Color splash

No extra kernel is needed. `recolorRegionRgba` with `strength: 0` copies the
original pixels of the selected region:

```dart
final canvas = Uint8List.fromList(photo);
FastRust.grayscaleRgba(canvas);
// On each tap:
FastRust.recolorRegionRgba(photo, canvas,
    width: w, height: h, x: tapX, y: tapY, color: 0, tolerance: 28, strength: 0);
```

The spreading fill works the same way: call `paintByDistanceRgba(...,
tint: true, strength: 0)`.

## Falling sand

```dart
const w = 1024, h = 1024;
final cells = Uint8List(w * h);          // SandMaterial.empty everywhere
final rgba = Uint8List(w * h * 4);
cells[10] = SandMaterial.sand;           // pour, draw walls, etc.

// Every frame (in a Ticker):
FastRust.sandStep(cells, width: w, height: h, frame: frame++);
FastRust.sandRenderRgba(cells, rgba, width: w, height: h);
// then show rgba with ui.decodeImageFromPixels
```

The rules:

- **Scan order:** rows are processed bottom-up, and the column direction
  alternates every frame. Each particle moves at most once per step.
- **Sand** falls, slides diagonally and sinks through water.
- **Water** falls, slides, and spreads sideways.
- **Walls** never move.

Water pushed up by sinking sand also counts as moved. Random choices are a
hash of (x, y, frame), so a run can be replayed exactly, and
`DartReference.sandStep` matches it cell for cell.

## Path tracing

```dart
const w = 360, h = 360;
final accum = Float64List(w * h * 3);   // running RGB sums
final rgba = Uint8List(w * h * 4);
var camera = const RayCamera(yaw: 0.5, pitch: 0.22, aperture: 0.08);
var cameraArray = camera.toArray(w, h);
var samples = 0;

// Every frame (in a Ticker):
FastRust.pathTrace(accum, width: w, height: h,
    camera: cameraArray, firstSample: samples, samples: 1);
samples += 1;
FastRust.pathResolveRgba(accum, rgba, width: w, height: h, sampleCount: samples);
// show rgba with ui.decodeImageFromPixels; on a drag, change the camera,
// clear accum and set samples = 0.
```

**What it renders:** a fixed scene of three large spheres (glass, diffuse and
metal) and eight small ones on a checkered floor, lit by a sky gradient.
Paths bounce up to `maxDepth` times:

- diffuse surfaces scatter in a Lambertian (cosine-weighted) pattern;
- metal reflects, with fuzz;
- glass refracts, with Fresnel reflection (Schlick's approximation);
- a thin lens adds depth of field.

**Threads and random numbers:** every pixel has its own random stream, seeded
by its index and the sample number. Rows are traced on all cores, and the
result is the same for any thread count.

**Exact Dart reference:** the kernel uses only `+ - * /`, `sqrt` and `floor`,
in a fixed order. Random directions use rejection sampling, and gamma is a
square root. `RayCamera.toArray` does the trigonometry once in Dart. As a
result, `DartReference.pathTrace` produces the same bits.

**Speed:** at 480×360, one sample per pixel takes about 5 ms on 8 Rust
threads, against 63 ms in Dart.

## Coloring book flood fill

```dart
final page = FastRust.coloringPageRgba(width: 1024, height: 1024, cells: 140, block: 8, seed: 1);
final n = FastRust.floodFillRgba(page,
    width: 1024, height: 1024, x: tapX, y: tapY, color: 0xE63946FF);
```

`floodFillRgba` works on any RGBA image, including your own line art. With
`tolerance: 0`, filling a region with its own color is a no-op that returns 0.
For anti-aliased line art, use a small tolerance (about 32–64) so the soft edges
are filled too.

## Other kernels

| Function | Kind | What it does |
|---|---|---|
| `sha256(bytes)` / `sha256Async` | leaf / isolate | 32-byte SHA-256 digest. |
| `grayscaleRgba(rgba)` | leaf, in place | BT.601 grayscale. |
| `boxBlurRgba(...)` / `boxBlurRgbaAsync` | leaf, multi-threaded / isolate | Box blur, any radius up to `maxBlurRadius`. |
| `mandelbrotRgba(...)` / `mandelbrotRgbaAsync` | non-leaf, multi-threaded / isolate | Fractal renderer. |
| `sortFloat64(list)` / `sortFloat64Async` | leaf, in place / isolate | pdqsort with IEEE-754 total order (NaN sorted by sign). |
| `countPrimes(limit)` | non-leaf | Odd-only sieve up to `maxPrimeLimit`. |
| `dot(a, b)` | leaf | Dot product of two `Float64List`s. |
| `threadCount`, `setThreadLimit(n)` | | Read or cap Rust worker threads. |

Invalid Dart arguments throw `ArgumentError` or `RangeError` before Rust is
called. Native errors throw `FastRustException`.

## Sync or async

- **Most sync methods** are *leaf* calls on your own buffers. They are the
  fastest, but they block the calling isolate and pause GC while they run.
  `mandelbrotRgba`, `countPrimes` and `photoToColoringPage` are non-leaf calls
  on native memory instead, so they do not pause GC, but they still block the
  calling isolate. Use them for
  work of a few milliseconds, such as a tap fill or a per-frame blur.
- **`...Async` methods** copy the input to native memory, run a *non-leaf*
  call on a background isolate, and return a new list. Use them for anything
  longer.

## Benchmarks

AOT (`dart build cli`), median of 9 runs, Apple M4 with 10 threads.

| Task | Dart | Rust 1 thread | Rust 10 threads |
|---|---:|---:|---:|
| Sort 1M `double`s (vs `List.sort`) | 257 ms | 12.1 ms (21×) | 12.1 ms (21×) |
| Box blur 1920×1080, r=12 | 21.8 ms | 11.3 ms (1.9×) | 2.6 ms (8.2×) |
| Mandelbrot 800×600, 500 iterations | 127 ms | 106 ms (1.2×) | 17.5 ms (7.3×) |
| Grayscale 1920×1080 | 2.3 ms | 0.9 ms (2.6×) | 0.3 ms (7.2×) |
| Flood fill of a 1920×1080 region | 11.7 ms | 2.9 ms (4.0×) | 2.9 ms (4.0×) |
| SHA-256 of 8 MiB (vs `package:crypto`) | 34.8 ms | 18.6 ms (1.9×) | 18.7 ms (1.9×) |

The newer pixel kernels were measured on a different machine (Apple M1 Pro,
8 threads, under background load), so compare them only with each other:

| Task | Dart | Rust |
|---|---:|---:|
| Photo recolor, 1920×1080 region (`recolorRegionRgba`) | 52.9 ms | 27.0 ms (2.0×) |
| Spreading-fill distances, 1920×1080 (`spreadDistancesRgba`) | 182.7 ms | 54.3 ms (3.4×) |
| Photo to coloring page, 1920×1080, demo settings (`photoToColoringPage`) | 731.9 ms | 115.6 ms (6.3×) |
| Falling-sand step, 1024×1024 (`sandStep`) | 13.8 ms | 9.0 ms (1.5×) |
| Path trace 480×360, 1 sample (`pathTrace`, 8 threads) | 63.0 ms | 4.9 ms (12.8×) |

The sand step is a sequential, branchy scan, which AOT Dart handles well, so
Rust gains only about 1.5×. It is the honest exception in this table.

On a real photo, a tapped region is usually far smaller than the whole frame.
In the demo app, one tap on 505×607 px takes 0.05–1.3 ms. Phones are slower than
desktops; run the demo with `--profile` on your device to see real numbers. The
full table, methodology and charts are in the
[repository README](https://github.com/winterzxzz/flutter_rust#1-benchmark-results).

## FAQ

**How do I call Rust from Flutter without `flutter_rust_bridge`?**
Compile Rust to a `cdylib` that exports `extern "C"` functions, declare them
with `@Native` in Dart, and register the library from a build hook. This
package does exactly that; read `hook/build.dart` and `lib/src/bindings.dart`.

**How is this different from platform channels?**
Platform channels serialize messages through Kotlin or Swift and cost
microseconds to milliseconds per call. FFI calls are direct and synchronous, at
about 1.5 ns, and they work on your buffers without copying.

**Can I use camera frames or picked images?**
Yes. Anything you can turn into an RGBA8888 `Uint8List` works, for example
`ui.Image.toByteData(format: ui.ImageByteFormat.rawRgba)`.

**Is Rust always faster than Dart?**
No. AOT Dart is close to Rust for a simple floating-point loop on one core. The
large wins come from multi-threading, from avoiding closure-heavy Dart
patterns (sorting), and from vectorized pixel loops.

**Does it work on the web?**
No. `dart:ffi` is not available on the web.

## Limitations

- Building needs a local Rust toolchain. Prebuilt binaries are not shipped yet.
- Tested end to end on macOS arm64 (`cargo test`, `dart test`, `flutter
  test`). The Android, iOS, Linux and Windows build paths (target triples, NDK
  linker, deployment targets) are written and reviewed, but app builds on those
  platforms have not been run yet.
- Photo selection compares colors with the tapped pixel. Regions whose color
  is close to a neighbor's, such as blonde hair next to skin, can leak; lower
  `tolerance` or tap several times with a smaller one.
- Each parallel call starts fresh threads; there is no persistent pool yet.
  That costs a few tens of microseconds per call.
- Sync leaf calls pause GC while they run. Keep them short or use `...Async`.

## Example

- [`example/fast_rust_example.dart`](https://github.com/winterzxzz/flutter_rust/blob/main/packages/fast_rust/example/fast_rust_example.dart):
  a command-line tour that runs each kernel in Rust and in Dart and checks that
  the outputs match. Run it with `dart run example/fast_rust_example.dart`.
- [`examples/fast_rust_demo`](https://github.com/winterzxzz/flutter_rust/tree/main/examples/fast_rust_demo):
  a Flutter app with seven tabs (Benchmark, Fractal, Live blur, Paint, Photo
  with Recolor/Splash/Line art modes, Sand, Ray) and a Rust/Dart switch on
  each.

## License

MIT. See [LICENSE](https://github.com/winterzxzz/flutter_rust/blob/main/LICENSE).
