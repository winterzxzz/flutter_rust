//! Mandelbrot renderer.

use crate::parallel::for_each_row_band;

/// Largest accepted iteration cap.
pub const MAX_ITERATIONS: u32 = 1 << 20;

/// Viewport: `scale` is the width of one pixel in the complex plane.
pub struct View {
    pub width: usize,
    pub height: usize,
    pub center_x: f64,
    pub center_y: f64,
    pub scale: f64,
    pub max_iter: u32,
}

/// Escape-time iteration count for `c = cx + i*cy`, capped at `max_iter`.
#[inline(always)]
pub fn escape_time(cx: f64, cy: f64, max_iter: u32) -> u32 {
    let (mut x, mut y, mut x2, mut y2) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
    let mut i = 0;
    while i < max_iter && x2 + y2 <= 4.0 {
        y = 2.0 * x * y + cy;
        x = x2 - y2 + cx;
        x2 = x * x;
        y2 = y * y;
        i += 1;
    }
    i
}

/// Maps an iteration count to RGBA with a smooth polynomial palette.
/// Points inside the set are opaque black.
#[inline(always)]
pub fn color(iter: u32, max_iter: u32) -> [u8; 4] {
    if iter >= max_iter {
        return [0, 0, 0, 255];
    }
    let t = iter as f64 / max_iter as f64;
    let u = 1.0 - t;
    let r = 9.0 * u * t * t * t * 255.0;
    let g = 15.0 * u * u * t * t * 255.0;
    let b = 8.5 * u * u * u * t * 255.0;
    [r as u8, g as u8, b as u8, 255]
}

/// Renders `view` into `out` (`width * height * 4` bytes), rows in parallel.
pub fn mandelbrot_rgba(out: &mut [u8], view: &View) {
    let stride = view.width * 4;
    let x0 = view.center_x - view.scale * view.width as f64 / 2.0;
    let y0 = view.center_y - view.scale * view.height as f64 / 2.0;
    for_each_row_band(out, stride, 1, |first_row, band| {
        for (r, row) in band.chunks_exact_mut(stride).enumerate() {
            let cy = y0 + (first_row + r) as f64 * view.scale;
            for (x, px) in row.as_chunks_mut::<4>().0.iter_mut().enumerate() {
                let cx = x0 + x as f64 * view.scale;
                *px = color(escape_time(cx, cy, view.max_iter), view.max_iter);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_points() {
        assert_eq!(escape_time(0.0, 0.0, 500), 500); // inside
        assert_eq!(escape_time(-1.0, 0.0, 500), 500); // period-2 bulb
        assert!(escape_time(2.0, 2.0, 500) <= 1); // far outside
    }

    #[test]
    fn parallel_matches_serial() {
        let view = View { width: 333, height: 211, center_x: -0.5, center_y: 0.0, scale: 0.01, max_iter: 200 };
        let mut out = vec![0u8; 333 * 211 * 4];
        mandelbrot_rgba(&mut out, &view);
        let x0 = -0.5 - 0.01 * 333.0 / 2.0;
        let y0 = 0.0 - 0.01 * 211.0 / 2.0;
        for y in (0..211).step_by(17) {
            for x in (0..333).step_by(13) {
                let want = color(escape_time(x0 + x as f64 * 0.01, y0 + y as f64 * 0.01, 200), 200);
                assert_eq!(&out[(y * 333 + x) * 4..][..4], &want);
            }
        }
    }
}
