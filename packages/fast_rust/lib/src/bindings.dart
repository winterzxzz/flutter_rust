// Raw bindings to the Rust library. The asset id of this library
// (package:fast_rust/src/bindings.dart) matches the CodeAsset registered in
// hook/build.dart, so @Native resolves symbols without manual dlopen.
//
// Two flavours per heavy kernel:
//
// * `isLeaf: true` — cheapest call, and the only kind that may receive
//   `typedList.address` (zero copy from the Dart heap). While a leaf call
//   runs, GC is paused for *every* isolate in the group, including the UI
//   isolate, so use these only for short calls (a few milliseconds).
// * non-leaf (`...Blocking`) — the thread leaves the Dart VM, so other
//   isolates keep collecting garbage. Must be given native memory.
//
// None of the functions call back into Dart.

import 'dart:ffi';

@Native<Uint32 Function()>(symbol: 'fr_abi_version', isLeaf: true)
external int frAbiVersion();

@Native<Int64 Function(Int64, Int64)>(symbol: 'fr_add_i64', isLeaf: true)
external int frAddI64(int a, int b);

@Native<Uint32 Function()>(symbol: 'fr_thread_count', isLeaf: true)
external int frThreadCount();

@Native<Void Function(Uint32)>(symbol: 'fr_set_thread_limit', isLeaf: true)
external void frSetThreadLimit(int limit);

@Native<Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>)>(
  symbol: 'fr_sha256',
  isLeaf: true,
)
external int frSha256(Pointer<Uint8> data, int len, Pointer<Uint8> out);

@Native<Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>)>(
  symbol: 'fr_sha256',
)
external int frSha256Blocking(Pointer<Uint8> data, int len, Pointer<Uint8> out);

@Native<Int32 Function(Pointer<Uint8>, Size)>(
  symbol: 'fr_grayscale_rgba',
  isLeaf: true,
)
external int frGrayscaleRgba(Pointer<Uint8> rgba, int len);

@Native<Int32 Function(Pointer<Uint8>, Uint32, Uint32, Uint32)>(
  symbol: 'fr_box_blur_rgba',
  isLeaf: true,
)
external int frBoxBlurRgba(
  Pointer<Uint8> rgba,
  int width,
  int height,
  int radius,
);

@Native<Int32 Function(Pointer<Uint8>, Uint32, Uint32, Uint32)>(
  symbol: 'fr_box_blur_rgba',
)
external int frBoxBlurRgbaBlocking(
  Pointer<Uint8> rgba,
  int width,
  int height,
  int radius,
);

@Native<
  Int32 Function(Pointer<Uint8>, Uint32, Uint32, Double, Double, Double, Uint32)
>(symbol: 'fr_mandelbrot_rgba')
external int frMandelbrotRgbaBlocking(
  Pointer<Uint8> out,
  int width,
  int height,
  double centerX,
  double centerY,
  double scale,
  int maxIter,
);

@Native<Int32 Function(Pointer<Double>, Size)>(
  symbol: 'fr_sort_f64',
  isLeaf: true,
)
external int frSortF64(Pointer<Double> data, int len);

@Native<Int32 Function(Pointer<Double>, Size)>(symbol: 'fr_sort_f64')
external int frSortF64Blocking(Pointer<Double> data, int len);

@Native<Uint64 Function(Uint64)>(symbol: 'fr_count_primes')
external int frCountPrimesBlocking(int limit);

@Native<
  Int32 Function(Pointer<Double>, Pointer<Double>, Size, Pointer<Double>)
>(symbol: 'fr_dot_f64', isLeaf: true)
external int frDotF64(
  Pointer<Double> a,
  Pointer<Double> b,
  int len,
  Pointer<Double> out,
);

@Native<Int32 Function(Pointer<Uint8>, Uint32, Uint32, Uint32, Uint32, Uint64)>(
  symbol: 'fr_coloring_page_rgba',
)
external int frColoringPageRgbaBlocking(
  Pointer<Uint8> out,
  int width,
  int height,
  int cells,
  int block,
  int seed,
);

@Native<
  Int64 Function(Pointer<Uint8>, Uint32, Uint32, Uint32, Uint32, Uint32, Uint32)
>(symbol: 'fr_flood_fill_rgba', isLeaf: true)
external int frFloodFillRgba(
  Pointer<Uint8> rgba,
  int width,
  int height,
  int x,
  int y,
  int color,
  int tolerance,
);

@Native<
  Int64 Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
  )
>(symbol: 'fr_recolor_region_rgba', isLeaf: true)
external int frRecolorRegionRgba(
  Pointer<Uint8> src,
  Pointer<Uint8> dst,
  int width,
  int height,
  int x,
  int y,
  int color,
  int tolerance,
  int strength,
);

@Native<
  Int64 Function(
    Pointer<Uint8>,
    Pointer<Uint32>,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
  )
>(symbol: 'fr_spread_distances', isLeaf: true)
external int frSpreadDistances(
  Pointer<Uint8> src,
  Pointer<Uint32> dist,
  int width,
  int height,
  int x,
  int y,
  int tolerance,
);

@Native<
  Int64 Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint32>,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
  )
>(symbol: 'fr_paint_by_distance', isLeaf: true)
external int frPaintByDistance(
  Pointer<Uint8> src,
  Pointer<Uint8> dst,
  Pointer<Uint32> dist,
  int width,
  int height,
  int from,
  int to,
  int color,
  int strength,
  int tint,
);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
  )
>(symbol: 'fr_photo_to_coloring_page')
external int frPhotoToColoringPageBlocking(
  Pointer<Uint8> src,
  Pointer<Uint8> out,
  Pointer<Uint8> labels,
  Pointer<Uint8> palette,
  int width,
  int height,
  int colors,
  int smooth,
  int minRegion,
  int lineWidth,
);

@Native<Int64 Function(Pointer<Uint8>, Uint32, Uint32, Uint32)>(
  symbol: 'fr_sand_step',
  isLeaf: true,
)
external int frSandStep(Pointer<Uint8> cells, int width, int height, int frame);

@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint32, Uint32)>(
  symbol: 'fr_sand_render_rgba',
  isLeaf: true,
)
external int frSandRenderRgba(
  Pointer<Uint8> cells,
  Pointer<Uint8> out,
  int width,
  int height,
);

@Native<
  Int32 Function(
    Pointer<Double>,
    Uint32,
    Uint32,
    Pointer<Double>,
    Uint32,
    Uint32,
    Uint32,
  )
>(symbol: 'fr_path_trace', isLeaf: true)
external int frPathTrace(
  Pointer<Double> accum,
  int width,
  int height,
  Pointer<Double> camera,
  int firstSample,
  int samples,
  int maxDepth,
);

@Native<
  Int32 Function(Pointer<Double>, Pointer<Uint8>, Uint32, Uint32, Uint32)
>(symbol: 'fr_path_resolve_rgba', isLeaf: true)
external int frPathResolveRgba(
  Pointer<Double> accum,
  Pointer<Uint8> out,
  int width,
  int height,
  int sampleCount,
);
