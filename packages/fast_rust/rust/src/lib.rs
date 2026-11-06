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
pub mod lineart;
pub mod numeric;
pub mod raytrace;
pub mod sand;
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

/// Whether the byte ranges `[a, a + a_len)` and `[b, b + b_len)` overlap.
fn overlaps(a: usize, a_len: usize, b: usize, b_len: usize) -> bool {
    a_len > 0 && b_len > 0 && a < b.wrapping_add(b_len) && b < a.wrapping_add(a_len)
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

/// Recolours the region of `src` around `(x, y)` (RGB within `tolerance`
/// of the seed pixel) into `dst`, keeping each pixel's luminance. `color` is
/// `0xRRGGBBAA` (alpha ignored), `strength` 0..=255. Returns the number of
/// written pixels, or a negative [`Status`]. `src` and `dst` must not overlap.
///
/// # Safety
/// `src` valid for `width * height * 4` bytes, `dst` valid for as many
/// writable bytes, and the two ranges disjoint.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fr_recolor_region_rgba(
    src: *const u8,
    dst: *mut u8,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    color: u32,
    tolerance: u32,
    strength: u32,
) -> i64 {
    if x >= width
        || y >= height
        || tolerance > 255
        || strength > 255
        || width as u64 * height as u64 > u32::MAX as u64
    {
        return Status::InvalidArgument as i64;
    }
    let Some(len) = (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(4))
    else {
        return Status::InvalidArgument as i64;
    };
    if overlaps(src as usize, len, dst as usize, len) {
        return Status::InvalidArgument as i64; // overlapping buffers
    }
    let Some(src) = slice(src, len) else {
        return Status::NullPointer as i64;
    };
    let Some(dst) = slice_mut(dst, len) else {
        return Status::NullPointer as i64;
    };
    coloring::recolor_region_rgba(
        src,
        dst,
        width as usize,
        height as usize,
        x as usize,
        y as usize,
        color.to_be_bytes(),
        tolerance as u8,
        strength as u8,
    ) as i64
}

/// Spreading fill, step 1: geodesic distances from `(x, y)` over the
/// region of `src` within `tolerance` of the seed (see
/// [`coloring::spread_distances`]) into `dist[0..width*height]`. Returns the
/// largest distance, or a negative [`Status`].
///
/// # Safety
/// `src` valid for `width * height * 4` bytes, `dist` for `width * height`
/// writable `u32`s.
#[no_mangle]
pub unsafe extern "C" fn fr_spread_distances(
    src: *const u8,
    dist: *mut u32,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    tolerance: u32,
) -> i64 {
    // Distances reach at most DIAGONAL_STEP * (pixels - 1); keep them below
    // UNREACHED so they never overflow u32.
    if x >= width
        || y >= height
        || tolerance > 255
        || width as u64 * height as u64 > coloring::MAX_SPREAD_PIXELS
    {
        return Status::InvalidArgument as i64;
    }
    let n = width as usize * height as usize;
    let Some(len) = n.checked_mul(4) else {
        return Status::InvalidArgument as i64;
    };
    if overlaps(src as usize, len, dist as usize, len) {
        return Status::InvalidArgument as i64; // dist aliases the image
    }
    let Some(src) = slice(src, len) else {
        return Status::NullPointer as i64;
    };
    let Some(dist) = slice_mut(dist, n) else {
        return Status::NullPointer as i64;
    };
    coloring::spread_distances(src, dist, width as usize, height as usize, x as usize, y as usize, tolerance as u8)
        as i64
}

/// Spreading fill, step 2: paints the pixels with `from <= dist < to` into
/// `dst`, flat `color` or (with `tint != 0`) a luminance-preserving tint of
/// `src`. Returns the number of painted pixels, or a negative [`Status`].
///
/// # Safety
/// `src` valid for `width * height * 4` bytes, `dst` for as many writable
/// bytes (disjoint from `src`), `dist` for `width * height` `u32`s.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fr_paint_by_distance(
    src: *const u8,
    dst: *mut u8,
    dist: *const u32,
    width: u32,
    height: u32,
    from: u32,
    to: u32,
    color: u32,
    strength: u32,
    tint: u32,
) -> i64 {
    if strength > 255 {
        return Status::InvalidArgument as i64;
    }
    let Some(n) = (width as usize).checked_mul(height as usize) else {
        return Status::InvalidArgument as i64;
    };
    let Some(len) = n.checked_mul(4) else {
        return Status::InvalidArgument as i64;
    };
    // dist is n u32s = len bytes.
    if overlaps(src as usize, len, dst as usize, len) || overlaps(dist as usize, len, dst as usize, len) {
        return Status::InvalidArgument as i64; // aliasing buffers
    }
    let Some(src) = slice(src, len) else {
        return Status::NullPointer as i64;
    };
    let Some(dst) = slice_mut(dst, len) else {
        return Status::NullPointer as i64;
    };
    let Some(dist) = slice(dist, n) else {
        return Status::NullPointer as i64;
    };
    coloring::paint_by_distance(
        src,
        dst,
        dist,
        width as usize,
        from,
        to,
        color.to_be_bytes(),
        strength as u8,
        tint != 0,
    ) as i64
}

/// Photo to coloring page (see [`lineart::photo_to_coloring_page`]).
/// `labels` (`width * height` bytes) and `palette` (`colors * 4` bytes) may
/// be null. Returns a [`Status`].
///
/// # Safety
/// `src` valid for `width * height * 4` bytes; `out` for as many writable
/// bytes; non-null `labels` / `palette` writable for their sizes. No buffer
/// may overlap another.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fr_photo_to_coloring_page(
    src: *const u8,
    out: *mut u8,
    labels: *mut u8,
    palette: *mut u8,
    width: u32,
    height: u32,
    colors: u32,
    smooth: u32,
    min_region: u32,
    line_width: u32,
) -> i32 {
    if colors == 0
        || colors as usize > lineart::MAX_COLORS
        || smooth as usize > lineart::MAX_SMOOTH
        || line_width == 0
        || line_width as usize > lineart::MAX_LINE_WIDTH
        || width as u64 * height as u64 > u32::MAX as u64
    {
        return Status::InvalidArgument as i32;
    }
    let n = width as usize * height as usize;
    let Some(len) = n.checked_mul(4) else {
        return Status::InvalidArgument as i32;
    };
    let pal_len = colors as usize * 4;
    let ranges = [
        (src as usize, len),
        (out as usize, len),
        (labels as usize, if labels.is_null() { 0 } else { n }),
        (palette as usize, if palette.is_null() { 0 } else { pal_len }),
    ];
    for a in 0..ranges.len() {
        for b in a + 1..ranges.len() {
            if overlaps(ranges[a].0, ranges[a].1, ranges[b].0, ranges[b].1) {
                return Status::InvalidArgument as i32;
            }
        }
    }
    let src = try_slice!(slice(src, len));
    let out = try_slice!(slice_mut(out, len));
    let labels = if labels.is_null() { None } else { Some(try_slice!(slice_mut(labels, n))) };
    let palette = if palette.is_null() { None } else { Some(try_slice!(slice_mut(palette, pal_len))) };
    lineart::photo_to_coloring_page(
        src,
        out,
        labels,
        palette,
        width as usize,
        height as usize,
        colors as usize,
        smooth as usize,
        min_region as usize,
        line_width as usize,
    );
    Status::Ok as i32
}

/// Advances a falling-sand grid (`width * height` cells, values below
/// [`sand::MATERIALS`]) by one step. Returns the number of moved particles,
/// or a negative [`Status`].
///
/// # Safety
/// `cells` valid for `width * height` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fr_sand_step(cells: *mut u8, width: u32, height: u32, frame: u32) -> i64 {
    let Some(n) = (width as usize).checked_mul(height as usize) else {
        return Status::InvalidArgument as i64;
    };
    let Some(cells) = slice_mut(cells, n) else {
        return Status::NullPointer as i64;
    };
    if cells.iter().any(|&c| c >= sand::MATERIALS) {
        return Status::InvalidArgument as i64;
    }
    sand::step(cells, width as usize, height as usize, frame) as i64
}

/// Renders a falling-sand grid into RGBA8888 `out`. Returns a [`Status`].
///
/// # Safety
/// `cells` valid for `width * height` bytes, `out` for four times as many
/// writable bytes, not overlapping.
#[no_mangle]
pub unsafe extern "C" fn fr_sand_render_rgba(cells: *const u8, out: *mut u8, width: u32, height: u32) -> i32 {
    let Some(n) = (width as usize).checked_mul(height as usize) else {
        return Status::InvalidArgument as i32;
    };
    let Some(len) = n.checked_mul(4) else {
        return Status::InvalidArgument as i32;
    };
    if overlaps(cells as usize, n, out as usize, len) {
        return Status::InvalidArgument as i32;
    }
    let cells = try_slice!(slice(cells, n));
    let out = try_slice!(slice_mut(out, len));
    sand::render_rgba(cells, out, width as usize);
    Status::Ok as i32
}

/// Path tracing: adds `samples` paths per pixel of the built-in scene to
/// `accum` (`width * height * 3` f64s). `camera` points to
/// [`raytrace::CAMERA_LEN`] f64s. Returns a [`Status`].
///
/// # Safety
/// `accum` valid for `width * height * 3` writable f64s, `camera` for
/// `CAMERA_LEN` f64s, not overlapping.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fr_path_trace(
    accum: *mut f64,
    width: u32,
    height: u32,
    camera: *const f64,
    first_sample: u32,
    samples: u32,
    max_depth: u32,
) -> i32 {
    if samples == 0
        || samples > raytrace::MAX_SAMPLES
        || max_depth == 0
        || max_depth > raytrace::MAX_DEPTH
        || first_sample.checked_add(samples).is_none()
        || width as u64 * height as u64 > u32::MAX as u64
    {
        return Status::InvalidArgument as i32;
    }
    let Some(n) = (width as usize).checked_mul(height as usize).and_then(|n| n.checked_mul(3)) else {
        return Status::InvalidArgument as i32;
    };
    let Some(bytes) = n.checked_mul(8) else {
        return Status::InvalidArgument as i32;
    };
    if overlaps(accum as usize, bytes, camera as usize, raytrace::CAMERA_LEN * 8) {
        return Status::InvalidArgument as i32;
    }
    let cam = try_slice!(slice(camera, raytrace::CAMERA_LEN));
    let Some(cam) = raytrace::Camera::from_slice(cam) else {
        return Status::InvalidArgument as i32;
    };
    let accum = try_slice!(slice_mut(accum, n));
    raytrace::trace(accum, width as usize, height as usize, &cam, first_sample, samples, max_depth);
    Status::Ok as i32
}

/// Writes the average of `sample_count` accumulated samples as RGBA8888
/// (gamma 2). Returns a [`Status`].
///
/// # Safety
/// `accum` valid for `width * height * 3` f64s, `out` for
/// `width * height * 4` writable bytes, not overlapping.
#[no_mangle]
pub unsafe extern "C" fn fr_path_resolve_rgba(
    accum: *const f64,
    out: *mut u8,
    width: u32,
    height: u32,
    sample_count: u32,
) -> i32 {
    let Some(n) = (width as usize).checked_mul(height as usize) else {
        return Status::InvalidArgument as i32;
    };
    let (Some(alen), Some(olen)) = (n.checked_mul(3), n.checked_mul(4)) else {
        return Status::InvalidArgument as i32;
    };
    let Some(abytes) = alen.checked_mul(8) else {
        return Status::InvalidArgument as i32;
    };
    if overlaps(accum as usize, abytes, out as usize, olen) {
        return Status::InvalidArgument as i32;
    }
    let accum = try_slice!(slice(accum, alen));
    let out = try_slice!(slice_mut(out, olen));
    raytrace::resolve_rgba(accum, out, width as usize, sample_count);
    Status::Ok as i32
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
            let src = [255u8; 16];
            assert_eq!(fr_recolor_region_rgba(src.as_ptr(), px.as_mut_ptr(), 2, 2, 0, 0, 0xFF0000FF, 0, 255), 4);
            assert_eq!(fr_recolor_region_rgba(px.as_ptr(), px.as_mut_ptr(), 2, 2, 0, 0, 0, 0, 255), -2);
            assert_eq!(fr_recolor_region_rgba(src.as_ptr(), px.as_mut_ptr(), 2, 2, 0, 0, 0, 0, 256), -2);
            assert_eq!(fr_recolor_region_rgba(std::ptr::null(), px.as_mut_ptr(), 2, 2, 0, 0, 0, 0, 0), -1);
            let mut dist = [0u32; 4];
            assert_eq!(fr_spread_distances(src.as_ptr(), dist.as_mut_ptr(), 2, 2, 0, 0, 0), 7);
            assert_eq!(fr_spread_distances(src.as_ptr(), dist.as_mut_ptr(), 2, 2, 2, 0, 0), -2);
            assert_eq!(fr_spread_distances(src.as_ptr(), std::ptr::null_mut(), 2, 2, 0, 0, 0), -1);
            assert_eq!(fr_paint_by_distance(src.as_ptr(), px.as_mut_ptr(), dist.as_ptr(), 2, 2, 0, 6, 0x01020304, 255, 0), 3);
            assert_eq!(fr_paint_by_distance(px.as_ptr(), px.as_mut_ptr(), dist.as_ptr(), 2, 2, 0, 6, 0, 255, 0), -2);
            // dist aliasing an image buffer is rejected.
            let mut buf = [255u8; 16];
            let p = buf.as_mut_ptr();
            assert_eq!(fr_spread_distances(p, p as *mut u32, 2, 2, 0, 0, 0), -2);
            assert_eq!(fr_paint_by_distance(src.as_ptr(), p, p as *const u32, 2, 2, 0, 6, 0, 255, 0), -2);
            assert_eq!(fr_spread_distances(src.as_ptr(), dist.as_mut_ptr(), 30000, 30000, 0, 0, 0), -2);
            let mut page = [0u8; 16];
            assert_eq!(fr_photo_to_coloring_page(src.as_ptr(), page.as_mut_ptr(), std::ptr::null_mut(), std::ptr::null_mut(), 2, 2, 2, 0, 0, 1), 0);
            assert_eq!(fr_photo_to_coloring_page(src.as_ptr(), page.as_mut_ptr(), std::ptr::null_mut(), std::ptr::null_mut(), 2, 2, 0, 0, 0, 1), -2);
            assert_eq!(fr_photo_to_coloring_page(page.as_ptr(), page.as_mut_ptr(), std::ptr::null_mut(), std::ptr::null_mut(), 2, 2, 2, 0, 0, 1), -2);
            let mut cells = [0u8, 2, 0, 0];
            assert_eq!(fr_sand_step(cells.as_mut_ptr(), 2, 2, 0), 1);
            assert_eq!(cells, [0, 0, 0, 2]);
            let mut bad = [9u8; 4];
            assert_eq!(fr_sand_step(bad.as_mut_ptr(), 2, 2, 0), -2);
            assert_eq!(fr_sand_render_rgba(cells.as_ptr(), page.as_mut_ptr(), 2, 2), 0);
            let mut acc = [0f64; 2 * 2 * 3];
            let mut cam = [0f64; 19];
            cam[2] = 5.0;
            cam[3] = -1.0;
            cam[4] = -1.0;
            cam[6] = 2.0;
            cam[10] = 2.0;
            assert_eq!(fr_path_trace(acc.as_mut_ptr(), 2, 2, cam.as_ptr(), 0, 1, 4), 0);
            assert!(acc.iter().any(|&v| v > 0.0));
            assert_eq!(fr_path_trace(acc.as_mut_ptr(), 2, 2, cam.as_ptr(), 0, 0, 4), -2);
            assert_eq!(fr_path_trace(acc.as_mut_ptr(), 2, 2, cam.as_ptr(), u32::MAX, 1, 4), -2);
            cam[0] = f64::NAN;
            assert_eq!(fr_path_trace(acc.as_mut_ptr(), 2, 2, cam.as_ptr(), 0, 1, 4), -2);
            assert_eq!(fr_path_trace(acc.as_mut_ptr(), 2, 2, std::ptr::null(), 0, 1, 4), -1);
            let mut px = [0u8; 16];
            assert_eq!(fr_path_resolve_rgba(acc.as_ptr(), px.as_mut_ptr(), 2, 2, 1), 0);
            assert_eq!(px[3], 255);
            // 4096x4096 squares x 65536 cells is far beyond the work cap.
            assert_eq!(
                fr_coloring_page_rgba(std::ptr::null_mut(), 4096, 4096, 65536, 1, 0),
                -2
            );
        }
    }
}
