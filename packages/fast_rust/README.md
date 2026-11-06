# fast_rust

Các kernel hiệu năng cao viết bằng Rust cho Dart và Flutter, nạp qua
*native assets* (build hook tự gọi `cargo`) và gọi FFI zero-copy.

```dart
import 'package:fast_rust/fast_rust.dart';

final digest = FastRust.sha256(bytes);
FastRust.boxBlurRgba(pixels, width: w, height: h, radius: 8);
final img = await FastRust.mandelbrotRgbaAsync(width: 800, height: 600, scale: 3 / 800);
```

Cần Rust ≥ 1.88 cùng target của nền tảng đích (`rustup target add …`).

Tài liệu đầy đủ (API, quy tắc leaf/non-leaf, kiến trúc, benchmark, cách thêm
hàm mới) nằm ở [README gốc của repo](../../README.md).

```sh
dart test                              # test đúng/sai
(cd rust && cargo test --release)      # test Rust
dart run benchmark/benchmark.dart      # benchmark
```
