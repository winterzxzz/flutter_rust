<div align="center">

<img src="docs/images/banner.png" alt="flutter_rust: thư viện Flutter + Rust FFI giúp tăng tốc hiệu năng ứng dụng Flutter" width="100%"/>

# flutter_rust: Flutter + Rust FFI để tăng tốc hiệu năng ứng dụng Flutter

**Gọi Rust từ Flutter/Dart qua `dart:ffi`, không cần codegen, zero-copy, tự build bằng native assets.**
Xử lý ảnh, **tô màu pixel-art (flood fill)**, hash, sort, tính toán số nhanh hơn Dart thuần **1.9× đến 21×**,
được đo bằng benchmark và kiểm chứng bằng test.

![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-%E2%89%A53.10-0175C2?logo=dart&logoColor=white)
![Rust](https://img.shields.io/badge/Rust-%E2%89%A51.88-B7410E?logo=rust&logoColor=white)
![FFI](https://img.shields.io/badge/dart%3Affi-zero--copy-6f42c1)
![Dependencies](https://img.shields.io/badge/Rust%20deps-0-success)
![Tests](https://img.shields.io/badge/tests-48%20passing-success)

[Bắt đầu nhanh](#4-bắt-đầu-nhanh) ·
[Benchmark](#1-kết-quả-benchmark) ·
[API](#6-api) ·
[App demo](#9-app-demo) ·
[Câu hỏi thường gặp](#14-câu-hỏi-thường-gặp-faq)

</div>

---

**flutter_rust** là một dự án mẫu hoàn chỉnh cho câu hỏi *"làm sao dùng Rust
trong Flutter để tối ưu hiệu năng?"*. Dự án gồm:

- **`fast_rust`**: thư viện Dart/Flutter. Phần tính toán nặng viết bằng Rust,
  Dart gọi trực tiếp qua `dart:ffi` `@Native`.
- **`fast_rust_demo`**: app Flutter chạy Dart và Rust cạnh nhau trên cùng
  input, để bạn tự thấy khác biệt ngay trên điện thoại.

Thư viện phù hợp với các việc nặng CPU trong app Flutter: **xử lý ảnh**
(blur, grayscale, filter), **app tô màu / pixel art** (flood fill, thùng sơn), **mã hoá và hash** (SHA-256), **sort dữ liệu
lớn**, **tính toán khoa học**, **render đồ hoạ** (fractal) hay **xử lý tín
hiệu**. Đây là những việc mà Dart thuần, hay `compute()`/isolate, vẫn chưa
đủ nhanh.

### Điểm nổi bật

- ⚡ **Nhanh:** mỗi lần gọi FFI chỉ tốn khoảng **1.5 ns**. Rust đọc và ghi
  thẳng vào `Uint8List`/`Float64List` của Dart, không copy, không serialize
  như *platform channel*.
- 🔧 **Không cần cấu hình native:** build hook (*native assets*) tự gọi
  `cargo` khi `flutter run`, `flutter build` hoặc `flutter test`. Không phải
  sửa Gradle, CMake hay Podspec, cũng không phải copy `.so` hay `.dylib`
  bằng tay.
- 🎨 **Tô màu pixel-art mượt:** flood fill một vùng đặc 2 triệu pixel mất
  khoảng 3 ms (Dart: 12 ms); một vùng vài nghìn pixel mất cỡ 0.1 ms, đủ
  nhanh để tô liên tục theo ngón tay.
- 🧵 **Đa luồng thật:** Rust chia việc ra mọi lõi CPU bằng hàng đợi có cân
  bằng tải. Trên Apple M4, Mandelbrot nhanh hơn **7.3×**.
- 📱 **Không làm giật UI:** các hàm `...Async` chạy trên isolate nền với
  *non-leaf call*, nên không chặn UI thread và không chặn GC.
- ✅ **Kiểm chứng:** 48 test (Rust, Dart, Flutter). Kết quả Rust khớp từng
  bit với bản Dart thuần, và khớp với `package:crypto` cho SHA-256.
- 📦 **Gọn:** crate Rust không có dependency nào, build offline, dễ audit.

<div align="center">

| Tô màu pixel-art bằng Rust | Khám phá fractal bằng Rust | Blur ảnh realtime trên UI thread |
|:---:|:---:|:---:|
| <img src="docs/images/screenshot-paint.png" alt="App Flutter tô màu pixel-art bằng flood fill viết bằng Rust, chạm để tô một vùng trong 0.07 ms" width="260"/> | <img src="docs/images/screenshot-fractal.png" alt="App Flutter khám phá tập Mandelbrot, render bằng Rust đa luồng qua dart:ffi" width="260"/> | <img src="docs/images/screenshot-blur.png" alt="App Flutter blur ảnh 1280×800 realtime bằng Rust, 7.2 ms mỗi frame, trong budget 16.7 ms" width="260"/> |
| Chạm hoặc kéo để tô; một vùng ~2 400 px mất **0.07 ms** (một lần đo trong môi trường test) | Render nền bằng Rust 10 luồng; UI vẫn mượt khi zoom | Box blur 1280×800 mất **7.2 ms/frame**, nằm trong budget 60 fps |

</div>

*Ảnh chụp app thật, render headless bằng `flutter test`; xem
[mục 15](#15-tái-tạo-ảnh-và-số-liệu-trong-readme). Số ms trong ảnh đo trong
môi trường test của máy desktop, không phải điện thoại.*

---

## Mục lục

1. [Kết quả benchmark](#1-kết-quả-benchmark)
2. [Cấu trúc thư mục](#2-cấu-trúc-thư-mục)
3. [Yêu cầu](#3-yêu-cầu)
4. [Bắt đầu nhanh](#4-bắt-đầu-nhanh)
5. [Dùng thư viện trong app của bạn](#5-dùng-thư-viện-trong-app-của-bạn)
6. [API](#6-api)
7. [Sync hay Async: quy tắc leaf call](#7-sync-hay-async-quy-tắc-leaf-call)
8. [Kiến trúc và cách hoạt động](#8-kiến-trúc-và-cách-hoạt-động)
9. [App demo](#9-app-demo)
10. [Test và benchmark](#10-test-và-benchmark)
11. [Thêm một hàm Rust mới](#11-thêm-một-hàm-rust-mới)
12. [Xử lý sự cố](#12-xử-lý-sự-cố)
13. [Trạng thái kiểm chứng và giới hạn](#13-trạng-thái-kiểm-chứng-và-giới-hạn)
14. [Câu hỏi thường gặp (FAQ)](#14-câu-hỏi-thường-gặp-faq)
15. [Tái tạo ảnh và số liệu trong README](#15-tái-tạo-ảnh-và-số-liệu-trong-readme)

---

## 1. Kết quả benchmark

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/benchmark-dark.svg">
  <img src="docs/images/benchmark-light.svg" alt="Biểu đồ benchmark Flutter Rust FFI: Rust nhanh hơn Dart từ 1.9 đến 21 lần, gồm blur, flood fill tô màu, Mandelbrot, sort" width="100%">
</picture>

Máy: Apple M4 (10 luồng), macOS. Đo bằng bản AOT (`dart build cli`, tương
đương build release), lấy median của 9 lần chạy sau khi warm-up. Số liệu gốc
nằm ở [`docs/benchmark.json`](docs/benchmark.json).

- **Rust 1T**: Rust bị giới hạn 1 luồng, để đo tốc độ trên một lõi.
- **Rust 10T**: Rust dùng toàn bộ luồng.
- Dart luôn chạy đơn luồng.

| Tác vụ                                     | Dart ms | Rust 1T |     × | Rust 10T |     × |
|--------------------------------------------|--------:|--------:|------:|---------:|------:|
| SHA-256 8 MiB (Dart: `package:crypto`)     |   34.83 |   18.56 |  1.9× |    18.73 |  1.9× |
| Grayscale 1920×1080                        |    2.31 |    0.88 |  2.6× |     0.32 |  7.2× |
| Box blur 1920×1080, r=12                   |   21.80 |   11.26 |  1.9× |     2.65 |  8.2× |
| Mandelbrot 800×600, 500 vòng lặp           |  127.06 |  106.28 |  1.2× |    17.51 |  7.3× |
| Flood fill (tô màu) vùng 1920×1080         |   11.69 |    2.93 |  4.0× |     2.91 |  4.0× |
| Sort 1 triệu `double` (Dart: `List.sort`)  |  257.32 |   12.11 | 21.2× |    12.09 | 21.3× |
| Đếm số nguyên tố ≤ 20 triệu                |   23.24 |    9.23 |  2.5× |     9.34 |  2.5× |
| Tích vô hướng 1 triệu `double`             |    0.69 |    0.32 |  2.2× |     0.32 |  2.1× |

Chi phí một lần gọi FFI (leaf call, AOT) là khoảng **1.5 ns**. Giữa các lần
chạy, số liệu dao động khoảng ±15%; ví dụ blur 10 luồng đo được từ 2.6 đến
4.8 ms.

**Đọc số liệu cho đúng:**

- Flood fill là thuật toán tuần tự, không chia luồng được; mức 4× đến
  hoàn toàn từ tốc độ trên một lõi (so sánh nguyên pixel 4 byte, tô cả
  đoạn bằng vòng ghi đã vector hoá). Số đo dùng một vùng hình chữ nhật đặc,
  trường hợp dễ nhất cho scanline; vùng hình dạng phức tạp tốn nhiều thời
  gian hơn trên mỗi pixel.
- Hai bên chạy cùng thuật toán, trừ hai trường hợp:
  - SHA-256: phía Dart là `package:crypto`.
  - Sort: phía Dart là `List.sort` (gọi closure so sánh cho mỗi phép so
    sánh), phía Rust là pdqsort. Phần lớn mức 21× đến từ chi phí gọi hàm so
    sánh của Dart.
- Với vòng lặp số thực đơn giản như Mandelbrot, Dart AOT nhanh **ngang**
  Rust trên một lõi (1.2×). Lợi thế 7.3× đến hoàn toàn từ đa luồng.
- Số liệu lấy trên một máy desktop. Điện thoại sẽ khác: hãy chạy app demo ở
  `--profile` hoặc `--release` trên máy thật để có số của bạn.
- **Khi nào không nên dùng FFI:** khi mỗi lần gọi chỉ làm vài nano-giây
  việc. Lợi ích đến từ việc chuyển *cả vòng lặp* sang Rust, không phải từng
  phép tính lẻ.

<p align="center">
  <img src="docs/images/blur-before-after.png" alt="So sánh trước và sau khi blur ảnh bằng Rust trong Flutter: bên trái ảnh gốc, bên phải box blur radius 18" width="100%"/>
  <br/><sub>Trước và sau <code>FastRust.boxBlurRgba</code> (radius 18). Ảnh gốc cũng do <code>FastRust.mandelbrotRgba</code> render.</sub>
</p>

## 2. Cấu trúc thư mục

```
flutter_rust/
├── packages/fast_rust/              # Thư viện (package Dart thuần, dùng được cho cả Flutter)
│   ├── rust/                        # Crate Rust (cdylib, không dependency)
│   │   ├── Cargo.toml               # Profile release: LTO, opt-level 3, panic=abort
│   │   └── src/
│   │       ├── lib.rs               # C ABI: các hàm fr_* xuất ra cho Dart
│   │       ├── parallel.rs          # Chia việc theo dải hàng, hàng đợi việc, giới hạn luồng
│   │       ├── hash.rs              # SHA-256 (FIPS 180-4)
│   │       ├── image.rs             # Grayscale, box blur tách hai chiều
│   │       ├── fractal.rs           # Mandelbrot
│   │       ├── coloring.rs          # Sinh trang tô màu pixel-art, flood fill scanline
│   │       └── numeric.rs           # Sort f64, sàng nguyên tố, tích vô hướng
│   ├── hook/build.dart              # Build hook: gọi cargo cho đúng target, đăng ký CodeAsset
│   ├── lib/
│   │   ├── fast_rust.dart           # Entry point public
│   │   └── src/
│   │       ├── bindings.dart        # Khai báo @Native (leaf và non-leaf)
│   │       ├── api.dart             # API an toàn: class FastRust
│   │       └── dart_reference.dart  # Cùng thuật toán viết bằng Dart thuần (oracle và baseline)
│   ├── test/fast_rust_test.dart     # 28 test đúng/sai, validation, async, tô màu
│   ├── benchmark/benchmark.dart     # Benchmark dòng lệnh (--json để xuất số liệu)
│   └── tool/readme_images.dart      # Tạo biểu đồ và ảnh cho README từ output thật
└── examples/fast_rust_demo/         # App Flutter demo
    ├── lib/
    │   ├── main.dart                # 4 tab, trang được build khi mở lần đầu
    │   ├── benchmarks.dart          # Các ca benchmark chạy trên isolate nền
    │   ├── engine.dart              # Enum Rust/Dart, chuyển RGBA sang ui.Image
    │   └── pages/                   # benchmark_page, fractal_page, blur_page, paint_page
    ├── test/app_test.dart           # Widget test (load Rust thật qua native assets)
    └── tool/screenshots_test.dart   # Chụp màn hình app cho README (golden)
docs/
├── benchmark.json                   # Số đo gốc dùng cho bảng và biểu đồ
└── images/                          # Banner, biểu đồ, ảnh chụp app, ảnh render bằng Rust
```

## 3. Yêu cầu

| Thành phần | Phiên bản | Ghi chú |
|---|---|---|
| Dart | ≥ 3.10 | Cần build hooks / native assets. Đã test với Dart 3.13.4. |
| Flutter | có hỗ trợ build hooks | Đã test với Flutter 3.47.5. |
| Rust | ≥ 1.88 | Cài qua [rustup](https://rustup.rs). Đã test với 1.99.1. |

Cài thêm target Rust cho nền tảng bạn build:

```sh
# Android
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
# iOS (máy thật + simulator)
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
# macOS
rustup target add aarch64-apple-darwin x86_64-apple-darwin
# Linux / Windows
rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu
rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc
```

- **Android**: cần Android NDK. Flutter tự truyền đường dẫn clang của NDK
  cho build hook, và hook dùng nó làm linker.
- **iOS/macOS**: cần Xcode.
- `cargo` phải nằm trong `PATH`. Nếu không có, hook thử
  `~/.cargo/bin/cargo`, vì IDE mở từ GUI hay thiếu đường dẫn này.

## 4. Bắt đầu nhanh

```sh
git clone <repo> flutter_rust && cd flutter_rust

# 1. Test thư viện (lần đầu sẽ build Rust, mất vài giây)
cd packages/fast_rust
dart pub get
dart test

# 2. Benchmark
dart run benchmark/benchmark.dart                # JIT (giống bản debug)
dart build cli -t benchmark/benchmark.dart       # AOT (giống bản release)
./build/cli/*/bundle/bin/benchmark

# 3. Chạy app demo
cd ../../examples/fast_rust_demo
flutter pub get
flutter test
flutter run --release        # hoặc --profile; bản debug chạy Dart ở chế độ JIT nên chậm hơn
```

## 5. Dùng thư viện trong app của bạn

Thêm dependency, hiện đang dùng qua path:

```yaml
dependencies:
  fast_rust:
    path: ../packages/fast_rust
```

Ví dụ:

```dart
import 'dart:typed_data';
import 'package:fast_rust/fast_rust.dart';

// Hash: zero-copy, chạy đồng bộ
final Uint8List digest = FastRust.sha256(bytes);

// Blur nhỏ trong một frame: sửa trực tiếp buffer RGBA
FastRust.boxBlurRgba(pixels, width: w, height: h, radius: 10);

// Việc nặng: chạy trên isolate nền, không chặn UI và GC
final Uint8List blurred =
    await FastRust.boxBlurRgbaAsync(bigImage, width: W, height: H, radius: 30);

final Uint8List fractal = await FastRust.mandelbrotRgbaAsync(
  width: 800,
  height: 600,
  scale: 3 / 800,          // kích thước 1 pixel trên mặt phẳng phức
  maxIterations: 500,
);

// Tô màu pixel-art: sinh trang rồi "đổ sơn" vào vùng được chạm
final page = FastRust.coloringPageRgba(width: 1024, height: 1024, cells: 140, block: 8);
final painted = FastRust.floodFillRgba(page,
    width: 1024, height: 1024, x: tapX, y: tapY, color: 0x2A9D8FFF);

// Sort tại chỗ (thứ tự tổng IEEE-754)
FastRust.sortFloat64(values);
final sorted = await FastRust.sortFloat64Async(hugeList);   // trả về bản sao đã sort

// Hiển thị ảnh RGBA trong Flutter
ui.decodeImageFromPixels(fractal, 800, 600, ui.PixelFormat.rgba8888, (img) {
  // dùng với RawImage(image: img)
});
```

Lỗi từ phía native được ném ra dưới dạng `FastRustException` (null pointer,
invalid argument, out of memory). Tham số sai kiểu Dart ném `ArgumentError`
hoặc `RangeError` trước khi gọi sang Rust.

## 6. API

Mọi thứ nằm trong `abstract final class FastRust`.

| Hàm | Kiểu gọi | Mô tả |
|---|---|---|
| `sha256(Uint8List) → Uint8List` | sync, leaf, zero-copy | Digest SHA-256 32 byte. |
| `sha256Async(Uint8List) → Future<Uint8List>` | isolate nền, non-leaf | Như trên, không chặn UI hay GC. |
| `grayscaleRgba(Uint8List)` | sync, leaf, tại chỗ | Chuyển xám theo BT.601, giữ nguyên alpha. |
| `boxBlurRgba(rgba, width:, height:, radius:)` | sync, leaf, tại chỗ, đa luồng | Box blur tách hai chiều, O(số pixel) với mọi radius. |
| `boxBlurRgbaAsync(...) → Future<Uint8List>` | isolate nền, non-leaf | Trả về ảnh mới, không sửa input. |
| `mandelbrotRgba(width:, height:, centerX:, centerY:, scale:, maxIterations:) → Uint8List` | sync, non-leaf, đa luồng | Render RGBA8888. |
| `mandelbrotRgbaAsync(...) → Future<Uint8List>` | isolate nền, non-leaf | Như trên, chạy nền. |
| `sortFloat64(Float64List)` | sync, leaf, tại chỗ | pdqsort theo `f64::total_cmp`. |
| `sortFloat64Async(Float64List) → Future<Float64List>` | isolate nền, non-leaf | Trả về bản sao đã sort. |
| `coloringPageRgba(width:, height:, cells:, block:, seed:) → Uint8List` | sync, non-leaf, đa luồng | Sinh trang tô màu pixel-art: `cells` vùng Voronoi trên lưới ô `block`×`block` px, viền đen. Cùng `seed` thì cùng trang. |
| `coloringPageRgbaAsync(...) → Future<Uint8List>` | isolate nền, non-leaf | Như trên, chạy nền. |
| `floodFillRgba(rgba, width:, height:, x:, y:, color:, tolerance:) → int` | sync, leaf, tại chỗ | "Thùng sơn": tô vùng liên thông 4 hướng quanh (x, y) bằng `color` (`0xRRGGBBAA`); `tolerance` 0–255 cho mỗi kênh. Trả về số pixel đã tô (0 nếu `tolerance` = 0 và vùng đã có sẵn màu đó). |
| `countPrimes(int) → int` | sync, non-leaf | Số số nguyên tố ≤ limit (sàng chỉ xét số lẻ). |
| `dot(Float64List, Float64List) → double` | sync, leaf | Tích vô hướng, 4 accumulator để LLVM vector hoá. |
| `threadCount` / `setThreadLimit(int)` | | Đọc hoặc giới hạn số luồng Rust (`0` là mặc định: số lõi, tối đa 16). |
| `abiVersion`, `add(a, b)` | | Phiên bản ABI; `add` dùng để đo chi phí gọi FFI. |

**Giới hạn input** (vượt quá sẽ ném `RangeError`):

| Hằng số | Giá trị | Lý do |
|---|---|---|
| `FastRust.maxBlurRadius` | 1024 | Tổng cửa sổ không tràn `u32`, chặn trên thời gian chạy. |
| `FastRust.maxIterations` | 2²⁰ | Tránh treo vì số vòng lặp quá lớn. |
| `FastRust.maxColoringCells` / `maxColoringBlock` | 65 536 / 256 | Giới hạn tham số của trang tô màu. |
| `FastRust.maxColoringWork` | 2³¹ | Tổng số ô lưới × số vùng (chi phí tìm vùng gần nhất); vượt quá sẽ ném `ArgumentError`. Chặn trên thời gian sinh trang. |
| `FastRust.maxPrimeLimit` | 2³¹ − 1 | Sàng cần `limit/2` byte (tối đa 1 GiB). Cấp phát thất bại sẽ ném `FastRustException`, app không bị abort. |

**Thứ tự NaN khi sort:** `-NaN < -∞ < … < -0.0 < 0.0 < … < ∞ < NaN`. Khác
với `List.sort` của Dart, vốn đưa mọi NaN về cuối.

`DartReference` cung cấp các hàm cùng tên, viết bằng Dart thuần. Chúng dùng
để test và làm baseline cho benchmark.

## 7. Sync hay Async: quy tắc leaf call

Đây là điểm quan trọng nhất khi dùng FFI hiệu năng cao.

**Leaf call** (`@Native(isLeaf: true)`):
- Rẻ nhất: thread không rời Dart VM.
- Là kiểu gọi duy nhất được nhận `typedList.address`, tức con trỏ thẳng vào
  heap của Dart, không copy.
- Đổi lại, **trong lúc leaf call chạy, GC của mọi isolate trong cùng
  group bị tạm dừng**, kể cả UI isolate, kể cả khi bạn gọi từ `Isolate.run`.

**Non-leaf call:**
- Thread rời VM, nên isolate khác vẫn dọn rác bình thường.
- Không nhận được con trỏ vào heap Dart, nên phải dùng bộ nhớ native
  (`malloc`).

Thư viện chọn như sau:

| Trường hợp | Kiểu gọi |
|---|---|
| Hàm sync trên buffer của bạn (`sha256`, `boxBlurRgba`, `grayscaleRgba`, `floodFillRgba`, `sortFloat64`, `dot`) | **leaf**, zero-copy. Chỉ dùng cho việc vài mili-giây, ví dụ blur mỗi frame trong demo. |
| `...Async` | isolate nền, copy sang bộ nhớ native, gọi **non-leaf**, copy kết quả về. Dùng cho việc dài. |
| `mandelbrotRgba`, `coloringPageRgba`, `countPrimes` | luôn **non-leaf**, vì chỉ ghi ra hoặc không có buffer. |

Quy tắc ngón tay cái: nếu một lần gọi có thể vượt quá khoảng 4 ms trên
điện thoại (một phần tư budget 16.7 ms của một frame), hãy dùng bản `Async`.

## 8. Kiến trúc và cách hoạt động

```
 Dart / Flutter app
        │  FastRust.boxBlurRgba(pixels, …)
        ▼
 lib/src/api.dart          kiểm tra tham số, chọn leaf hoặc non-leaf
        │
 lib/src/bindings.dart     @Native<…>(symbol: 'fr_box_blur_rgba', isLeaf: true)
        │                  asset id = package:fast_rust/src/bindings.dart
        ▼
 libfast_rust.{so,dylib,dll}   ← do hook/build.dart build và đóng gói
        │
 rust/src/lib.rs           extern "C" fr_*: kiểm tra null và kích thước, trả mã i32
        ▼
 rust/src/image.rs …       kernel thuần Rust, chạy song song qua parallel.rs
```

**Build hook (`hook/build.dart`):**

1. Dart hoặc Flutter SDK chạy hook với target OS và kiến trúc hiện tại.
2. Hook ánh xạ sang target triple của Rust, ví dụ `android/arm64` thành
   `aarch64-linux-android`, `iOS simulator/arm64` thành
   `aarch64-apple-ios-sim`.
3. Hook gọi `cargo rustc --release --lib --crate-type cdylib --target
   <triple>`. Output đặt trong thư mục cache của hook (`.dart_tool/…`), nên
   các lần build sau là incremental.
   - Trên Android, hook dùng clang wrapper của NDK làm linker
     (`<triple><api>-clang`) và thêm `-z max-page-size=16384` để hỗ trợ
     thiết bị dùng page 16 KB (Android 15+).
   - Trên Apple, hook đặt `MACOSX_DEPLOYMENT_TARGET` hoặc
     `IPHONEOS_DEPLOYMENT_TARGET` theo cấu hình của Flutter.
4. Hook đăng ký `CodeAsset(name: 'src/bindings.dart',
   linkMode: DynamicLoadingBundled())`. SDK tự đóng gói thư viện vào app
   (APK, framework, bundle). Các hàm `@Native` trong `bindings.dart` tự
   resolve symbol, không cần `DynamicLibrary.open`.
5. Hook khai báo từng file trong `rust/src/` là dependency, nên sửa code Rust
   sẽ tự build lại.

**Quy ước C ABI (`rust/src/lib.rs`):**
- Mọi hàm `fr_*` nhận con trỏ cùng độ dài, và không bao giờ cấp phát bộ nhớ
  đi qua ranh giới FFI. Bên gọi sở hữu bộ nhớ.
- Trả về `i32`: `0` là OK, `-1` là null pointer, `-2` là invalid argument.
  Phía Dart chuyển mã này thành `FastRustException`.
- `len == 0` không bao giờ dereference con trỏ.
- `panic = "abort"` và mọi input được kiểm tra trước, nên không có unwind
  đi qua FFI.

**Đa luồng (`rust/src/parallel.rs`):**
- Dữ liệu được chia thành các dải hàng (khoảng 16K phần tử mỗi dải). Các
  dải nằm trong một hàng đợi dùng chung có mutex, nên luồng nào xong sớm sẽ
  lấy thêm việc. Cách này quan trọng với tải không đều như fractal: chuyển
  từ chia cố định sang hàng đợi đã đưa Mandelbrot từ 3.6× lên 6.8× (đo ở JIT).
- Thread gọi cũng tham gia làm việc. Input nhỏ chạy luôn trên thread hiện
  tại để khỏi tốn chi phí spawn.
- Kernel có chi phí khởi tạo theo dải (cửa sổ dọc của blur) xin dải cao
  hơn qua tham số `min_band_rows`.

**Box blur O(số pixel):** hai lượt, ngang rồi dọc. Mỗi lượt giữ một tổng
trượt, và các mẫu bị kẹp ở mép ảnh được tính bằng phép nhân thay vì lặp.
Nhờ vậy chi phí không phụ thuộc radius.

## 9. App demo

`examples/fast_rust_demo` có 4 tab. Mỗi tab chỉ build khi được mở lần đầu,
để việc nặng không chạy lúc khởi động.

| Tab | Chứng minh điều gì |
|---|---|
| **Benchmark** | Bấm *Run all*: từng ca chạy Dart và Rust trên isolate nền, rồi hiện thanh so sánh và hệ số nhanh hơn. Nếu đang ở bản debug, app có cảnh báo. |
| **Fractal** | Khám phá Mandelbrot ở độ phân giải màn hình (tối đa 1200 px). Chạm để zoom vào, nhấn giữ để zoom ra, chỉnh số vòng lặp, đổi engine Rust hoặc Dart và xem số ms. Render chạy trên isolate nền với non-leaf call, nên UI luôn mượt. |
| **Paint** (tô màu) | Sách tô màu pixel-art 1024×1024 do Rust sinh ra. Trang này không cuộn, để mọi cú kéo đều là tô. Chọn màu, rồi **chạm hoặc kéo ngón tay** để tô từng vùng bằng flood fill; app hiện số pixel và thời gian mỗi lần tô. Nút **Auto** tô lại *N* vùng ngẫu nhiên mỗi frame (thanh trượt 1–200) và hiện **FPS** cùng thời gian tô mỗi frame. Đổi Rust/Dart để so trực tiếp trên chính thiết bị của bạn; số FPS phụ thuộc cả thời gian upload ảnh, không chỉ thời gian tô. |
| **Live blur** | Ảnh 1280×800 (chính ảnh này cũng do Rust render), blur ngay trên UI thread mỗi lần kéo slider. Màn hình hiện số ms mỗi frame so với budget 16.7 ms. Vòng xoay tiến trình đứng hình nghĩa là UI thread đang bị chặn. |

Chạy:

```sh
cd examples/fast_rust_demo
flutter run --profile      # số đo đại diện; dùng --release để trải nghiệm thật
```

## 10. Test và benchmark

| Lệnh | Kiểm tra gì |
|---|---|
| `cd packages/fast_rust/rust && cargo test --release` | 14 test Rust: flood fill khớp BFS trên trang tô màu ngẫu nhiên, tolerance; vector NIST của SHA-256, blur khớp bản naive O(r²) kể cả radius lớn hơn ảnh, bản song song khớp bản tuần tự, NaN, sàng nguyên tố, FFI từ chối null và kích thước sai. |
| `cd packages/fast_rust && dart test` | 28 test: trang tô màu (kể cả seed âm hay ≥ 2⁶³) và flood fill khớp bản Dart từng pixel, kể cả buffer lệch căn chỉnh; Rust khớp `package:crypto` và `DartReference` từng bit, view có offset, validation, các bản async non-leaf, thứ tự NaN, giới hạn luồng không đổi kết quả. |
| `cd examples/fast_rust_demo && flutter test` | 6 test: tab Paint tô bằng cú kéo dọc (không cuộn trang) và chế độ Auto; Rust load được trong `flutter test`, trang build lazy, fractal render qua isolate, live blur render frame, ca benchmark chạy được. |
| `dart run benchmark/benchmark.dart` | Bảng so sánh Dart, Rust 1T và Rust nT. |

Kiểm tra lint: `cargo clippy --release --all-targets`, `dart analyze`,
`flutter analyze`. Ảnh chụp app không nằm trong bộ test thường; chúng được
tạo riêng bằng `flutter test tool/screenshots_test.dart --update-goldens`.

## 11. Thêm một hàm Rust mới

1. **Rust:** viết kernel trong một module, rồi xuất ra trong `rust/src/lib.rs`:

   ```rust
   #[no_mangle]
   pub unsafe extern "C" fn fr_invert_rgba(rgba: *mut u8, len: usize) -> i32 {
       if len % 4 != 0 { return Status::InvalidArgument as i32; }
       let rgba = try_slice!(slice_mut(rgba, len));
       for px in rgba.chunks_exact_mut(4) { px[0] = !px[0]; px[1] = !px[1]; px[2] = !px[2]; }
       Status::Ok as i32
   }
   ```

2. **Binding:** khai báo trong `lib/src/bindings.dart`.
   - Dùng leaf call cho việc ngắn trên buffer Dart.
   - Dùng non-leaf (bỏ `isLeaf`) và bộ nhớ native cho việc dài.

   ```dart
   @Native<Int32 Function(Pointer<Uint8>, Size)>(symbol: 'fr_invert_rgba', isLeaf: true)
   external int frInvertRgba(Pointer<Uint8> rgba, int len);
   ```

3. **API:** bọc trong `FastRust` (`lib/src/api.dart`), kiểm tra tham số rồi
   gọi `_check(...)`.
4. **Test:** viết bản Dart trong `DartReference` và test so khớp trong
   `test/fast_rust_test.dart`.
5. Nếu thay đổi chữ ký của một hàm đã có, hãy tăng `fr_abi_version`.

Không cần sửa build hook: mọi file trong `rust/src/` đã được theo dõi.

## 12. Xử lý sự cố

| Triệu chứng | Cách xử lý |
|---|---|
| `cargo rustc --target … failed`, kèm gợi ý `rustup target add …` | Chưa cài target Rust cho nền tảng đó. Chạy lệnh được gợi ý. |
| Không tìm thấy `cargo` khi build từ IDE | Thêm `~/.cargo/bin` vào `PATH` của IDE. Hook cũng tự thử đường dẫn này. |
| Android: lỗi linker `…-clang` không tồn tại | NDK cài đặt không có wrapper cho API level đang yêu cầu. Nâng NDK hoặc chỉnh `minSdk`. |
| `Invalid argument(s): Illegal argument in isolate message: object is unsendable` | Closure gửi cho `Isolate.run` được tạo bên trong method của `State`, nên nó giữ `this`. Hãy tạo closure trong hàm top-level, như `_renderInBackground` trong `fractal_page.dart`. |
| Số benchmark trong app thấp bất thường | Bạn đang chạy bản debug (JIT). Hãy dùng `--profile` hoặc `--release`. |
| UI giật khi xử lý dữ liệu lớn | Bạn đang gọi bản sync (leaf) cho việc dài. Chuyển sang `...Async`, xem [mục 7](#7-sync-hay-async-quy-tắc-leaf-call). |

## 13. Trạng thái kiểm chứng và giới hạn

**Đã kiểm chứng** trên macOS arm64:
- `cargo test` và clippy.
- `dart test` và `dart analyze`.
- `flutter test` và `flutter analyze`. Thư viện Rust được build và load qua
  native assets trong cả ba môi trường test.
- Benchmark JIT và AOT.

**Chưa kiểm chứng:** build app cho Android, iOS và desktop. Logic chọn
target triple, linker NDK và deployment target đã viết và đã được review,
nhưng chưa chạy trên các nền tảng này.

**Giới hạn đã biết:**
- Mỗi lần gọi hàm song song, Rust spawn luồng mới, chưa có thread pool cố
  định. Chi phí này cỡ vài chục µs mỗi lần gọi; với blur mỗi frame trên
  Android có thể đáng kể.
- Nhiều isolate cùng gọi hàm song song cùng lúc có thể tranh nhau lõi CPU.
- Hàm sync dạng leaf vẫn tạm dừng GC trong lúc chạy (xem mục 7).
- Chưa có giấy phép (license) cho dự án.

## 14. Câu hỏi thường gặp (FAQ)

<details open>
<summary><b>Làm sao gọi code Rust từ Flutter?</b></summary>

1. Biên dịch Rust thành thư viện động (`cdylib`), xuất hàm
   `extern "C"`.
2. Khai báo hàm đó trong Dart bằng `@Native` của `dart:ffi`.
3. Dùng build hook (native assets) để Flutter tự build và đóng gói thư viện
   cho từng nền tảng.

Dự án này làm sẵn cả ba bước. Xem [mục 8](#8-kiến-trúc-và-cách-hoạt-động)
và [mục 11](#11-thêm-một-hàm-rust-mới).
</details>

<details>
<summary><b>Có cần <code>flutter_rust_bridge</code> không?</b></summary>

Không bắt buộc. `flutter_rust_bridge` mạnh khi bạn cần truyền kiểu dữ liệu
phức tạp (struct, enum, `String`, stream, async Rust) và muốn sinh binding
tự động. Dự án này chọn cách viết tay tối giản, phù hợp khi các hàm làm
việc trên buffer số (ảnh, mảng `double`, byte):

- không có bước codegen;
- không có dependency phía Rust;
- con trỏ đi thẳng vào buffer Dart, nên chi phí gọi gần như bằng không.
</details>

<details>
<summary><b>FFI khác gì platform channel (MethodChannel)?</b></summary>

Platform channel gửi message bất đồng bộ qua Kotlin/Swift và phải
serialize dữ liệu, nên mỗi lần gọi tốn cỡ micro-giây đến mili-giây. FFI gọi
hàm native trực tiếp và đồng bộ, khoảng 1.5 ns mỗi lần. Với dữ liệu lớn như
ảnh, FFI còn tránh được việc copy.
</details>

<details>
<summary><b>Rust có luôn nhanh hơn Dart không?</b></summary>

Không. Dart AOT đã khá nhanh với vòng lặp số học đơn giản: Mandelbrot trên 1
lõi chỉ nhanh hơn 1.2×. Rust thắng rõ khi:

- dùng được đa luồng;
- thuật toán hưởng lợi từ tối ưu của LLVM (sort, SHA-256);
- tránh được overhead của Dart (closure so sánh, kiểm tra biên).

Hãy đo trước khi chuyển code.
</details>

<details>
<summary><b>Gọi Rust có làm UI Flutter bị giật không?</b></summary>

Có thể, nếu bạn gọi hàm sync cho việc dài. Hàm sync là *leaf call*: nó chặn
isolate đang gọi và tạm dừng GC của cả nhóm isolate. Với việc trên vài
mili-giây, hãy dùng các hàm `...Async`: chúng chạy trên isolate nền với
non-leaf call, không chặn UI hay GC. Xem [mục 7](#7-sync-hay-async-quy-tắc-leaf-call).
</details>

<details>
<summary><b>Có chạy trên Android và iOS không?</b></summary>

Build hook đã có logic cho Android (arm64, armv7, x86_64, x86), iOS (máy
thật và simulator), macOS, Linux và Windows. Hiện mới **kiểm chứng trên
macOS**; Android và iOS chưa được build thử. Xem
[mục 13](#13-trạng-thái-kiểm-chứng-và-giới-hạn).
</details>

<details>
<summary><b>Làm app tô màu (coloring book, pixel art) bằng Flutter có mượt không?</b></summary>

Có. `FastRust.floodFillRgba` tô một vùng đặc 2 triệu pixel trong khoảng 3
ms, so với 12 ms bằng Dart thuần (đo trên desktop). Một vùng cỡ vài nghìn pixel chỉ mất dưới 0.1 ms. Với
tốc độ đó bạn có thể tô ngay trong `onPanUpdate` khi người dùng kéo ngón
tay mà không bị trễ. Xem tab **Paint** trong app demo
(`examples/fast_rust_demo/lib/pages/paint_page.dart`) để có ví dụ hoàn chỉnh:
chọn màu, chạm, kéo, chế độ Auto kèm bộ đếm FPS.
</details>

<details>
<summary><b>Dùng được cho xử lý ảnh từ camera hay file không?</b></summary>

Được. Mọi hàm ảnh nhận buffer **RGBA8888** (`Uint8List`, dài
`width × height × 4`). Bạn có thể lấy buffer từ `ui.Image.toByteData(format:
ImageByteFormat.rawRgba)` hoặc từ frame camera sau khi chuyển sang RGBA.
</details>

## 15. Tái tạo ảnh và số liệu trong README

Mọi ảnh trong `docs/images` (trừ banner) được tạo từ chính thư viện, nên bạn
có thể tự kiểm tra lại:

```sh
cd packages/fast_rust
dart build cli -t benchmark/benchmark.dart
./build/cli/*/bundle/bin/benchmark --json=../../docs/benchmark.json   # số đo
dart run tool/readme_images.dart ../../docs                           # biểu đồ SVG, fractal, blur

cd ../../examples/fast_rust_demo
flutter test tool/screenshots_test.dart --update-goldens              # ảnh chụp app
```

| Ảnh | Nguồn |
|---|---|
| `benchmark-light.svg`, `benchmark-dark.svg` | `tool/readme_images.dart`, đọc `docs/benchmark.json` |
| `mandelbrot.png`, `blur-before-after.png` | `FastRust.mandelbrotRgba` và `FastRust.boxBlurRgba` |
| `screenshot-*.png` (fractal, blur, paint) | golden test của app demo, dùng font Roboto thật |
| `banner.png` | ảnh minh hoạ do AI tạo, không chứa số liệu |

---

<div align="center">

<img src="docs/images/mandelbrot.png" alt="Tập Mandelbrot 1600×800 render bằng Rust đa luồng từ Dart qua dart:ffi" width="100%"/>

**Từ khoá:** Flutter Rust · Flutter FFI · dart:ffi · gọi Rust từ Flutter ·
tối ưu hiệu năng Flutter · tăng tốc Flutter · native assets · build hooks ·
xử lý ảnh Flutter · Flutter image processing · app tô màu Flutter · flood fill ·
pixel art · coloring book · Rust cdylib · flutter_rust_bridge
alternative · Dart isolate · Flutter performance

Nếu thấy hữu ích, hãy ⭐ repo để nhiều người tìm thấy hơn.

</div>
