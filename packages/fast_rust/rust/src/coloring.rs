//! Pixel-art coloring: page generation and scanline flood fill.

use crate::parallel::{for_each_band_of, for_each_row_band, thread_count};

/// Largest accepted number of regions on a coloring page.
pub const MAX_CELLS: u32 = 65_536;
/// Largest accepted pixel-block size on a coloring page.
pub const MAX_BLOCK: u32 = 256;
/// Largest accepted `grid squares × cells` (the brute-force Voronoi cost):
/// about a second of work on a phone.
pub const MAX_PAGE_WORK: u64 = 1 << 31;

/// `grid squares × cells` for a page, used to bound its cost.
pub fn page_work(width: usize, height: usize, cells: usize, block: usize) -> u64 {
    let squares = width.div_ceil(block) as u64 * height.div_ceil(block) as u64;
    squares.saturating_mul(cells as u64)
}

const OUTLINE: [u8; 4] = [0, 0, 0, 255];
const PAPER: [u8; 4] = [255, 255, 255, 255];

/// xorshift64, shared bit-for-bit with the Dart reference.
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng((seed ^ 0x9E37_79B9_7F4A_7C15) | 1)
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    /// Uniform-ish value in `0..n` (`n > 0`).
    pub fn below(&mut self, n: usize) -> usize {
        ((self.next_u64() >> 1) % n as u64) as usize
    }
}

/// Renders a coloring page: `cells` Voronoi regions on a grid of
/// `block`×`block` pixel squares, white regions with 1-square black outlines
/// and a black frame. Labels and pixels are computed in parallel.
pub fn coloring_page_rgba(
    out: &mut [u8],
    width: usize,
    height: usize,
    cells: usize,
    block: usize,
    seed: u64,
) {
    if width == 0 || height == 0 {
        return;
    }
    let gw = width.div_ceil(block);
    let gh = height.div_ceil(block);
    let mut rng = Rng::new(seed);
    let seeds: Vec<(i64, i64)> = (0..cells.max(1))
        .map(|_| (rng.below(gw) as i64, rng.below(gh) as i64))
        .collect();

    // Nearest seed per grid square (ties go to the lower index). Each square
    // costs `cells` distance checks, so give every thread several bands even
    // on a small grid.
    let mut labels = vec![0u32; gw * gh];
    let band_rows = gh.div_ceil(thread_count() * 4);
    for_each_band_of(&mut labels, gw, band_rows, |first_row, band| {
        for (r, row) in band.chunks_exact_mut(gw).enumerate() {
            let gy = (first_row + r) as i64;
            for (gx, label) in row.iter_mut().enumerate() {
                let gx = gx as i64;
                let mut best = (i64::MAX, 0u32);
                for (i, &(sx, sy)) in seeds.iter().enumerate() {
                    let d = (sx - gx) * (sx - gx) + (sy - gy) * (sy - gy);
                    if d < best.0 {
                        best = (d, i as u32);
                    }
                }
                *label = best.1;
            }
        }
    });

    let labels = &labels;
    let outline = |gx: usize, gy: usize| {
        let l = labels[gy * gw + gx];
        gx == 0
            || gy == 0
            || gx + 1 == gw
            || gy + 1 == gh
            || labels[gy * gw + gx + 1] != l
            || labels[(gy + 1) * gw + gx] != l
    };
    let stride = width * 4;
    for_each_row_band(out, stride, 1, |first_row, band| {
        for (r, row) in band.chunks_exact_mut(stride).enumerate() {
            let gy = (first_row + r) / block;
            for (x, px) in row.as_chunks_mut::<4>().0.iter_mut().enumerate() {
                *px = if outline(x / block, gy) { OUTLINE } else { PAPER };
            }
        }
    });
}

/// Flood-fills the 4-connected region around `(x, y)` whose pixels are
/// within `tolerance` (per channel) of the seed pixel, painting `color`.
/// Returns the number of pixels painted. Scanline algorithm.
pub fn flood_fill_rgba(
    rgba: &mut [u8],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    color: [u8; 4],
    tolerance: u8,
) -> u64 {
    let px = rgba.as_chunks_mut::<4>().0;
    let target = px[y * width + x];
    if tolerance == 0 {
        if target == color {
            return 0;
        }
        // Exact match: painted pixels stop matching, so no visited map.
        scanline(px, width, height, x, y, color, |p, _| *p == target, |_| {})
    } else {
        let tol = tolerance as i16;
        let near = |p: &[u8; 4]| (0..4).all(|c| (p[c] as i16 - target[c] as i16).abs() <= tol);
        // `color` may itself be within tolerance: track visited pixels.
        let visited = std::cell::RefCell::new(vec![0u64; (width * height).div_ceil(64)]);
        scanline(
            px,
            width,
            height,
            x,
            y,
            color,
            |p, i| visited.borrow()[i >> 6] & (1 << (i & 63)) == 0 && near(p),
            |i| visited.borrow_mut()[i >> 6] |= 1 << (i & 63),
        )
    }
}

/// Generic scanline fill. `fillable(pixel, index)` decides membership;
/// `mark(index)` is called for every painted pixel.
#[allow(clippy::too_many_arguments)]
#[inline(always)]
fn scanline(
    px: &mut [[u8; 4]],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    color: [u8; 4],
    fillable: impl Fn(&[u8; 4], usize) -> bool,
    mark: impl Fn(usize),
) -> u64 {
    // Pixel indices as u32 (callers guarantee width * height <= u32::MAX):
    // 4 bytes per pending run start keeps the worst case small.
    let mut stack = vec![(y * width + x) as u32];
    let mut painted = 0u64;
    while let Some(i) = stack.pop() {
        let (x, y) = (i as usize % width, i as usize / width);
        let row = y * width;
        if !fillable(&px[row + x], row + x) {
            continue;
        }
        let mut lx = x;
        while lx > 0 && fillable(&px[row + lx - 1], row + lx - 1) {
            lx -= 1;
        }
        let mut rx = x;
        while rx + 1 < width && fillable(&px[row + rx + 1], row + rx + 1) {
            rx += 1;
        }
        for i in row + lx..=row + rx {
            mark(i);
        }
        px[row + lx..=row + rx].fill(color);
        painted += (rx - lx + 1) as u64;

        // Queue the start of every fillable run in the rows above and below.
        for ny in [y.wrapping_sub(1), y + 1] {
            if ny >= height {
                continue;
            }
            let nrow = ny * width;
            let mut in_run = false;
            for i in lx..=rx {
                let m = fillable(&px[nrow + i], nrow + i);
                if m && !in_run {
                    stack.push((nrow + i) as u32);
                }
                in_run = m;
            }
        }
    }
    painted
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    /// Plain BFS reference with the same matching rule.
    fn naive_fill(rgba: &mut [u8], w: usize, h: usize, x: usize, y: usize, color: [u8; 4], tol: u8) -> u64 {
        let target: [u8; 4] = rgba[(y * w + x) * 4..][..4].try_into().unwrap();
        if tol == 0 && target == color {
            return 0;
        }
        let near = |p: &[u8]| (0..4).all(|c| (p[c] as i16 - target[c] as i16).abs() <= tol as i16);
        let mut seen = vec![false; w * h];
        let mut q = VecDeque::from([(x, y)]);
        seen[y * w + x] = true;
        let mut n = 0;
        while let Some((x, y)) = q.pop_front() {
            rgba[(y * w + x) * 4..][..4].copy_from_slice(&color);
            n += 1;
            let mut push = |nx: usize, ny: usize, rgba: &[u8]| {
                if !seen[ny * w + nx] && near(&rgba[(ny * w + nx) * 4..][..4]) {
                    seen[ny * w + nx] = true;
                    q.push_back((nx, ny));
                }
            };
            if x > 0 { push(x - 1, y, rgba); }
            if x + 1 < w { push(x + 1, y, rgba); }
            if y > 0 { push(x, y - 1, rgba); }
            if y + 1 < h { push(x, y + 1, rgba); }
        }
        n
    }

    fn page(w: usize, h: usize, cells: usize, block: usize, seed: u64) -> Vec<u8> {
        let mut out = vec![0u8; w * h * 4];
        coloring_page_rgba(&mut out, w, h, cells, block, seed);
        out
    }

    #[test]
    fn fill_matches_bfs_on_coloring_pages() {
        for &(w, h, cells, block) in &[(64, 48, 12, 2), (200, 150, 40, 4), (97, 61, 9, 1)] {
            let base = page(w, h, cells, block, 7);
            let mut rng = Rng::new(3);
            for _ in 0..25 {
                let (x, y) = (rng.below(w), rng.below(h));
                let color = [rng.below(256) as u8, 40, 200, 255];
                let mut a = base.clone();
                let mut b = base.clone();
                let na = flood_fill_rgba(&mut a, w, h, x, y, color, 0);
                let nb = naive_fill(&mut b, w, h, x, y, color, 0);
                assert_eq!(na, nb);
                assert_eq!(a, b, "{w}x{h} at ({x},{y})");
            }
        }
    }

    #[test]
    fn fill_with_tolerance_and_same_color() {
        // Gradient row: tolerance decides how far the fill spreads.
        let w = 20;
        let mut img: Vec<u8> = (0..w).flat_map(|i| [i as u8 * 10, 0, 0, 255]).collect();
        let mut naive = img.clone();
        let n = flood_fill_rgba(&mut img, w, 1, 0, 0, [5, 0, 0, 255], 25);
        assert_eq!(n, naive_fill(&mut naive, w, 1, 0, 0, [5, 0, 0, 255], 25));
        assert_eq!(n, 3); // values 0, 10, 20 are within 25 of 0
        assert_eq!(img, naive);
        // Filling with the region's own colour is a no-op.
        assert_eq!(flood_fill_rgba(&mut img, w, 1, 10, 0, [100, 0, 0, 255], 0), 0);
    }

    #[test]
    fn page_has_frame_and_regions() {
        let (w, h) = (64, 40);
        let p = page(w, h, 10, 4, 1);
        assert_eq!(&p[..4], &OUTLINE); // frame
        let white = p.as_chunks::<4>().0.iter().filter(|px| **px == PAPER).count();
        assert!(white > w * h / 3, "mostly paper");
        // Same seed, same page; different seed, different page.
        assert_eq!(p, page(w, h, 10, 4, 1));
        assert_ne!(p, page(w, h, 10, 4, 2));
    }
}
