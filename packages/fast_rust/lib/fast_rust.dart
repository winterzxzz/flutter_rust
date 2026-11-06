/// High-performance kernels implemented in Rust.
///
/// All synchronous functions operate directly on the memory of the Dart
/// typed lists you pass in (no copies). They block the calling isolate for
/// the duration of the call; use the `...Async` variants, or wrap calls in
/// `Isolate.run`, for work that takes longer than a frame (~16 ms).
library;

export 'src/api.dart'
    show ColoringPage, FastRust, FastRustException, SandMaterial;
export 'src/dart_reference.dart' show DartReference;
