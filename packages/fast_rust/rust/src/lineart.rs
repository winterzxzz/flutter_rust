//! Photo to coloring page: turns a photo into black outlines on white,
//! with closed regions ready for a bucket or spreading fill.
//!
//! Pipeline (integer-only, so the Dart reference matches bit for bit):
//! 1. box blur (`smooth`) to drop noise and texture;
//! 2. k-means colour quantization into `colors` clusters, seeded from
//!    luminance quantiles (deterministic);
//! 3. two 3x3 majority-filter passes to remove speckles;
//! 4. 4-connected regions smaller than `min_region` pixels are merged into
//!    the neighbouring cluster they share the most border with (repeated
//!    until stable, at most [`MERGE_PASSES`] times);
//! 5. outlines where the cluster changes, widened to `line_width`, plus a
//!    frame of the same width.

use crate::image::box_blur_rgba;
use crate::parallel::for_each_row_band;

/// Largest accepted number of colour clusters.
pub const MAX_COLORS: usize = 32;
/// Largest accepted blur radius for the smoothing step.
pub const MAX_SMOOTH: usize = 16;
/// Largest accepted outline width in pixels.
pub const MAX_LINE_WIDTH: usize = 8;
/// k-means iterations.
pub const KMEANS_ITERATIONS: usize = 6;
/// Most passes of the small-region merge.
pub const MERGE_PASSES: usize = 8;
/// Value of `labels` for outline pixels.
pub const LINE_LABEL: u8 = 255;

const INK: [u8; 4] = [0, 0, 0, 255];
const PAPER: [u8; 4] = [255, 255, 255, 255];

#[inline(always)]
fn luma(p: [u8; 4]) -> usize {
    ((77 * p[0] as u32 + 150 * p[1] as u32 + 29 * p[2] as u32) >> 8) as usize
}

#[inline(always)]
fn nearest(p: [u8; 4], centroids: &[[u32; 3]]) -> u8 {
    let mut best = (u32::MAX, 0u8);
    for (i, c) in centroids.iter().enumerate() {
        let dr = p[0] as i32 - c[0] as i32;
        let dg = p[1] as i32 - c[1] as i32;
        let db = p[2] as i32 - c[2] as i32;
        let d = (dr * dr + dg * dg + db * db) as u32;
        if d < best.0 {
            best = (d, i as u8);
        }
    }
    best.1
}

/// Initial centroids: split the luminance histogram into `k` parts of equal
/// pixel count and take the mean colour of each part.
fn initial_centroids(px: &[[u8; 4]], k: usize) -> Vec<[u32; 3]> {
    let mut count = [0u64; 256];
    let mut sum = [[0u64; 3]; 256];
    for p in px {
        let l = luma(*p);
        count[l] += 1;
        for c in 0..3 {
            sum[l][c] += p[c] as u64;
        }
    }
    let total = px.len() as u64;
    let mut out = Vec::with_capacity(k);
    let mut l = 0usize;
    let mut seen = 0u64;
    for part in 0..k as u64 {
        let end = total * (part + 1) / k as u64;
        let (mut n, mut s) = (0u64, [0u64; 3]);
        while l < 256 && seen + count[l] <= end {
            n += count[l];
            for c in 0..3 {
                s[c] += sum[l][c];
            }
            seen += count[l];
            l += 1;
        }
        match (s[0].checked_div(n), s[1].checked_div(n), s[2].checked_div(n)) {
            (Some(r), Some(g), Some(b)) => out.push([r as u32, g as u32, b as u32]),
            _ => {
                // Empty part: a grey at the next luminance.
                let g = l.min(255) as u32;
                out.push([g, g, g]);
            }
        }
    }
    out
}

/// Converts `src` (RGBA8888) into a coloring page written to `out`.
/// `labels`, when given, receives the cluster of every pixel
/// ([`LINE_LABEL`] on outlines) and `palette` the cluster colours as RGBA.
#[allow(clippy::too_many_arguments)]
pub fn photo_to_coloring_page(
    src: &[u8],
    out: &mut [u8],
    labels_out: Option<&mut [u8]>,
    palette_out: Option<&mut [u8]>,
    width: usize,
    height: usize,
    colors: usize,
    smooth: usize,
    min_region: usize,
    line_width: usize,
) {
    let n = width * height;
    if n == 0 {
        return;
    }
    let k = colors.clamp(1, MAX_COLORS);

    // 1. Smooth.
    let mut work = src.to_vec();
    box_blur_rgba(&mut work, width, height, smooth.min(MAX_SMOOTH));
    let px = work.as_chunks::<4>().0;

    // 2. k-means.
    let mut centroids = initial_centroids(px, k);
    let mut labels = vec![0u8; n];
    for _ in 0..KMEANS_ITERATIONS {
        {
            let cs = &centroids;
            for_each_row_band(&mut labels, width, 1, |first_row, band| {
                let base = first_row * width;
                for (i, l) in band.iter_mut().enumerate() {
                    *l = nearest(px[base + i], cs);
                }
            });
        }
        let mut count = vec![0u64; k];
        let mut sum = vec![[0u64; 3]; k];
        for (p, &l) in px.iter().zip(&labels) {
            count[l as usize] += 1;
            for c in 0..3 {
                sum[l as usize][c] += p[c] as u64;
            }
        }
        for i in 0..k {
            for c in 0..3 {
                // Empty clusters keep their centroid.
                if let Some(v) = sum[i][c].checked_div(count[i]) {
                    centroids[i][c] = v as u32;
                }
            }
        }
    }
    {
        let cs = &centroids;
        for_each_row_band(&mut labels, width, 1, |first_row, band| {
            let base = first_row * width;
            for (i, l) in band.iter_mut().enumerate() {
                *l = nearest(px[base + i], cs);
            }
        });
    }

    // 3. Majority filter (3x3, clamped edges). Ties keep the current label
    // if it is among the most frequent, otherwise take the lowest index.
    for _ in 0..2 {
        let prev = labels.clone();
        let prev = &prev;
        for_each_row_band(&mut labels, width, 1, |first_row, band| {
            let mut hist = [0u8; MAX_COLORS];
            for (r, row) in band.chunks_exact_mut(width).enumerate() {
                let y = first_row + r;
                for (x, l) in row.iter_mut().enumerate() {
                    hist[..k].fill(0);
                    for dy in [-1isize, 0, 1] {
                        let yy = (y as isize + dy).clamp(0, height as isize - 1) as usize;
                        for dx in [-1isize, 0, 1] {
                            let xx = (x as isize + dx).clamp(0, width as isize - 1) as usize;
                            hist[prev[yy * width + xx] as usize] += 1;
                        }
                    }
                    let cur = prev[y * width + x];
                    let max = *hist[..k].iter().max().unwrap();
                    *l = if hist[cur as usize] == max {
                        cur
                    } else {
                        hist[..k].iter().position(|&h| h == max).unwrap() as u8
                    };
                }
            }
        });
    }

    // 4. Merge small regions, in scan order of their first pixel.
    // Merging can leave a small region next to one that merged away, so
    // repeat until nothing changes (bounded).
    if min_region > 1 {
        for _ in 0..MERGE_PASSES {
            if !merge_small_regions(&mut labels, width, height, k, min_region) {
                break;
            }
        }
    }

    // 5. Outlines: a pixel is an edge seed if its right or bottom neighbour
    // has another label; seeds are widened to `line_width` with a separable
    // max filter (left/top offset (lw-1)/2), and a frame is added.
    let lw = line_width.clamp(1, MAX_LINE_WIDTH);
    let a = (lw - 1) / 2;
    let b = lw - 1 - a;
    let mut seeds = vec![0u8; n];
    {
        let labels = &labels;
        for_each_row_band(&mut seeds, width, 1, |first_row, band| {
            for (r, row) in band.chunks_exact_mut(width).enumerate() {
                let y = first_row + r;
                for (x, s) in row.iter_mut().enumerate() {
                    let l = labels[y * width + x];
                    *s = ((x + 1 < width && labels[y * width + x + 1] != l)
                        || (y + 1 < height && labels[(y + 1) * width + x] != l))
                        as u8;
                }
            }
        });
    }
    let mut horiz = vec![0u8; n];
    {
        let seeds = &seeds;
        for_each_row_band(&mut horiz, width, 1, |first_row, band| {
            for (r, row) in band.chunks_exact_mut(width).enumerate() {
                let y = first_row + r;
                for (x, h) in row.iter_mut().enumerate() {
                    let lo = x.saturating_sub(b);
                    let hi = (x + a).min(width - 1);
                    *h = seeds[y * width + lo..=y * width + hi].iter().any(|&s| s != 0) as u8;
                }
            }
        });
    }
    let stride = width * 4;
    let labels_ref = &labels;
    let horiz = &horiz;
    let line_at = |x: usize, y: usize| {
        if x < lw || y < lw || x + lw >= width || y + lw >= height {
            return true; // frame
        }
        let lo = y.saturating_sub(b);
        let hi = (y + a).min(height - 1);
        (lo..=hi).any(|yy| horiz[yy * width + x] != 0)
    };
    for_each_row_band(out, stride, 1, |first_row, band| {
        for (r, row) in band.chunks_exact_mut(stride).enumerate() {
            let y = first_row + r;
            for (x, p) in row.as_chunks_mut::<4>().0.iter_mut().enumerate() {
                *p = if line_at(x, y) { INK } else { PAPER };
            }
        }
    });
    if let Some(lo) = labels_out {
        let out_px = out.as_chunks::<4>().0;
        for (i, l) in lo.iter_mut().enumerate() {
            *l = if out_px[i] == INK { LINE_LABEL } else { labels_ref[i] };
        }
    }
    if let Some(pal) = palette_out {
        for (i, c) in centroids.iter().enumerate() {
            if let Some(p) = pal.get_mut(i * 4..i * 4 + 4) {
                p.copy_from_slice(&[c[0] as u8, c[1] as u8, c[2] as u8, 255]);
            }
        }
    }
}

/// Merges every 4-connected region smaller than `min_region` into the
/// neighbouring label it touches most often (ties: lowest label). Regions
/// are visited in scan order of their first pixel; earlier merges are seen
/// by later ones.
/// Returns whether any region changed label.
fn merge_small_regions(labels: &mut [u8], width: usize, height: usize, k: usize, min_region: usize) -> bool {
    let mut changed = false;
    let n = width * height;
    let mut comp = vec![u32::MAX; n];
    let mut members: Vec<u32> = Vec::with_capacity(n);
    let mut starts: Vec<usize> = Vec::new();
    let mut stack = Vec::new();
    for start in 0..n {
        if comp[start] != u32::MAX {
            continue;
        }
        let id = starts.len() as u32;
        starts.push(members.len());
        let l = labels[start];
        comp[start] = id;
        stack.push(start as u32);
        while let Some(i) = stack.pop() {
            let i = i as usize;
            members.push(i as u32);
            let (x, y) = (i % width, i / width);
            let mut visit = |j: usize| {
                if comp[j] == u32::MAX && labels[j] == l {
                    comp[j] = id;
                    stack.push(j as u32);
                }
            };
            if x > 0 { visit(i - 1); }
            if x + 1 < width { visit(i + 1); }
            if y > 0 { visit(i - width); }
            if y + 1 < height { visit(i + width); }
        }
    }
    starts.push(members.len());
    let mut hist = [0u32; MAX_COLORS];
    for c in 0..starts.len() - 1 {
        let pixels = &mut members[starts[c]..starts[c + 1]];
        if pixels.len() >= min_region {
            continue;
        }
        // Members are in DFS order; sort so the result does not depend on it.
        pixels.sort_unstable();
        let own = labels[pixels[0] as usize];
        hist[..k].fill(0);
        for &i in pixels.iter() {
            let i = i as usize;
            let (x, y) = (i % width, i / width);
            let mut count = |j: usize| {
                let l = labels[j];
                if l != own {
                    hist[l as usize] += 1;
                }
            };
            if x > 0 { count(i - 1); }
            if x + 1 < width { count(i + 1); }
            if y > 0 { count(i - width); }
            if y + 1 < height { count(i + width); }
        }
        let max = *hist[..k].iter().max().unwrap();
        if max == 0 {
            continue; // the whole image is one region
        }
        let target = hist[..k].iter().position(|&h| h == max).unwrap() as u8;
        for &i in pixels.iter() {
            labels[i as usize] = target;
        }
        changed = true;
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two flat halves with a little noise: one vertical outline in the middle.
    fn halves(w: usize, h: usize) -> Vec<u8> {
        let mut v = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let noise = ((x * 7 + y * 13) % 5) as u8;
                let base = if x < w / 2 { 40 } else { 210 };
                v.extend_from_slice(&[base + noise, base / 2 + noise, 90, 255]);
            }
        }
        v
    }

    #[test]
    fn two_halves_give_two_white_regions() {
        let (w, h) = (80, 50);
        let src = halves(w, h);
        let mut out = vec![0u8; w * h * 4];
        let mut labels = vec![0u8; w * h];
        let mut palette = vec![0u8; 2 * 4];
        photo_to_coloring_page(&src, &mut out, Some(&mut labels), Some(&mut palette), w, h, 2, 1, 16, 2);
        let px = out.as_chunks::<4>().0;
        // Frame is ink, centres of both halves are paper with distinct labels.
        assert_eq!(px[0], INK);
        let (l, r) = ((h / 2) * w + w / 4, (h / 2) * w + 3 * w / 4);
        assert_eq!(px[l], PAPER);
        assert_eq!(px[r], PAPER);
        assert_ne!(labels[l], labels[r]);
        // An outline separates the halves on the middle row.
        let row = &px[(h / 2) * w..(h / 2 + 1) * w];
        assert!(row[w / 2 - 2..w / 2 + 2].contains(&INK));
        // Palette holds the two cluster colours.
        assert!(palette[0] < 100 && palette[4] > 150, "{palette:?}");
        // Deterministic.
        let mut again = vec![0u8; w * h * 4];
        photo_to_coloring_page(&src, &mut again, None, None, w, h, 2, 1, 16, 2);
        assert_eq!(out, again);
    }

    #[test]
    fn tiny_speckles_are_merged() {
        let (w, h) = (40, 40);
        let mut src: Vec<u8> = [200u8, 200, 200, 255].repeat(w * h);
        // A 2x2 dark dot: survives the majority filter only partly, then is
        // merged because it is smaller than min_region.
        for (x, y) in [(20, 20), (21, 20), (20, 21), (21, 21)] {
            src[(y * w + x) * 4..][..3].copy_from_slice(&[10, 10, 10]);
        }
        let mut out = vec![0u8; w * h * 4];
        photo_to_coloring_page(&src, &mut out, None, None, w, h, 2, 0, 9, 1);
        let ink_inside = out
            .as_chunks::<4>()
            .0
            .iter()
            .enumerate()
            .filter(|(i, p)| {
                let (x, y) = (i % w, i / w);
                x > 1 && y > 1 && x < w - 2 && y < h - 2 && **p == INK
            })
            .count();
        assert_eq!(ink_inside, 0, "speckle left an outline");
    }
}
