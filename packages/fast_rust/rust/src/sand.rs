//! Falling-sand cellular automaton: sand piles up and sinks through water,
//! water flows and levels out, walls stay put.
//!
//! One step scans rows bottom-up, alternating the column direction every
//! frame, and moves each particle at most once (a "moved" flag in bit 7).
//! Random choices come from a hash of (x, y, frame), so the result is fully
//! deterministic and the Dart reference matches cell for cell. The scan is
//! inherently sequential, so this kernel runs on one thread.

/// Empty cell.
pub const EMPTY: u8 = 0;
/// Static wall.
pub const WALL: u8 = 1;
/// Falls, slides diagonally, sinks through water.
pub const SAND: u8 = 2;
/// Falls, slides diagonally, spreads sideways.
pub const WATER: u8 = 3;
/// Number of materials; larger cell values are rejected.
pub const MATERIALS: u8 = 4;

const MOVED: u8 = 0x80;
const KIND: u8 = 0x7F;

/// 32-bit integer hash of a cell and frame.
#[inline(always)]
pub fn hash(x: u32, y: u32, frame: u32) -> u32 {
    let mut h = x
        .wrapping_mul(0x9E37_79B1)
        ^ y.wrapping_mul(0x85EB_CA77)
        ^ frame.wrapping_mul(0xC2B2_AE3D);
    h ^= h >> 15;
    h = h.wrapping_mul(0x2C1B_3C6D);
    h ^= h >> 12;
    h
}

/// Advances the simulation by one step in place. Returns the number of
/// particles that moved.
pub fn step(cells: &mut [u8], width: usize, height: usize, frame: u32) -> u64 {
    if width == 0 || height < 2 {
        return 0;
    }
    let mut moved = 0u64;
    let rightward = frame.is_multiple_of(2);
    for y in (0..height - 1).rev() {
        for k in 0..width {
            let x = if rightward { k } else { width - 1 - k };
            let i = y * width + x;
            let c = cells[i];
            if c & MOVED != 0 {
                continue;
            }
            let kind = c & KIND;
            if kind != SAND && kind != WATER {
                continue;
            }
            let below = i + width;
            // Sand displaces water; water only moves into empty cells.
            let free = |t: u8| t == EMPTY || (kind == SAND && t == WATER);
            let mut target = None;
            if free(cells[below]) {
                target = Some(below);
            } else {
                // The hash is only needed when a particle cannot fall straight.
                let h = hash(x as u32, y as u32, frame);
                let first_left = h & 1 == 0;
                for left in [first_left, !first_left] {
                    if left && x > 0 && free(cells[below - 1]) {
                        target = Some(below - 1);
                        break;
                    }
                    if !left && x + 1 < width && free(cells[below + 1]) {
                        target = Some(below + 1);
                        break;
                    }
                }
                if target.is_none() && kind == WATER {
                    let first_left = h & 2 == 0;
                    for left in [first_left, !first_left] {
                        if left && x > 0 && cells[i - 1] == EMPTY {
                            target = Some(i - 1);
                            break;
                        }
                        if !left && x + 1 < width && cells[i + 1] == EMPTY {
                            target = Some(i + 1);
                            break;
                        }
                    }
                }
            }
            if let Some(t) = target {
                // Water displaced by sinking sand counts as moved too, so no
                // particle moves twice in one step.
                cells[i] = if cells[t] == EMPTY { EMPTY } else { cells[t] | MOVED };
                cells[t] = kind | MOVED;
                moved += 1;
            }
        }
    }
    for c in cells.iter_mut() {
        *c &= KIND;
    }
    moved
}

/// Colour of a cell; sand and walls get a small per-cell variation so the
/// grains are visible.
#[inline(always)]
pub fn cell_color(kind: u8, i: u32) -> [u8; 4] {
    let v = (hash(i, 0x51ED, 7) & 31) as u8;
    match kind {
        WALL => [90 + v, 92 + v, 104 + v, 255],
        SAND => [214 + v / 2, 178 + v / 2, 92 + v, 255],
        WATER => [40, 110 + v / 2, 230, 255],
        _ => [16, 20, 32, 255],
    }
}

/// Renders the cells into an RGBA8888 buffer (multi-threaded).
pub fn render_rgba(cells: &[u8], out: &mut [u8], width: usize) {
    crate::parallel::for_each_row_band(out, width * 4, 1, |first_row, band| {
        let base = first_row * width;
        for (k, p) in band.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let i = base + k;
            *p = cell_color(cells[i] & KIND, i as u32);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sand_falls_and_piles_while_water_levels() {
        let (w, h) = (9, 6);
        let mut cells = vec![EMPTY; w * h];
        cells[4] = SAND; // top centre
        for f in 0..10 {
            step(&mut cells, w, h, f);
        }
        assert_eq!(cells[(h - 1) * w + 4], SAND, "sand reached the floor");

        // A column of 3 grains spreads into a pile, never more than 1 wide
        // step at a time, and the count is conserved.
        let mut cells = vec![EMPTY; w * h];
        for y in 0..3 {
            cells[y * w + 4] = SAND;
        }
        for f in 0..20 {
            step(&mut cells, w, h, f);
        }
        assert_eq!(cells.iter().filter(|&&c| c == SAND).count(), 3);
        assert!(cells[(h - 1) * w..].iter().filter(|&&c| c == SAND).count() >= 2);

        // Water poured in one spot ends up flat on the floor.
        let mut cells = vec![EMPTY; w * h];
        for y in 0..3 {
            cells[y * w + 4] = WATER;
        }
        for f in 0..60 {
            step(&mut cells, w, h, f);
        }
        let floor = &cells[(h - 1) * w..];
        assert_eq!(floor.iter().filter(|&&c| c == WATER).count(), 3);
    }

    #[test]
    fn displaced_water_moves_once_per_step() {
        // Column: sand, sand, sand, water. One step: the bottom sand swaps
        // with the water, and that water must not keep rising.
        let mut cells = vec![SAND, SAND, SAND, WATER];
        step(&mut cells, 1, 4, 0);
        assert_eq!(cells, vec![SAND, SAND, WATER, SAND]);
    }

    #[test]
    fn sand_sinks_through_water_and_walls_hold() {
        let (w, h) = (3, 4);
        let mut cells = vec![WALL; w * h];
        cells[1] = SAND;
        cells[w + 1] = WATER;
        cells[2 * w + 1] = WATER;
        cells[3 * w + 1] = EMPTY;
        for f in 0..6 {
            step(&mut cells, w, h, f);
        }
        assert_eq!(cells[3 * w + 1], SAND);
        assert_eq!(cells.iter().filter(|&&c| c == WALL).count(), 8);
        assert_eq!(cells.iter().filter(|&&c| c == WATER).count(), 2);
    }
}
