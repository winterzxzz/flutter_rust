## 0.1.0

* Initial release. Rust kernels called through zero-copy `dart:ffi`
  `@Native` functions; a native-assets build hook runs `cargo` for the
  target platform (Android, iOS, macOS, Linux, Windows).
* Photo recoloring: `FastRust.recolorRegionRgba` selects a connected
  region of a real image by color tolerance (magic wand) and tints it
  while keeping each pixel's brightness, so texture survives.
* Pixel-art coloring: `floodFillRgba` (scanline bucket fill with
  tolerance) and `coloringPageRgba` (generated coloring pages).
* Image processing: multi-threaded `boxBlurRgba` (O(pixels) for any
  radius) and `grayscaleRgba`.
* `sha256`, `sortFloat64` (IEEE-754 total order), `countPrimes`, `dot`,
  and a multi-threaded `mandelbrotRgba`.
* `...Async` variants run on a background isolate with non-leaf calls.
* `DartReference`: pure-Dart versions of every kernel, used by the tests
  to check that Rust output matches bit for bit.
