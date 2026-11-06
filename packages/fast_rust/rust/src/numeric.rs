//! Numeric kernels.

/// Ascending sort by IEEE-754 total order (-NaN < -inf < ... < inf < NaN).
pub fn sort_f64(data: &mut [f64]) {
    data.sort_unstable_by(f64::total_cmp);
}

/// Largest accepted sieve limit (needs `limit / 2` bytes: 1 GiB).
pub const MAX_PRIME_LIMIT: u64 = (1 << 31) - 1;

/// Counts primes `<= limit` with an odd-only sieve of Eratosthenes.
/// Returns `None` if `limit > MAX_PRIME_LIMIT` or memory is unavailable.
pub fn count_primes(limit: u64) -> Option<u64> {
    if limit > MAX_PRIME_LIMIT {
        return None;
    }
    if limit < 2 {
        return Some(0);
    }
    let limit = limit as usize;
    // Index i represents the odd number 2i + 1.
    let size = (limit - 1) / 2 + 1;
    // Fallible allocation: report failure instead of aborting the app
    // (a 1 GiB request can fail on 32-bit or low-memory devices).
    let mut composite = Vec::new();
    composite.try_reserve_exact(size).ok()?;
    composite.resize(size, false);
    let mut i = 1;
    while (2 * i + 1) * (2 * i + 1) <= limit {
        if !composite[i] {
            let p = 2 * i + 1;
            let mut j = p * p / 2;
            while j < size {
                composite[j] = true;
                j += p;
            }
        }
        i += 1;
    }
    // Index 0 is the number 1 (not prime); the prime 2 is added back.
    Some(1 + composite[1..].iter().filter(|&&c| !c).count() as u64)
}

/// Dot product with 4 independent accumulators so LLVM can vectorize.
pub fn dot_f64(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len().min(b.len());
    let (a, b) = (&a[..n], &b[..n]);
    let mut acc = [0.0f64; 4];
    let chunks = n / 4 * 4;
    for (ca, cb) in a.as_chunks::<4>().0.iter().zip(b.as_chunks::<4>().0) {
        for k in 0..4 {
            acc[k] += ca[k] * cb[k];
        }
    }
    let mut sum = (acc[0] + acc[1]) + (acc[2] + acc[3]);
    for k in chunks..n {
        sum += a[k] * b[k];
    }
    sum
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn primes() {
        assert_eq!(count_primes(0), Some(0));
        assert_eq!(count_primes(1), Some(0));
        assert_eq!(count_primes(2), Some(1));
        assert_eq!(count_primes(3), Some(2));
        assert_eq!(count_primes(10), Some(4));
        assert_eq!(count_primes(100), Some(25));
        assert_eq!(count_primes(1_000_000), Some(78_498));
        assert_eq!(count_primes(10_000_000), Some(664_579));
        assert_eq!(count_primes(MAX_PRIME_LIMIT + 1), None);
    }

    #[test]
    fn sort_handles_specials() {
        let mut v = vec![3.0, f64::NAN, -0.0, f64::NEG_INFINITY, 0.0, -2.5, f64::INFINITY];
        sort_f64(&mut v);
        assert_eq!(&v[..6], &[f64::NEG_INFINITY, -2.5, -0.0, 0.0, 3.0, f64::INFINITY]);
        assert!(v[6].is_nan());
        assert!(v[2].is_sign_negative());
    }

    #[test]
    fn dot() {
        let a: Vec<f64> = (0..7).map(|i| i as f64).collect();
        let b = vec![2.0; 7];
        assert_eq!(dot_f64(&a, &b), 42.0);
        assert_eq!(dot_f64(&[], &[]), 0.0);
    }
}
