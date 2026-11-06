//! RGBA8888 image filters.

use crate::parallel::{for_each_row_band, thread_count};

/// Largest accepted blur radius. Keeps window sums far from `u32` overflow
/// (255 * 2049) and bounds worst-case cost.
pub const MAX_BLUR_RADIUS: usize = 1024;

/// In-place grayscale using integer BT.601 luma weights (77, 150, 29) / 256.
pub fn grayscale_rgba(rgba: &mut [u8]) {
    for_each_row_band(rgba, 4, 1, |_, band| {
        for px in band.as_chunks_mut::<4>().0 {
            let y = (77 * px[0] as u32 + 150 * px[1] as u32 + 29 * px[2] as u32 + 128) >> 8;
            let y = y as u8;
            px[0] = y;
            px[1] = y;
            px[2] = y;
        }
    });
}

/// Separable box blur with clamped edges. Each pass keeps a running window
/// sum and counts edge-clamped samples by multiplication, so total cost is
/// O(pixels) independent of `radius`.
/// Rows are processed in parallel. `radius` is clamped to [`MAX_BLUR_RADIUS`].
pub fn box_blur_rgba(rgba: &mut [u8], width: usize, height: usize, radius: usize) {
    let radius = radius.min(MAX_BLUR_RADIUS);
    if radius == 0 || width == 0 || height == 0 {
        return;
    }
    let stride = width * 4;
    let diameter = (2 * radius + 1) as u32;
    let half = diameter / 2;
    let mut tmp = vec![0u8; rgba.len()];

    // Horizontal pass: rgba -> tmp, one row at a time.
    {
        let src: &[u8] = rgba;
        for_each_row_band(&mut tmp, stride, 1, |first_row, band| {
            for (r, out) in band.chunks_exact_mut(stride).enumerate() {
                let y = first_row + r;
                let row = &src[y * stride..(y + 1) * stride];
                blur_line(row, out, width, 4, radius, diameter, half);
            }
        });
    }

    // Vertical pass: tmp -> rgba. Each band keeps per-column window sums and
    // pays an O(radius) setup, so use one tall band per thread.
    let src: &[u8] = &tmp;
    let band_rows = height.div_ceil(thread_count());
    for_each_row_band(rgba, stride, band_rows, |first_row, band| {
        let rows = band.len() / stride;
        let last = height - 1;
        // Window rows first_row-radius ..= first_row+radius, clamped. Rows
        // clamped to an edge are counted by multiplication, so setup is
        // O(min(diameter, height)) rows rather than O(radius).
        let mut sums = vec![0u32; stride];
        let lo = first_row.saturating_sub(radius);
        let hi = (first_row + radius).min(last);
        let below = radius.saturating_sub(first_row) as u32;
        let above = (first_row + radius).saturating_sub(last) as u32;
        let (top, bottom) = (&src[..stride], &src[last * stride..]);
        for (i, s) in sums.iter_mut().enumerate() {
            *s = top[i] as u32 * below + bottom[i] as u32 * above;
        }
        for y in lo..=hi {
            let row = &src[y * stride..(y + 1) * stride];
            for (s, &v) in sums.iter_mut().zip(row) {
                *s += v as u32;
            }
        }
        for r in 0..rows {
            let y = first_row + r;
            let out = &mut band[r * stride..(r + 1) * stride];
            for (o, &s) in out.iter_mut().zip(&sums) {
                *o = ((s + half) / diameter) as u8;
            }
            let add_y = (y + radius + 1).min(last);
            let sub_y = y.saturating_sub(radius);
            let add = &src[add_y * stride..(add_y + 1) * stride];
            let sub = &src[sub_y * stride..(sub_y + 1) * stride];
            for ((s, &a), &b) in sums.iter_mut().zip(add).zip(sub) {
                *s = *s + a as u32 - b as u32;
            }
        }
    });
}

/// 1-D running-sum blur over `n` pixels of `channels` interleaved bytes.
#[inline]
fn blur_line(
    src: &[u8],
    out: &mut [u8],
    n: usize,
    channels: usize,
    radius: usize,
    diameter: u32,
    half: u32,
) {
    let last = n - 1;
    for c in 0..channels {
        let at = |i: usize| src[i.min(last) * channels + c] as u32;
        // Window for x = 0 covers [-radius, radius], clamped to the edges;
        // clamped pixels are counted by multiplication.
        let inside = radius.min(last);
        let mut sum = at(0) * radius as u32 + at(last) * (radius - inside) as u32;
        for i in 0..=inside {
            sum += at(i);
        }
        for x in 0..n {
            out[x * channels + c] = ((sum + half) / diameter) as u8;
            sum = sum + at(x + radius + 1) - at(x.saturating_sub(radius));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Straightforward O(radius^2) reference with the same clamping rule.
    fn naive_blur(src: &[u8], w: usize, h: usize, r: usize) -> Vec<u8> {
        let d = (2 * r + 1) as u32;
        let clamp = |v: isize, max: usize| v.clamp(0, max as isize - 1) as usize;
        let mut tmp = vec![0u8; src.len()];
        for y in 0..h {
            for x in 0..w {
                for c in 0..4 {
                    let s: u32 = (-(r as isize)..=r as isize)
                        .map(|k| src[(y * w + clamp(x as isize + k, w)) * 4 + c] as u32)
                        .sum();
                    tmp[(y * w + x) * 4 + c] = ((s + d / 2) / d) as u8;
                }
            }
        }
        let mut out = vec![0u8; src.len()];
        for y in 0..h {
            for x in 0..w {
                for c in 0..4 {
                    let s: u32 = (-(r as isize)..=r as isize)
                        .map(|k| tmp[(clamp(y as isize + k, h) * w + x) * 4 + c] as u32)
                        .sum();
                    out[(y * w + x) * 4 + c] = ((s + d / 2) / d) as u8;
                }
            }
        }
        out
    }

    fn pattern(w: usize, h: usize) -> Vec<u8> {
        (0..w * h * 4)
            .map(|i| ((i * 2654435761usize) >> 7) as u8)
            .collect()
    }

    #[test]
    fn blur_matches_naive() {
        for &(w, h, r) in &[(1, 1, 3), (7, 5, 1), (13, 9, 4), (300, 260, 6), (64, 3, 10), (20, 9, 50), (700, 40, 3), (5, 300, 1024)] {
            let src = pattern(w, h);
            let mut fast = src.clone();
            box_blur_rgba(&mut fast, w, h, r);
            assert_eq!(fast, naive_blur(&src, w, h, r), "{w}x{h} r={r}");
        }
    }

    #[test]
    fn blur_radius_zero_is_identity() {
        let src = pattern(10, 10);
        let mut out = src.clone();
        box_blur_rgba(&mut out, 10, 10, 0);
        assert_eq!(out, src);
    }

    #[test]
    fn grayscale_keeps_alpha() {
        let mut px = vec![255, 0, 0, 7, 0, 255, 0, 9, 10, 20, 30, 255];
        grayscale_rgba(&mut px);
        assert_eq!(px, vec![77, 77, 77, 7, 149, 149, 149, 9, 18, 18, 18, 255]);
    }
}
