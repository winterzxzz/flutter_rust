//! Progressive path tracer for a built-in scene of spheres: glass, metal
//! and diffuse balls on a checkered floor under a sky gradient.
//!
//! Every call adds `samples` paths per pixel to an `f64` accumulation buffer
//! (3 values per pixel); [`resolve_rgba`] turns the running average into
//! RGBA. Pixels are independent (each has its own random stream seeded from
//! its index and the sample number), so rows are traced in parallel and the
//! result does not depend on the thread count.
//!
//! The kernel uses only `+ - * /`, `sqrt` and `floor`, which IEEE-754
//! rounds identically everywhere, and never fuses operations, so the pure
//! Dart reference produces the same bits.

use crate::parallel::for_each_row_band;

/// Largest accepted samples per pixel in one call.
pub const MAX_SAMPLES: u32 = 64;
/// Largest accepted bounce depth.
pub const MAX_DEPTH: u32 = 16;
/// Number of `f64` values describing the camera (see [`Camera`]).
pub const CAMERA_LEN: usize = 19;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct V(pub f64, pub f64, pub f64);

impl V {
    #[inline(always)]
    fn add(self, o: V) -> V {
        V(self.0 + o.0, self.1 + o.1, self.2 + o.2)
    }
    #[inline(always)]
    fn sub(self, o: V) -> V {
        V(self.0 - o.0, self.1 - o.1, self.2 - o.2)
    }
    #[inline(always)]
    fn scale(self, s: f64) -> V {
        V(self.0 * s, self.1 * s, self.2 * s)
    }
    #[inline(always)]
    fn mul(self, o: V) -> V {
        V(self.0 * o.0, self.1 * o.1, self.2 * o.2)
    }
    #[inline(always)]
    fn dot(self, o: V) -> f64 {
        self.0 * o.0 + self.1 * o.1 + self.2 * o.2
    }
    #[inline(always)]
    fn len_sq(self) -> f64 {
        self.dot(self)
    }
    #[inline(always)]
    fn unit(self) -> V {
        self.scale(1.0 / self.len_sq().sqrt())
    }
}

/// Surface of a sphere.
#[derive(Clone, Copy)]
pub enum Material {
    /// Lambertian, with an albedo.
    Diffuse(V),
    /// Checkered Lambertian floor.
    Checker(V, V),
    /// Mirror with an albedo and a fuzz radius.
    Metal(V, f64),
    /// Glass with an index of refraction.
    Glass(f64),
}

#[derive(Clone, Copy)]
pub struct Sphere {
    pub center: V,
    pub radius: f64,
    pub material: Material,
}

const fn s(x: f64, y: f64, z: f64, r: f64, m: Material) -> Sphere {
    Sphere { center: V(x, y, z), radius: r, material: m }
}

/// The scene, mirrored literally by the Dart reference.
pub const SCENE: [Sphere; 12] = [
    s(0.0, -1000.0, 0.0, 1000.0, Material::Checker(V(0.86, 0.86, 0.82), V(0.22, 0.30, 0.42))),
    s(0.0, 1.0, 0.0, 1.0, Material::Glass(1.5)),
    s(-2.2, 1.0, 0.3, 1.0, Material::Diffuse(V(0.85, 0.28, 0.20))),
    s(2.2, 1.0, 0.3, 1.0, Material::Metal(V(0.80, 0.70, 0.55), 0.02)),
    s(-1.9, 0.3, 1.9, 0.3, Material::Diffuse(V(0.95, 0.75, 0.20))),
    s(-0.7, 0.25, 2.2, 0.25, Material::Metal(V(0.85, 0.85, 0.92), 0.15)),
    s(0.6, 0.3, 2.3, 0.3, Material::Diffuse(V(0.25, 0.70, 0.45))),
    s(1.8, 0.25, 2.0, 0.25, Material::Glass(1.5)),
    s(-3.4, 0.35, -1.5, 0.35, Material::Diffuse(V(0.30, 0.45, 0.90))),
    s(3.3, 0.35, -1.4, 0.35, Material::Metal(V(0.95, 0.60, 0.30), 0.3)),
    s(0.3, 0.4, -2.6, 0.4, Material::Diffuse(V(0.70, 0.30, 0.80))),
    s(-1.2, 0.3, -2.2, 0.3, Material::Glass(1.5)),
];

/// Pinhole/thin-lens camera: `origin`, `lower_left` corner of the focus
/// plane, its `horizontal` and `vertical` spans, the lens axes `u`, `v`
/// and the lens radius, packed as 19 `f64`s in that order.
#[derive(Clone, Copy)]
pub struct Camera {
    origin: V,
    lower_left: V,
    horizontal: V,
    vertical: V,
    u: V,
    v: V,
    lens_radius: f64,
}

impl Camera {
    pub fn from_slice(c: &[f64]) -> Option<Camera> {
        if c.len() < CAMERA_LEN || c[..CAMERA_LEN].iter().any(|x| !x.is_finite()) {
            return None;
        }
        let v = |i: usize| V(c[i], c[i + 1], c[i + 2]);
        Some(Camera {
            origin: v(0),
            lower_left: v(3),
            horizontal: v(6),
            vertical: v(9),
            u: v(12),
            v: v(15),
            lens_radius: c[18],
        })
    }
}

/// xorshift64 stream, seeded per pixel and sample.
struct Rng(u64);

impl Rng {
    #[inline(always)]
    fn new(pixel: u64, sample: u64) -> Rng {
        let s = (pixel.wrapping_add(1)).wrapping_mul(0x9E37_79B9_7F4A_7C15)
            ^ (sample.wrapping_add(1)).wrapping_mul(0xD1B5_4A32_D192_ED03);
        let mut r = Rng(s | 1);
        r.next();
        r.next();
        r
    }
    #[inline(always)]
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    /// Uniform in [0, 1) with 53 random bits (exact conversion).
    #[inline(always)]
    fn f(&mut self) -> f64 {
        (self.next() >> 11) as f64 * (1.0 / 9_007_199_254_740_992.0)
    }
    #[inline(always)]
    fn in_unit_sphere(&mut self) -> V {
        loop {
            let p = V(self.f() * 2.0 - 1.0, self.f() * 2.0 - 1.0, self.f() * 2.0 - 1.0);
            if p.len_sq() < 1.0 {
                return p;
            }
        }
    }
    #[inline(always)]
    fn in_unit_disk(&mut self) -> V {
        loop {
            let p = V(self.f() * 2.0 - 1.0, self.f() * 2.0 - 1.0, 0.0);
            if p.len_sq() < 1.0 {
                return p;
            }
        }
    }
}

#[inline(always)]
fn reflect(v: V, n: V) -> V {
    v.sub(n.scale(2.0 * v.dot(n)))
}

/// Nearest hit along `origin + t * dir` with t in (0.001, inf).
#[inline(always)]
fn hit(origin: V, dir: V) -> Option<(f64, usize)> {
    let mut best: Option<(f64, usize)> = None;
    let a = dir.len_sq();
    for (i, s) in SCENE.iter().enumerate() {
        let oc = origin.sub(s.center);
        let half_b = oc.dot(dir);
        let c = oc.len_sq() - s.radius * s.radius;
        let disc = half_b * half_b - a * c;
        if disc < 0.0 {
            continue;
        }
        let sq = disc.sqrt();
        let limit = best.map_or(f64::INFINITY, |b| b.0);
        let mut t = (-half_b - sq) / a;
        if t <= 0.001 || t >= limit {
            t = (-half_b + sq) / a;
            if t <= 0.001 || t >= limit {
                continue;
            }
        }
        best = Some((t, i));
    }
    best
}

fn radiance(mut origin: V, mut dir: V, rng: &mut Rng, max_depth: u32) -> V {
    let mut throughput = V(1.0, 1.0, 1.0);
    for _ in 0..max_depth {
        let Some((t, i)) = hit(origin, dir) else {
            let unit = dir.unit();
            let k = 0.5 * (unit.1 + 1.0);
            let sky = V(1.0, 1.0, 1.0).scale(1.0 - k).add(V(0.45, 0.65, 1.0).scale(k));
            return throughput.mul(sky);
        };
        let s = &SCENE[i];
        let p = origin.add(dir.scale(t));
        let outward = p.sub(s.center).scale(1.0 / s.radius);
        let front = dir.dot(outward) < 0.0;
        let n = if front { outward } else { outward.scale(-1.0) };
        match s.material {
            Material::Diffuse(albedo) | Material::Checker(albedo, _) => {
                let albedo = match s.material {
                    Material::Checker(a, b) => {
                        let k = p.0.floor() + p.2.floor();
                        if k - (k * 0.5).floor() * 2.0 == 0.0 { a } else { b }
                    }
                    _ => albedo,
                };
                let mut d = n.add(rng.in_unit_sphere().unit());
                if d.len_sq() < 1e-16 {
                    d = n;
                }
                origin = p;
                dir = d;
                throughput = throughput.mul(albedo);
            }
            Material::Metal(albedo, fuzz) => {
                let r = reflect(dir.unit(), n).add(rng.in_unit_sphere().scale(fuzz));
                if r.dot(n) <= 0.0 {
                    return V(0.0, 0.0, 0.0);
                }
                origin = p;
                dir = r;
                throughput = throughput.mul(albedo);
            }
            Material::Glass(ior) => {
                let ratio = if front { 1.0 / ior } else { ior };
                let unit = dir.unit();
                let cos = (-unit.dot(n)).min(1.0);
                let sin = (1.0 - cos * cos).sqrt();
                let r0 = (1.0 - ratio) / (1.0 + ratio);
                let r0 = r0 * r0;
                let m = 1.0 - cos;
                let schlick = r0 + (1.0 - r0) * (m * m * m * m * m);
                dir = if ratio * sin > 1.0 || schlick > rng.f() {
                    reflect(unit, n)
                } else {
                    let perp = unit.add(n.scale(cos)).scale(ratio);
                    let par = n.scale(-((1.0 - perp.len_sq()).abs().sqrt()));
                    perp.add(par)
                };
                origin = p;
            }
        }
    }
    V(0.0, 0.0, 0.0)
}

/// Adds `samples` paths per pixel to `accum` (`width * height * 3` f64s,
/// row 0 at the top). `first_sample` is the number of samples already in
/// the buffer; it seeds the random streams.
#[allow(clippy::too_many_arguments)]
pub fn trace(
    accum: &mut [f64],
    width: usize,
    height: usize,
    camera: &Camera,
    first_sample: u32,
    samples: u32,
    max_depth: u32,
) {
    if width == 0 || height == 0 {
        return;
    }
    let cam = *camera;
    for_each_row_band(accum, width * 3, 1, |first_row, band| {
        for (r, row) in band.chunks_exact_mut(width * 3).enumerate() {
            let y = first_row + r;
            for x in 0..width {
                let pixel = (y * width + x) as u64;
                let mut sum = V(0.0, 0.0, 0.0);
                for k in 0..samples {
                    let mut rng = Rng::new(pixel, (first_sample + k) as u64);
                    let u = (x as f64 + rng.f()) / width as f64;
                    let v = ((height - 1 - y) as f64 + rng.f()) / height as f64;
                    let lens = rng.in_unit_disk().scale(cam.lens_radius);
                    let offset = cam.u.scale(lens.0).add(cam.v.scale(lens.1));
                    let from = cam.origin.add(offset);
                    let target = cam
                        .lower_left
                        .add(cam.horizontal.scale(u))
                        .add(cam.vertical.scale(v));
                    sum = sum.add(radiance(from, target.sub(from), &mut rng, max_depth));
                }
                let o = &mut row[x * 3..x * 3 + 3];
                o[0] += sum.0;
                o[1] += sum.1;
                o[2] += sum.2;
            }
        }
    });
}

/// Writes the average of `sample_count` samples as RGBA8888: clamped to
/// [0, 1], gamma 2 (square root), scaled to 0..=255.
pub fn resolve_rgba(accum: &[f64], out: &mut [u8], width: usize, sample_count: u32) {
    let inv = 1.0 / (sample_count.max(1) as f64);
    for_each_row_band(out, width * 4, 1, |first_row, band| {
        let base = first_row * width;
        for (k, p) in band.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let a = &accum[(base + k) * 3..(base + k) * 3 + 3];
            for c in 0..3 {
                let v = a[c] * inv;
                // NaN (from a degenerate camera) shows as black on both sides.
                let v = if v.is_nan() { 0.0 } else { v.clamp(0.0, 1.0) }.sqrt();
                p[c] = (v * 255.0 + 0.5) as u8;
            }
            p[3] = 255;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn camera(w: usize, h: usize) -> Camera {
        // Straight down -z from (0, 1.2, 8), 2.4 world units of focus-plane
        // height, no lens blur; enough to exercise every material.
        let aspect = w as f64 / h as f64;
        let (hh, hw) = (1.2, 1.2 * aspect);
        let c = [
            0.0, 1.2, 8.0, // origin
            -hw, 0.0, 4.0, // lower left
            2.0 * hw, 0.0, 0.0, // horizontal
            0.0, 2.0 * hh, 0.0, // vertical
            1.0, 0.0, 0.0, 0.0, 1.0, 0.0, // u, v
            0.0,
        ];
        Camera::from_slice(&c).unwrap()
    }

    #[test]
    fn many_bands_give_the_same_bits_on_one_or_many_threads() {
        // 400 px wide: about 13 rows per band, so 40 rows make 4 bands.
        let (w, h) = (400, 40);
        let cam = camera(w, h);
        let mut many = vec![0.0; w * h * 3];
        trace(&mut many, w, h, &cam, 0, 1, 6);
        crate::parallel::set_thread_limit(1);
        let mut one = vec![0.0; w * h * 3];
        trace(&mut one, w, h, &cam, 0, 1, 6);
        crate::parallel::set_thread_limit(0);
        assert!(many.iter().zip(&one).all(|(a, b)| a.to_bits() == b.to_bits()));
    }

    #[test]
    fn rays_hit_the_scene_and_the_sky() {
        assert_eq!(hit(V(0.0, 1.0, 8.0), V(0.0, 0.0, -1.0)).unwrap().1, 1);
        assert_eq!(hit(V(0.0, 5.0, 0.0), V(0.0, -1.0, 0.0)).unwrap().1, 1);
        assert_eq!(hit(V(0.0, 0.5, 8.0), V(0.0, 1.0, 0.0)), None);
        assert_eq!(hit(V(10.0, 1.0, 0.0), V(0.0, -1.0, 0.0)).unwrap().1, 0);
    }

    #[test]
    fn render_is_deterministic_and_thread_independent() {
        let (w, h) = (24, 16);
        let cam = camera(w, h);
        let mut a = vec![0.0; w * h * 3];
        trace(&mut a, w, h, &cam, 0, 2, 6);
        let mut b = vec![0.0; w * h * 3];
        crate::parallel::set_thread_limit(1);
        trace(&mut b, w, h, &cam, 0, 1, 6);
        trace(&mut b, w, h, &cam, 1, 1, 6);
        crate::parallel::set_thread_limit(0);
        // Same samples, split over two calls and one thread: same sums up to
        // the order of the per-pixel additions (2 samples at once vs 1 + 1).
        for (x, y) in a.iter().zip(&b) {
            assert!((x - y).abs() < 1e-12, "{x} vs {y}");
        }
        let mut out = vec![0u8; w * h * 4];
        resolve_rgba(&a, &mut out, w, 2);
        // The top row sees sky (bright, bluish), the bottom row the floor.
        let top = &out[(w / 2) * 4..(w / 2) * 4 + 4];
        assert!(top[2] >= top[0] && top[2] > 150, "{top:?}");
        assert!(out.iter().skip(3).step_by(4).all(|&a| a == 255));
    }
}
