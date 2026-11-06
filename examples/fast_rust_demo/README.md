# fast_rust_demo

App Flutter chứng minh hiệu năng của [`fast_rust`](../../packages/fast_rust):

- **Benchmark**: chạy Dart và Rust cạnh nhau trên isolate nền, hiện hệ số
  nhanh hơn.
- **Fractal**: khám phá Mandelbrot, chạm để zoom, đổi engine Rust hoặc Dart.
- **Live blur**: blur ảnh 1280×800 ngay trên UI thread theo slider, so với
  budget 16.7 ms của một frame.

```sh
flutter pub get
flutter test
flutter run --profile     # hoặc --release; bản debug chạy Dart ở chế độ JIT
```

Cần Rust cùng target của thiết bị. Xem mục *Yêu cầu* trong
[README gốc](../../README.md#3-yêu-cầu).
