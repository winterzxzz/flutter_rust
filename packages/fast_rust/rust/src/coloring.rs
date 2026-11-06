//! Coloring: pixel-art page generation, scanline flood fill and
//! luminance-preserving photo recolouring.

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

/// Luminance-preserving tint of one pixel: dark pixels stay dark and light
/// pixels stay light, so texture (hair, leaves, fabric) survives the new
/// colour. `strength` 0..=255 blends from the source to the full tint.
/// Integer-only, so the Dart reference matches bit for bit.
#[inline(always)]
pub fn tint_pixel(src: [u8; 4], color: [u8; 4], strength: u8) -> [u8; 4] {
    let l = (77 * src[0] as u32 + 150 * src[1] as u32 + 29 * src[2] as u32) >> 8;
    let s = strength as u32;
    let mut out = src;
    for c in 0..3 {
        let k = color[c] as u32;
        let shaded = if l < 128 {
            k * l / 127
        } else {
            k + (255 - k) * (l - 128) / 127
        }
        .min(255);
        let v = src[c] as u32;
        out[c] = ((v * (255 - s) + shaded * s + 127) / 255) as u8;
    }
    out
}

/// Photo recolouring ("magic wand" + tint): selects the 4-connected region
/// of `src` around `(x, y)` whose RGB is within `tolerance` (per channel) of
/// the seed pixel, then writes [`tint_pixel`] of every selected source pixel
/// into `dst` with `color`. `src` is never modified, so repeated taps always
/// select against the original photo. Returns the number of pixels written.
#[allow(clippy::too_many_arguments)]
pub fn recolor_region_rgba(
    src: &[u8],
    dst: &mut [u8],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    color: [u8; 4],
    tolerance: u8,
    strength: u8,
) -> u64 {
    let src = src.as_chunks::<4>().0;
    let dst = dst.as_chunks_mut::<4>().0;
    let seed = src[y * width + x];
    let tol = tolerance as i16;
    let near = |p: &[u8; 4]| (0..3).all(|c| (p[c] as i16 - seed[c] as i16).abs() <= tol);
    let mut visited = vec![0u64; (width * height).div_ceil(64)];
    let mut stack = vec![(y * width + x) as u32];
    let mut painted = 0u64;
    macro_rules! fillable {
        ($i:expr) => {{
            let i = $i;
            visited[i >> 6] & (1 << (i & 63)) == 0 && near(&src[i])
        }};
    }
    while let Some(i) = stack.pop() {
        let (x, y) = (i as usize % width, i as usize / width);
        let row = y * width;
        if !fillable!(row + x) {
            continue;
        }
        let mut lx = x;
        while lx > 0 && fillable!(row + lx - 1) {
            lx -= 1;
        }
        let mut rx = x;
        while rx + 1 < width && fillable!(row + rx + 1) {
            rx += 1;
        }
        for i in row + lx..=row + rx {
            visited[i >> 6] |= 1 << (i & 63);
            dst[i] = tint_pixel(src[i], color, strength);
        }
        painted += (rx - lx + 1) as u64;
        for ny in [y.wrapping_sub(1), y + 1] {
            if ny >= height {
                continue;
            }
            let nrow = ny * width;
            let mut in_run = false;
            for i in lx..=rx {
                let m = fillable!(nrow + i);
                if m && !in_run {
                    stack.push((nrow + i) as u32);
                }
                in_run = m;
            }
        }
    }
    painted
}

/// Distance unit of one orthogonal step in [`spread_distances`]; a diagonal
/// step costs [`DIAGONAL_STEP`]. 5/7 approximates 1/sqrt(2), so the fill
/// spreads as a round wave instead of a diamond.
pub const ORTHOGONAL_STEP: u32 = 5;
/// See [`ORTHOGONAL_STEP`].
pub const DIAGONAL_STEP: u32 = 7;
/// Marks a pixel outside the selected region in [`spread_distances`].
pub const UNREACHED: u32 = u32::MAX;
/// Largest image accepted by [`spread_distances`]: the longest geodesic
/// distance, `DIAGONAL_STEP * (pixels - 1)`, then stays below [`UNREACHED`].
pub const MAX_SPREAD_PIXELS: u64 = (u32::MAX / DIAGONAL_STEP) as u64;

/// Spreading fill ("paint that flows"): for the region of `src` around
/// `(x, y)` whose RGB is within `tolerance` of the seed pixel, writes the
/// geodesic distance from the seed into `dist` (in [`ORTHOGONAL_STEP`]
/// units), and [`UNREACHED`] everywhere else. Animating
/// `paint_by_distance` with a growing radius makes the colour flow around
/// obstacles and along the region's shape.
///
/// The region is exactly the 4-connected region (a diagonal step is only
/// taken next to an orthogonal one, so colour never leaks through a
/// diagonal gap in an outline). Dijkstra with a bucket queue: O(pixels).
/// Returns the largest distance. Callers must pass `(x, y)` inside the image
/// and at most [`MAX_SPREAD_PIXELS`] pixels; `dist` must not alias `src`.
#[allow(clippy::too_many_arguments)]
pub fn spread_distances(
    src: &[u8],
    dist: &mut [u32],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    tolerance: u8,
) -> u32 {
    let src = src.as_chunks::<4>().0;
    dist.fill(UNREACHED);
    let seed = src[y * width + x];
    let tol = tolerance as i16;
    let inside = |i: usize| (0..3).all(|c| (src[i][c] as i16 - seed[c] as i16).abs() <= tol);
    // Bucket queue keyed by distance modulo (DIAGONAL_STEP + 1): every
    // pending entry is within DIAGONAL_STEP of the current distance.
    const RING: usize = DIAGONAL_STEP as usize + 1;
    let mut buckets: [Vec<u32>; RING] = Default::default();
    let start = y * width + x;
    dist[start] = 0;
    buckets[0].push(start as u32);
    let mut pending = 1usize;
    let mut d = 0u32;
    let mut max = 0u32;
    while pending > 0 {
        let slot = d as usize % RING;
        while let Some(i) = buckets[slot].pop() {
            pending -= 1;
            let i = i as usize;
            if dist[i] != d {
                continue; // stale entry, already reached by a shorter path
            }
            max = d;
            let (px, py) = ((i % width) as isize, (i / width) as isize);
            let ok = |nx: isize, ny: isize| {
                nx >= 0 && ny >= 0 && (nx as usize) < width && (ny as usize) < height && inside(ny as usize * width + nx as usize)
            };
            let mut relax = |nx: isize, ny: isize, step: u32, buckets: &mut [Vec<u32>; RING], pending: &mut usize| {
                let j = ny as usize * width + nx as usize;
                let nd = d + step;
                if nd < dist[j] {
                    dist[j] = nd;
                    buckets[nd as usize % RING].push(j as u32);
                    *pending += 1;
                }
            };
            let (l, r, u, dn) = (ok(px - 1, py), ok(px + 1, py), ok(px, py - 1), ok(px, py + 1));
            if l { relax(px - 1, py, ORTHOGONAL_STEP, &mut buckets, &mut pending); }
            if r { relax(px + 1, py, ORTHOGONAL_STEP, &mut buckets, &mut pending); }
            if u { relax(px, py - 1, ORTHOGONAL_STEP, &mut buckets, &mut pending); }
            if dn { relax(px, py + 1, ORTHOGONAL_STEP, &mut buckets, &mut pending); }
            for (dx, dy, a, b) in [(-1, -1, l, u), (1, -1, r, u), (-1, 1, l, dn), (1, 1, r, dn)] {
                if (a || b) && ok(px + dx, py + dy) {
                    relax(px + dx, py + dy, DIAGONAL_STEP, &mut buckets, &mut pending);
                }
            }
        }
        d += 1;
    }
    max
}

/// Paints every pixel whose `dist` is in `from..to` (half-open, so frames
/// `0..r1`, `r1..r2`, ... never paint a pixel twice). With `tint`, the
/// pixel becomes [`tint_pixel`] of `src` (photos keep their texture);
/// otherwise it becomes `color` (flat fill for line art). Multi-threaded.
/// Returns the number of painted pixels.
#[allow(clippy::too_many_arguments)]
pub fn paint_by_distance(
    src: &[u8],
    dst: &mut [u8],
    dist: &[u32],
    width: usize,
    from: u32,
    to: u32,
    color: [u8; 4],
    strength: u8,
    tint: bool,
) -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    let painted = AtomicU64::new(0);
    let stride = width * 4;
    let src_px = src.as_chunks::<4>().0;
    for_each_row_band(dst, stride, 1, |first_row, band| {
        let mut n = 0u64;
        let base = first_row * width;
        for (k, px) in band.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let i = base + k;
            let d = dist[i];
            if d >= from && d < to {
                *px = if tint { tint_pixel(src_px[i], color, strength) } else { color };
                n += 1;
            }
        }
        painted.fetch_add(n, Ordering::Relaxed);
    });
    painted.into_inner()
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

    #[test]
    fn tint_keeps_luminance_order() {
        let red = [230, 40, 60, 255];
        let black = tint_pixel([0, 0, 0, 255], red, 255);
        let white = tint_pixel([255, 255, 255, 255], red, 255);
        let mid = tint_pixel([128, 128, 128, 200], red, 255);
        assert_eq!(black, [0, 0, 0, 255]);
        assert_eq!(white, [255, 255, 255, 255]);
        assert_eq!(mid[3], 200, "alpha kept");
        assert!(mid[0] > mid[1] && mid[0] > mid[2], "tinted red: {mid:?}");
        // Strength 0 is the identity.
        assert_eq!(tint_pixel([12, 34, 56, 78], red, 0), [12, 34, 56, 78]);
    }

    #[test]
    fn recolor_selects_on_source_and_writes_dst() {
        // Left half light gray (200), right half dark (40), 8x4.
        let (w, h) = (8, 4);
        let src: Vec<u8> = (0..w * h)
            .flat_map(|i| {
                let v = if i % w < 4 { 200 } else { 40 };
                [v, v, v, 255]
            })
            .collect();
        let mut dst = src.clone();
        let n = recolor_region_rgba(&src, &mut dst, w, h, 1, 1, [0, 0, 255, 255], 10, 255);
        assert_eq!(n, 16);
        for (i, px) in dst.as_chunks::<4>().0.iter().enumerate() {
            if i % w < 4 {
                assert!(px[2] > px[0], "left half tinted blue");
            } else {
                assert_eq!(*px, [40, 40, 40, 255], "right half untouched");
            }
        }
        // Selecting again on the untouched source repaints the same region.
        let n2 = recolor_region_rgba(&src, &mut dst, w, h, 0, 0, [255, 0, 0, 255], 10, 255);
        assert_eq!(n2, 16);
        assert!(dst[0] > dst[2], "now red");
    }

    #[test]
    fn spread_covers_exactly_the_4_connected_region() {
        for &(w, h, cells, block) in &[(64, 48, 12, 2), (97, 61, 9, 1)] {
            let base = page(w, h, cells, block, 11);
            let mut rng = Rng::new(9);
            for _ in 0..20 {
                let (x, y) = (rng.below(w), rng.below(h));
                let mut dist = vec![0u32; w * h];
                let max = spread_distances(&base, &mut dist, w, h, x, y, 0);
                let mut filled = base.clone();
                let n = naive_fill(&mut filled, w, h, x, y, [1, 2, 3, 4], 0);
                let reached = dist.iter().filter(|&&d| d != UNREACHED).count() as u64;
                assert_eq!(reached, n.max(1), "{w}x{h} at ({x},{y})");
                assert_eq!(dist[y * w + x], 0);
                assert!(dist.iter().all(|&d| d == UNREACHED || d <= max));
            }
        }
    }

    #[test]
    fn spread_is_round_and_paints_once() {
        // Open 41x41 white square, seed in the centre.
        let (w, h) = (41, 41);
        let src = vec![255u8; w * h * 4];
        let mut dist = vec![0u32; w * h];
        let max = spread_distances(&src, &mut dist, w, h, 20, 20, 0);
        // Straight and diagonal neighbours.
        assert_eq!(dist[20 * w + 25], 25);
        assert_eq!(dist[25 * w + 25], 35);
        assert_eq!(max, 20 * DIAGONAL_STEP);
        // Painting in consecutive rings touches every pixel exactly once.
        let mut dst = vec![0u8; w * h * 4];
        let mut total = 0;
        let mut r = 0;
        while r <= max {
            total += paint_by_distance(&src, &mut dst, &dist, w, r, r + 13, [9, 8, 7, 255], 255, false);
            r += 13;
        }
        assert_eq!(total, (w * h) as u64);
        assert!(dst.as_chunks::<4>().0.iter().all(|p| *p == [9, 8, 7, 255]));
    }
}
