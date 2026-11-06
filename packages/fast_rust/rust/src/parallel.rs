//! Minimal data-parallel helper on top of `std::thread::scope`.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

/// Optional user cap on worker threads (0 = no cap).
static THREAD_LIMIT: AtomicUsize = AtomicUsize::new(0);

/// Hardware threads, cached: `available_parallelism` is a syscall.
fn hardware_threads() -> usize {
    static COUNT: OnceLock<usize> = OnceLock::new();
    *COUNT.get_or_init(|| {
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
            .min(16)
    })
}

/// Worker count used by the parallel kernels.
pub fn thread_count() -> usize {
    match THREAD_LIMIT.load(Ordering::Relaxed) {
        0 => hardware_threads(),
        n => n.min(hardware_threads()),
    }
}

/// Caps worker threads (`0` restores the default). Used by benchmarks to
/// separate single-core speed from multi-core scaling.
pub fn set_thread_limit(limit: usize) {
    THREAD_LIMIT.store(limit, Ordering::Relaxed);
}

/// Splits `data` into bands of whole rows (`row_len` elements each) and runs
/// `f(first_row_index, band)` on every band, in parallel.
///
/// Bands are handed out from a shared queue, so threads that finish cheap
/// bands pick up more work (important for uneven loads like fractals).
/// Small inputs run on the calling thread to avoid spawn overhead.
///
/// `min_band_rows` lets kernels with per-band setup cost (e.g. a sliding
/// window) ask for fewer, taller bands.
pub fn for_each_row_band<T: Send>(
    data: &mut [T],
    row_len: usize,
    min_band_rows: usize,
    f: impl Fn(usize, &mut [T]) + Sync,
) {
    if row_len == 0 || data.is_empty() {
        return;
    }
    let rows = data.len() / row_len;
    // ~16K elements per band keeps queue and spawn overhead negligible.
    let rows_per_band = (16_384 / row_len).max(min_band_rows).max(1);
    let bands = rows.div_ceil(rows_per_band);
    let threads = thread_count().min(bands);
    if threads <= 1 {
        f(0, data);
        return;
    }
    let queue = Mutex::new(
        data.chunks_mut(rows_per_band * row_len)
            .enumerate()
            .map(|(i, band)| (i * rows_per_band, band)),
    );
    let worker = || loop {
        // Bind first so the lock is released before running `f`.
        let next = queue.lock().unwrap_or_else(|e| e.into_inner()).next();
        let Some((first_row, band)) = next else { break };
        f(first_row, band);
    };
    std::thread::scope(|s| {
        for _ in 1..threads {
            s.spawn(worker);
        }
        worker(); // the calling thread works too
    });
}
