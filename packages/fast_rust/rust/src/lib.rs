//! Native core for the `fast_rust` Dart package.
//!
//! Every exported function uses the C ABI, takes raw pointers plus lengths,
//! never allocates memory that crosses the boundary, and returns an `i32`
//! status code (see [`Status`]). This keeps the Dart side zero-copy: Dart
//! passes the address of its own typed data and Rust works on it in place.

pub mod coloring;
pub mod fractal;
pub mod hash;
pub mod image;
pub mod numeric;
mod parallel;

/// Status codes returned by every fallible exported function.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok = 0,
    NullPointer = -1,
    InvalidArgument = -2,
}

/// Builds a shared slice from an FFI pointer. `len == 0` never dereferences.
///
/// # Safety
/// `ptr` must be valid for reads of `len` elements when `len > 0`.
unsafe fn slice<'a, T>(ptr: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    Some(std::slice::from_raw_parts(ptr, len))
}

/// Mutable counterpart of [`slice`].
///
/// # Safety
/// `ptr` must be valid for reads and writes of `len` elements when `len > 0`
/// and must not alias any other live reference.
unsafe fn slice_mut<'a, T>(ptr: *mut T, len: usize) -> Option<&'a mut [T]> {
    if len == 0 {
        return Some(&mut []);
    }
    if ptr.is_null() {
        return None;
    }
    Some(std::slice::from_raw_parts_mut(ptr, len))
}

macro_rules! try_slice {
    ($e:expr) => {
        match $e {
            Some(s) => s,
            None => return Status::NullPointer as i32,
        }
    };
}

/// ABI version, bumped on any breaking change to the exported functions.
#[no_mangle]
pub extern "C" fn fr_abi_version() -> u32 {
    1
}

/// Trivial function used to measure the raw cost of one FFI call.
#[no_mangle]
pub extern "C" fn fr_add_i64(a: i64, b: i64) -> i64 {
    a.wrapping_add(b)
}

/// Number of worker threads Rust uses for parallel functions.
#[no_mangle]
pub extern "C" fn fr_thread_count() -> u32 {
    parallel::thread_count() as u32
}

/// Caps worker threads for all later calls; `0` restores the default.
#[no_mangle]
pub extern "C" fn fr_set_thread_limit(limit: u32) {
    parallel::set_thread_limit(limit as usize);
}

/// SHA-256 of `data[0..len]`, written into `out[0..32]`.
///
/// # Safety
/// `data` valid for `len` bytes, `out` valid for 32 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fr_sha256(data: *const u8, len: usize, out: *mut u8) -> i32 {
    let data = try_slice!(slice(data, len));
    let out = try_slice!(slice_mut(out, 32));
    out.copy_from_slice(&hash::sha256(data));
    Status::Ok as i32
}

/// Converts an RGBA8888 buffer to grayscale in place (alpha untouched).
///
/// # Safety
/// `rgba` valid for `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fr_grayscale_rgba(rgba: *mut u8, len: usize) -> i32 {
    if !len.is_multiple_of(4) {
        return Status::InvalidArgument as i32;
    }
    let rgba = try_slice!(slice_mut(rgba, len));
    image::grayscale_rgba(rgba);
    Status::Ok as i32
}

/// Box blur of an RGBA8888 image in place, multi-threaded; O(pixels)
/// regardless of `radius`. `radius > MAX_BLUR_RADIUS` is rejected.
///
/// # Safety
/// `rgba` valid for `width * height * 4` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fr_box_blur_rgba(
    rgba: *mut u8,
    width: u32,
    height: u32,
    radius: u32,
) -> i32 {
    if radius as usize > image::MAX_BLUR_RADIUS {
        return Status::InvalidArgument as i32;
    }
    let Some(len) = (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(4))
    else {
        return Status::InvalidArgument as i32;
    };
    let rgba = try_slice!(slice_mut(rgba, len));
    image::box_blur_rgba(rgba, width as usize, height as usize, radius as usize);
    Status::Ok as i32
}

/// Renders the Mandelbrot set into an RGBA8888 buffer, multi-threaded.
///
/// # Safety
/// `out` valid for `width * height * 4` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fr_mandelbrot_rgba(
    out: *mut u8,
    width: u32,
    height: u32,
    center_x: f64,
    center_y: f64,
    scale: f64,
    max_iter: u32,
) -> i32 {
    if max_iter == 0
        || max_iter > fractal::MAX_ITERATIONS
        || !scale.is_finite()
        || scale <= 0.0
        || !center_x.is_finite()
        || !center_y.is_finite()
    {
        return Status::InvalidArgument as i32;
    }
    let Some(len) = (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(4))
    else {
        return Status::InvalidArgument as i32;
    };
    let out = try_slice!(slice_mut(out, len));
    let view = fractal::View {
        width: width as usize,
        height: height as usize,
        center_x,
        center_y,
        scale,
        max_iter,
    };
    fractal::mandelbrot_rgba(out, &view);
    Status::Ok as i32
}

/// Renders a pixel-art coloring page (`cells` regions on `block`-pixel
/// squares) into an RGBA8888 buffer.
///
/// # Safety
/// `out` valid for `width * height * 4` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fr_coloring_page_rgba(
    out: *mut u8,
    width: u32,
    height: u32,
    cells: u32,
    block: u32,
    seed: u64,
) -> i32 {
    if cells == 0
        || cells > coloring::MAX_CELLS
        || block == 0
        || block > coloring::MAX_BLOCK
        || coloring::page_work(width as usize, height as usize, cells as usize, block as usize)
            > coloring::MAX_PAGE_WORK
    {
        return Status::InvalidArgument as i32;
    }
    let Some(len) = (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(4))
    else {
        return Status::InvalidArgument as i32;
    };
    let out = try_slice!(slice_mut(out, len));
    coloring::coloring_page_rgba(
        out,
        width as usize,
        height as usize,
        cells as usize,
        block as usize,
        seed,
    );
    Status::Ok as i32
}

/// Flood-fills the region around `(x, y)` with `color` (`0xRRGGBBAA`).
/// Returns the number of painted pixels, or a negative [`Status`].
///
/// # Safety
/// `rgba` valid for `width * height * 4` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fr_flood_fill_rgba(
    rgba: *mut u8,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    color: u32,
    tolerance: u32,
) -> i64 {
    if x >= width || y >= height || tolerance > 255 || width as u64 * height as u64 > u32::MAX as u64 {
        return Status::InvalidArgument as i64;
    }
    let Some(len) = (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(4))
    else {
        return Status::InvalidArgument as i64;
    };
    let Some(rgba) = slice_mut(rgba, len) else {
        return Status::NullPointer as i64;
    };
    coloring::flood_fill_rgba(
        rgba,
        width as usize,
        height as usize,
        x as usize,
        y as usize,
        color.to_be_bytes(),
        tolerance as u8,
    ) as i64
}

/// Sorts `data[0..len]` ascending in place using IEEE-754 total order.
///
/// # Safety
/// `data` valid for `len` writable `f64`s.
#[no_mangle]
pub unsafe extern "C" fn fr_sort_f64(data: *mut f64, len: usize) -> i32 {
    let data = try_slice!(slice_mut(data, len));
    numeric::sort_f64(data);
    Status::Ok as i32
}

/// Number of primes `<= limit` (sieve of Eratosthenes), or `u64::MAX` if
/// `limit > MAX_PRIME_LIMIT` or the sieve cannot be allocated.
#[no_mangle]
pub extern "C" fn fr_count_primes(limit: u64) -> u64 {
    numeric::count_primes(limit).unwrap_or(u64::MAX)
}

/// Dot product of two `f64` vectors of length `len`.
///
/// # Safety
/// `a` and `b` valid for `len` `f64`s each. `out` valid for one write.
#[no_mangle]
pub unsafe extern "C" fn fr_dot_f64(a: *const f64, b: *const f64, len: usize, out: *mut f64) -> i32 {
    let a = try_slice!(slice(a, len));
    let b = try_slice!(slice(b, len));
    if out.is_null() {
        return Status::NullPointer as i32;
    }
    *out = numeric::dot_f64(a, b);
    Status::Ok as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_rejects_null_and_bad_sizes() {
        unsafe {
            let mut out = [0u8; 32];
            assert_eq!(fr_sha256(std::ptr::null(), 4, out.as_mut_ptr()), -1);
            assert_eq!(fr_sha256(std::ptr::null(), 0, out.as_mut_ptr()), 0);
            let mut px = [0u8; 6];
            assert_eq!(fr_grayscale_rgba(px.as_mut_ptr(), 6), -2);
            assert_eq!(
                fr_mandelbrot_rgba(std::ptr::null_mut(), 1, 1, 0.0, 0.0, 1.0, 0),
                -2
            );
            assert_eq!(
                fr_box_blur_rgba(std::ptr::null_mut(), u32::MAX, u32::MAX, 1),
                -2
            );
            assert_eq!(fr_box_blur_rgba(std::ptr::null_mut(), 2, 2, 1), -1);
            assert_eq!(fr_box_blur_rgba(px.as_mut_ptr(), 1, 1, 1025), -2);
            assert_eq!(
                fr_mandelbrot_rgba(px.as_mut_ptr(), 1, 1, 0.0, 0.0, 1.0, u32::MAX),
                -2
            );
        }
        assert_eq!(fr_add_i64(i64::MAX, 1), i64::MIN);
        assert!(fr_thread_count() >= 1);
        assert_eq!(fr_count_primes(u64::MAX), u64::MAX);
        unsafe {
            let mut px = [255u8; 16];
            assert_eq!(fr_flood_fill_rgba(px.as_mut_ptr(), 2, 2, 2, 0, 0, 0), -2);
            assert_eq!(fr_flood_fill_rgba(std::ptr::null_mut(), 2, 2, 0, 0, 0, 0), -1);
            assert_eq!(fr_flood_fill_rgba(px.as_mut_ptr(), 2, 2, 0, 0, 0xFF0000FF, 0), 4);
            assert_eq!(&px[..4], &[255, 0, 0, 255]);
            assert_eq!(fr_coloring_page_rgba(px.as_mut_ptr(), 2, 2, 0, 1, 0), -2);
            // 4096x4096 squares x 65536 cells is far beyond the work cap.
            assert_eq!(
                fr_coloring_page_rgba(std::ptr::null_mut(), 4096, 4096, 65536, 1, 0),
                -2
            );
        }
    }
}
