# flutter_rust

Thư viện **`fast_rust`** đưa các đoạn code nặng của Flutter/Dart sang **Rust**
để tăng hiệu năng. Kèm theo là app **`fast_rust_demo`**, chứng minh bằng số đo
thật: chạy Dart và Rust cạnh nhau trên cùng input, cùng thuật toán.

- Không codegen, không serialize. Dart gọi Rust qua `dart:ffi` `@Native`,
  truyền thẳng địa chỉ buffer (zero-copy). Mỗi lần gọi tốn khoảng **1.5 ns**.
- Không cần chỉnh Gradle, CMake hay Podspec. Build hook của Dart
  (*native assets*) tự gọi `cargo` cho đúng nền tảng mỗi khi bạn
  `flutter run`, `flutter build`, `flutter test`, `dart run` hay `dart test`.
- Crate Rust không có dependency nào: build offline, nhanh, dễ audit.
- Đa luồng thật bằng `std::thread::scope` và hàng đợi việc có cân bằng tải.
- Kết quả Rust được kiểm tra khớp **từng bit** với bản Dart thuần, và với
  `package:crypto` cho SHA-256.

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

---

## 1. Kết quả benchmark

Máy: Apple M4 (10 luồng), macOS. Đo bằng bản AOT (`dart build cli`, tương
đương build release), lấy median của 9 lần chạy sau khi warm-up.

- **Rust 1T**: Rust bị giới hạn 1 luồng, để đo tốc độ trên một lõi.
- **Rust 10T**: Rust dùng toàn bộ luồng.
- Dart luôn chạy đơn luồng.

| Tác vụ                                     | Dart ms | Rust 1T |     × | Rust 10T |     × |
|--------------------------------------------|--------:|--------:|------:|---------:|------:|
| SHA-256 8 MiB (Dart: `package:crypto`)     |   34.51 |   18.73 |  1.8× |    18.74 |  1.8× |
| Grayscale 1920×1080                        |    2.32 |    0.89 |  2.6× |     0.36 |  6.5× |
| Box blur 1920×1080, r=12                   |   23.61 |   11.46 |  2.1× |     2.63 |  9.0× |
| Mandelbrot 800×600, 500 vòng lặp           |  117.63 |  117.21 |  1.0× |    19.08 |  6.2× |
| Sort 1 triệu `double` (Dart: `List.sort`)  |  267.21 |   12.40 | 21.5× |    12.65 | 21.1× |
| Đếm số nguyên tố ≤ 20 triệu                |   23.74 |    8.78 |  2.7× |     8.94 |  2.7× |
| Tích vô hướng 1 triệu `double`             |    0.70 |    0.34 |  2.1× |     0.33 |  2.1× |

Chi phí một lần gọi FFI (leaf call, AOT) là khoảng **1.5 ns**.

**Đọc số liệu cho đúng:**

- Hai bên chạy cùng thuật toán, trừ hai trường hợp:
  - SHA-256: phía Dart là `package:crypto`.
  - Sort: phía Dart là `List.sort` (gọi closure so sánh cho mỗi phép so
    sánh), phía Rust là pdqsort. Phần lớn mức 21× đến từ chi phí gọi hàm so
    sánh của Dart.
- Với vòng lặp số thực đơn giản như Mandelbrot, Dart AOT nhanh **ngang**
  Rust trên một lõi. Lợi thế 6.2× đến hoàn toàn từ đa luồng.
- Số liệu lấy trên một máy desktop. Điện thoại sẽ khác: hãy chạy app demo ở
  `--profile` hoặc `--release` trên máy thật để có số của bạn.
- **Khi nào không nên dùng FFI:** khi mỗi lần gọi chỉ làm vài nano-giây
  việc. Lợi ích đến từ việc chuyển *cả vòng lặp* sang Rust, không phải từng
  phép tính lẻ.

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
│   │       └── numeric.rs           # Sort f64, sàng nguyên tố, tích vô hướng
│   ├── hook/build.dart              # Build hook: gọi cargo cho đúng target, đăng ký CodeAsset
│   ├── lib/
│   │   ├── fast_rust.dart           # Entry point public
│   │   └── src/
│   │       ├── bindings.dart        # Khai báo @Native (leaf và non-leaf)
│   │       ├── api.dart             # API an toàn: class FastRust
│   │       └── dart_reference.dart  # Cùng thuật toán viết bằng Dart thuần (oracle và baseline)
│   ├── test/fast_rust_test.dart     # 22 test đúng/sai, validation, async
│   └── benchmark/benchmark.dart     # Benchmark dòng lệnh
└── examples/fast_rust_demo/         # App Flutter demo
    ├── lib/
    │   ├── main.dart                # 3 tab, trang được build khi mở lần đầu
    │   ├── benchmarks.dart          # Các ca benchmark chạy trên isolate nền
    │   ├── engine.dart              # Enum Rust/Dart, chuyển RGBA sang ui.Image
    │   └── pages/                   # benchmark_page, fractal_page, blur_page
    └── test/app_test.dart           # Widget test (load Rust thật qua native assets)
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
| `countPrimes(int) → int` | sync, non-leaf | Số số nguyên tố ≤ limit (sàng chỉ xét số lẻ). |
| `dot(Float64List, Float64List) → double` | sync, leaf | Tích vô hướng, 4 accumulator để LLVM vector hoá. |
| `threadCount` / `setThreadLimit(int)` | | Đọc hoặc giới hạn số luồng Rust (`0` là mặc định: số lõi, tối đa 16). |
| `abiVersion`, `add(a, b)` | | Phiên bản ABI; `add` dùng để đo chi phí gọi FFI. |

**Giới hạn input** (vượt quá sẽ ném `RangeError`):

| Hằng số | Giá trị | Lý do |
|---|---|---|
| `FastRust.maxBlurRadius` | 1024 | Tổng cửa sổ không tràn `u32`, chặn trên thời gian chạy. |
| `FastRust.maxIterations` | 2²⁰ | Tránh treo vì số vòng lặp quá lớn. |
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
| Hàm sync trên buffer của bạn (`sha256`, `boxBlurRgba`, `grayscaleRgba`, `sortFloat64`, `dot`) | **leaf**, zero-copy. Chỉ dùng cho việc vài mili-giây, ví dụ blur mỗi frame trong demo. |
| `...Async` | isolate nền, copy sang bộ nhớ native, gọi **non-leaf**, copy kết quả về. Dùng cho việc dài. |
| `mandelbrotRgba`, `countPrimes` | luôn **non-leaf**, vì chỉ ghi ra hoặc không có buffer. |

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

`examples/fast_rust_demo` có 3 tab. Mỗi tab chỉ build khi được mở lần đầu,
để việc nặng không chạy lúc khởi động.

| Tab | Chứng minh điều gì |
|---|---|
| **Benchmark** | Bấm *Run all*: từng ca chạy Dart và Rust trên isolate nền, rồi hiện thanh so sánh và hệ số nhanh hơn. Nếu đang ở bản debug, app có cảnh báo. |
| **Fractal** | Khám phá Mandelbrot ở độ phân giải màn hình (tối đa 1200 px). Chạm để zoom vào, nhấn giữ để zoom ra, chỉnh số vòng lặp, đổi engine Rust hoặc Dart và xem số ms. Render chạy trên isolate nền với non-leaf call, nên UI luôn mượt. |
| **Live blur** | Ảnh 1280×800 (chính ảnh này cũng do Rust render), blur ngay trên UI thread mỗi lần kéo slider. Màn hình hiện số ms mỗi frame so với budget 16.7 ms. Vòng xoay tiến trình đứng hình nghĩa là UI thread đang bị chặn. |

Chạy:

```sh
cd examples/fast_rust_demo
flutter run --profile      # số đo đại diện; dùng --release để trải nghiệm thật
```

## 10. Test và benchmark

| Lệnh | Kiểm tra gì |
|---|---|
| `cd packages/fast_rust/rust && cargo test --release` | 11 test Rust: vector NIST của SHA-256, blur khớp bản naive O(r²) kể cả radius lớn hơn ảnh, bản song song khớp bản tuần tự, NaN, sàng nguyên tố, FFI từ chối null và kích thước sai. |
| `cd packages/fast_rust && dart test` | 22 test: Rust khớp `package:crypto` và `DartReference` từng bit, view có offset, validation, các bản async non-leaf, thứ tự NaN, giới hạn luồng không đổi kết quả. |
| `cd examples/fast_rust_demo && flutter test` | 5 test: Rust load được trong `flutter test`, trang build lazy, fractal render qua isolate, live blur render frame, ca benchmark chạy được. |
| `dart run benchmark/benchmark.dart` | Bảng so sánh Dart, Rust 1T và Rust nT. |

Kiểm tra lint: `cargo clippy --release --all-targets`, `dart analyze`,
`flutter analyze`.

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
