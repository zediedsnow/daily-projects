//! A dependency-free Monte Carlo path tracer.
//!
//! Features: Lambertian / metal / dielectric (glass) / emissive materials,
//! a bounding-volume hierarchy, thin-lens depth of field, multi-threaded
//! rendering with std::thread, ACES tone mapping, and a hand-written PNG
//! encoder (zlib "stored" blocks + CRC32 + Adler-32). Zero crates.

use std::ops::{Add, Div, Mul, Neg, Sub};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

// ---------------------------------------------------------------- vectors
#[derive(Clone, Copy, Debug, Default)]
struct V3(f64, f64, f64);

impl V3 {
    fn dot(self, o: V3) -> f64 { self.0 * o.0 + self.1 * o.1 + self.2 * o.2 }
    fn cross(self, o: V3) -> V3 {
        V3(self.1 * o.2 - self.2 * o.1, self.2 * o.0 - self.0 * o.2, self.0 * o.1 - self.1 * o.0)
    }
    fn len(self) -> f64 { self.dot(self).sqrt() }
    fn unit(self) -> V3 { self / self.len() }
    fn mul(self, o: V3) -> V3 { V3(self.0 * o.0, self.1 * o.1, self.2 * o.2) }
    fn axis(self, i: usize) -> f64 { [self.0, self.1, self.2][i] }
    fn min(self, o: V3) -> V3 { V3(self.0.min(o.0), self.1.min(o.1), self.2.min(o.2)) }
    fn max(self, o: V3) -> V3 { V3(self.0.max(o.0), self.1.max(o.1), self.2.max(o.2)) }
    fn near_zero(self) -> bool { self.0.abs() < 1e-8 && self.1.abs() < 1e-8 && self.2.abs() < 1e-8 }
}
impl Add for V3 { type Output = V3; fn add(self, o: V3) -> V3 { V3(self.0 + o.0, self.1 + o.1, self.2 + o.2) } }
impl Sub for V3 { type Output = V3; fn sub(self, o: V3) -> V3 { V3(self.0 - o.0, self.1 - o.1, self.2 - o.2) } }
impl Mul<f64> for V3 { type Output = V3; fn mul(self, t: f64) -> V3 { V3(self.0 * t, self.1 * t, self.2 * t) } }
impl Div<f64> for V3 { type Output = V3; fn div(self, t: f64) -> V3 { self * (1.0 / t) } }
impl Neg for V3 { type Output = V3; fn neg(self) -> V3 { V3(-self.0, -self.1, -self.2) } }

// ---------------------------------------------------------------- rng (xorshift64*)
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        ((self.0.wrapping_mul(0x2545F4914F6CDD1D) >> 11) as f64) / ((1u64 << 53) as f64)
    }
    fn range(&mut self, a: f64, b: f64) -> f64 { a + (b - a) * self.next() }
    fn in_unit_sphere(&mut self) -> V3 {
        loop {
            let p = V3(self.range(-1., 1.), self.range(-1., 1.), self.range(-1., 1.));
            if p.dot(p) < 1.0 { return p; }
        }
    }
    fn unit_vec(&mut self) -> V3 { self.in_unit_sphere().unit() }
    fn in_unit_disk(&mut self) -> V3 {
        loop {
            let p = V3(self.range(-1., 1.), self.range(-1., 1.), 0.);
            if p.dot(p) < 1.0 { return p; }
        }
    }
}

// ---------------------------------------------------------------- geometry
struct Ray { o: V3, d: V3 }
impl Ray { fn at(&self, t: f64) -> V3 { self.o + self.d * t } }

#[derive(Clone, Copy)]
enum Mat {
    Diffuse(V3),
    Checker(V3, V3, f64),
    Metal(V3, f64),
    Glass(f64),
    Light(V3),
}

struct Sphere { c: V3, r: f64, m: Mat }

struct Hit { t: f64, p: V3, n: V3, front: bool, m: Mat }

impl Sphere {
    fn hit(&self, ray: &Ray, tmin: f64, tmax: f64) -> Option<Hit> {
        let oc = ray.o - self.c;
        let a = ray.d.dot(ray.d);
        let h = oc.dot(ray.d);
        let c = oc.dot(oc) - self.r * self.r;
        let disc = h * h - a * c;
        if disc < 0.0 { return None; }
        let sq = disc.sqrt();
        let mut t = (-h - sq) / a;
        if t <= tmin || t >= tmax {
            t = (-h + sq) / a;
            if t <= tmin || t >= tmax { return None; }
        }
        let p = ray.at(t);
        let out = (p - self.c) / self.r;
        let front = ray.d.dot(out) < 0.0;
        Some(Hit { t, p, n: if front { out } else { -out }, front, m: self.m })
    }
    fn bbox(&self) -> Aabb {
        let r = V3(self.r.abs(), self.r.abs(), self.r.abs());
        Aabb { lo: self.c - r, hi: self.c + r }
    }
}

#[derive(Clone, Copy)]
struct Aabb { lo: V3, hi: V3 }
impl Aabb {
    fn union(a: Aabb, b: Aabb) -> Aabb { Aabb { lo: a.lo.min(b.lo), hi: a.hi.max(b.hi) } }
    fn hit(&self, ray: &Ray, inv: V3, mut tmin: f64, mut tmax: f64) -> bool {
        for i in 0..3 {
            let mut t0 = (self.lo.axis(i) - ray.o.axis(i)) * inv.axis(i);
            let mut t1 = (self.hi.axis(i) - ray.o.axis(i)) * inv.axis(i);
            if inv.axis(i) < 0.0 { std::mem::swap(&mut t0, &mut t1); }
            tmin = tmin.max(t0);
            tmax = tmax.min(t1);
            if tmax <= tmin { return false; }
        }
        true
    }
}

// ---------------------------------------------------------------- BVH
enum Node {
    Leaf(usize),
    Inner(Aabb, Box<Node>, Box<Node>),
}

struct Bvh { root: Node, spheres: Vec<Sphere>, nodes: usize }

impl Bvh {
    fn new(spheres: Vec<Sphere>) -> Bvh {
        let mut idx: Vec<usize> = (0..spheres.len()).collect();
        let mut nodes = 0;
        let root = Self::build(&spheres, &mut idx[..], &mut nodes);
        Bvh { root, spheres, nodes }
    }
    fn build(s: &[Sphere], idx: &mut [usize], count: &mut usize) -> Node {
        *count += 1;
        if idx.len() == 1 { return Node::Leaf(idx[0]); }
        let bb = idx.iter().map(|&i| s[i].bbox()).reduce(Aabb::union).unwrap();
        let ext = bb.hi - bb.lo;
        let axis = if ext.0 > ext.1 && ext.0 > ext.2 { 0 } else if ext.1 > ext.2 { 1 } else { 2 };
        idx.sort_by(|&a, &b| s[a].c.axis(axis).partial_cmp(&s[b].c.axis(axis)).unwrap());
        let mid = idx.len() / 2;
        let (l, r) = idx.split_at_mut(mid);
        Node::Inner(bb, Box::new(Self::build(s, l, count)), Box::new(Self::build(s, r, count)))
    }
    fn hit(&self, ray: &Ray, tmin: f64, tmax: f64) -> Option<Hit> {
        let inv = V3(1.0 / ray.d.0, 1.0 / ray.d.1, 1.0 / ray.d.2);
        let mut best: Option<Hit> = None;
        let mut closest = tmax;
        let mut stack: Vec<&Node> = vec![&self.root];
        while let Some(n) = stack.pop() {
            match n {
                Node::Leaf(i) => {
                    if let Some(h) = self.spheres[*i].hit(ray, tmin, closest) {
                        closest = h.t;
                        best = Some(h);
                    }
                }
                Node::Inner(bb, l, r) => {
                    if bb.hit(ray, inv, tmin, closest) {
                        stack.push(l);
                        stack.push(r);
                    }
                }
            }
        }
        best
    }
}

// ---------------------------------------------------------------- shading
fn reflect(v: V3, n: V3) -> V3 { v - n * (2.0 * v.dot(n)) }
fn refract(uv: V3, n: V3, eta: f64) -> V3 {
    let cos = (-uv).dot(n).min(1.0);
    let perp = (uv + n * cos) * eta;
    let par = n * -(1.0 - perp.dot(perp)).abs().sqrt();
    perp + par
}
fn schlick(cos: f64, ior: f64) -> f64 {
    let r0 = ((1.0 - ior) / (1.0 + ior)).powi(2);
    r0 + (1.0 - r0) * (1.0 - cos).powi(5)
}

fn sky(d: V3) -> V3 {
    // dusky gradient: dim so the emissive spheres carry the scene
    let t = 0.5 * (d.unit().1 + 1.0);
    V3(0.02, 0.02, 0.05) * (1.0 - t) + V3(0.10, 0.14, 0.28) * t
}

fn trace(world: &Bvh, mut ray: Ray, rng: &mut Rng, max_depth: u32) -> V3 {
    let mut throughput = V3(1., 1., 1.);
    for depth in 0..max_depth {
        let Some(h) = world.hit(&ray, 1e-4, f64::INFINITY) else {
            return throughput.mul(sky(ray.d));
        };
        let (dir, atten) = match h.m {
            Mat::Light(e) => return throughput.mul(e),
            Mat::Diffuse(a) => {
                let mut d = h.n + rng.unit_vec();
                if d.near_zero() { d = h.n; }
                (d, a)
            }
            Mat::Checker(a, b, s) => {
                let k = ((h.p.0 * s).floor() + (h.p.2 * s).floor()) as i64;
                let mut d = h.n + rng.unit_vec();
                if d.near_zero() { d = h.n; }
                (d, if k.rem_euclid(2) == 0 { a } else { b })
            }
            Mat::Metal(a, fuzz) => {
                let d = reflect(ray.d.unit(), h.n) + rng.in_unit_sphere() * fuzz;
                if d.dot(h.n) <= 0.0 { return V3(0., 0., 0.); }
                (d, a)
            }
            Mat::Glass(ior) => {
                let eta = if h.front { 1.0 / ior } else { ior };
                let u = ray.d.unit();
                let cos = (-u).dot(h.n).min(1.0);
                let sin = (1.0 - cos * cos).sqrt();
                let d = if eta * sin > 1.0 || schlick(cos, eta) > rng.next() {
                    reflect(u, h.n)
                } else {
                    refract(u, h.n, eta)
                };
                (d, V3(1., 1., 1.))
            }
        };
        throughput = throughput.mul(atten);
        // Russian roulette after a few bounces keeps deep paths unbiased but cheap
        if depth > 3 {
            let p = throughput.0.max(throughput.1).max(throughput.2).min(0.95);
            if rng.next() > p { return V3(0., 0., 0.); }
            throughput = throughput / p;
        }
        ray = Ray { o: h.p, d: dir };
    }
    V3(0., 0., 0.)
}

// ---------------------------------------------------------------- camera
struct Camera { origin: V3, ll: V3, h: V3, v: V3, u: V3, lens: f64 }
impl Camera {
    fn new(from: V3, at: V3, vfov: f64, aspect: f64, aperture: f64, focus: f64) -> Camera {
        let hh = (vfov.to_radians() / 2.0).tan();
        let (vh, vw) = (2.0 * hh, 2.0 * hh * aspect);
        let w = (from - at).unit();
        let u = V3(0., 1., 0.).cross(w).unit();
        let v = w.cross(u);
        let h = u * (vw * focus);
        let vv = v * (vh * focus);
        Camera { origin: from, ll: from - h / 2.0 - vv / 2.0 - w * focus, h, v: vv, u, lens: aperture / 2.0 }
    }
    fn ray(&self, s: f64, t: f64, rng: &mut Rng) -> Ray {
        let rd = rng.in_unit_disk() * self.lens;
        let off = self.u * rd.0 + self.v.unit() * rd.1;
        Ray { o: self.origin + off, d: self.ll + self.h * s + self.v * t - self.origin - off }
    }
}

// ---------------------------------------------------------------- scene
fn scene(seed: u64) -> Vec<Sphere> {
    let mut rng = Rng(seed);
    let mut s = vec![
        Sphere { c: V3(0., -1000., 0.), r: 1000., m: Mat::Checker(V3(0.75, 0.75, 0.78), V3(0.12, 0.12, 0.15), 1.0) },
        Sphere { c: V3(0., 1., 0.), r: 1.0, m: Mat::Glass(1.5) },
        Sphere { c: V3(0., 1., 0.), r: -0.92, m: Mat::Glass(1.5) }, // hollow glass bubble
        Sphere { c: V3(-4., 1., 0.), r: 1.0, m: Mat::Diffuse(V3(0.7, 0.25, 0.15)) },
        Sphere { c: V3(4., 1., 0.), r: 1.0, m: Mat::Metal(V3(0.85, 0.8, 0.7), 0.0) },
        Sphere { c: V3(0., 7., -3.), r: 2.0, m: Mat::Light(V3(5.0, 4.6, 4.0)) },
    ];
    let palette = [V3(8., 2., 1.5), V3(1.5, 4., 9.), V3(2., 8., 3.), V3(8., 6., 1.5), V3(6., 1.5, 8.)];
    for a in -11..11 {
        for b in -11..11 {
            let c = V3(a as f64 + 0.9 * rng.next(), 0.2, b as f64 + 0.9 * rng.next());
            if (c - V3(4., 0.2, 0.)).len() < 1.2 || (c - V3(0., 0.2, 0.)).len() < 1.2 || (c - V3(-4., 0.2, 0.)).len() < 1.2 {
                continue;
            }
            let k = rng.next();
            let m = if k < 0.55 {
                Mat::Diffuse(V3(rng.next() * rng.next(), rng.next() * rng.next(), rng.next() * rng.next()))
            } else if k < 0.78 {
                Mat::Metal(V3(rng.range(0.5, 1.), rng.range(0.5, 1.), rng.range(0.5, 1.)), rng.range(0., 0.4))
            } else if k < 0.9 {
                Mat::Glass(1.5)
            } else {
                Mat::Light(palette[(rng.next() * palette.len() as f64) as usize % palette.len()])
            };
            s.push(Sphere { c, r: 0.2, m });
        }
    }
    s
}

// ---------------------------------------------------------------- PNG encoder (no crates)
fn crc32(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for i in 0..256u32 {
        let mut c = i;
        for _ in 0..8 { c = if c & 1 != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }; }
        table[i as usize] = c;
    }
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data { crc = table[((crc ^ b as u32) & 0xFF) as usize] ^ (crc >> 8); }
    crc ^ 0xFFFF_FFFF
}
fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &x in data { a = (a + x as u32) % 65521; b = (b + a) % 65521; }
    (b << 16) | a
}
fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let mut c = kind.to_vec();
    c.extend_from_slice(data);
    out.extend_from_slice(&c);
    out.extend_from_slice(&crc32(&c).to_be_bytes());
}
fn encode_png(w: usize, h: usize, rgb: &[u8]) -> Vec<u8> {
    // each scanline is prefixed with filter byte 0 (None); deflate uses stored blocks
    let mut raw = Vec::with_capacity(h * (w * 3 + 1));
    for y in 0..h { raw.push(0); raw.extend_from_slice(&rgb[y * w * 3..(y + 1) * w * 3]); }
    let mut z = vec![0x78, 0x01];
    for (i, block) in raw.chunks(65535).enumerate() {
        let last = (i + 1) * 65535 >= raw.len();
        z.push(last as u8);
        let n = block.len() as u16;
        z.extend_from_slice(&n.to_le_bytes());
        z.extend_from_slice(&(!n).to_le_bytes());
        z.extend_from_slice(block);
    }
    z.extend_from_slice(&adler32(&raw).to_be_bytes());
    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&(w as u32).to_be_bytes());
    ihdr.extend_from_slice(&(h as u32).to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    chunk(&mut png, b"IHDR", &ihdr);
    chunk(&mut png, b"IDAT", &z);
    chunk(&mut png, b"IEND", &[]);
    png
}

// ACES filmic approximation (Narkowicz 2015) + gamma 2.2
fn tonemap(c: f64) -> u8 {
    let x = c * 0.8;
    let y = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
    (y.clamp(0.0, 1.0).powf(1.0 / 2.2) * 255.0 + 0.5) as u8
}

// ---------------------------------------------------------------- main
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let get = |flag: &str, def: usize| -> usize {
        args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).and_then(|v| v.parse().ok()).unwrap_or(def)
    };
    let width = get("--width", 960);
    let height = width * 9 / 16;
    let spp = get("--spp", 128);
    let depth = get("--depth", 16) as u32;
    let seed = get("--seed", 42) as u64;
    let out = args.iter().position(|a| a == "--out").and_then(|i| args.get(i + 1)).cloned().unwrap_or("out.png".into());
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);

    let world = Arc::new(Bvh::new(scene(seed)));
    let from = V3(13., 2.2, 3.);
    let at = V3(0., 0.6, 0.);
    let cam = Arc::new(Camera::new(from, at, 20.0, width as f64 / height as f64, 0.1, 10.0));

    eprintln!("scene: {} spheres, {} BVH nodes | {}x{} @ {} spp, depth {} | {} threads",
        world.spheres.len(), world.nodes, width, height, spp, depth, threads);

    let next_row = Arc::new(AtomicUsize::new(0));
    let done = Arc::new(AtomicUsize::new(0));
    let start = Instant::now();
    let mut handles = Vec::new();
    for tid in 0..threads {
        let (world, cam, next_row, done) = (world.clone(), cam.clone(), next_row.clone(), done.clone());
        handles.push(std::thread::spawn(move || {
            let mut rows = Vec::new();
            loop {
                let y = next_row.fetch_add(1, Ordering::Relaxed);
                if y >= height { break; }
                let mut rng = Rng(0x9E3779B97F4A7C15 ^ ((y as u64 + 1) * 0x100000001B3) ^ tid as u64);
                let mut row = vec![0u8; width * 3];
                for x in 0..width {
                    let mut c = V3(0., 0., 0.);
                    for _ in 0..spp {
                        let s = (x as f64 + rng.next()) / (width - 1) as f64;
                        let t = ((height - 1 - y) as f64 + rng.next()) / (height - 1) as f64;
                        let r = cam.ray(s, t, &mut rng);
                        let l = trace(&world, r, &mut rng, depth);
                        // clamp fireflies from tiny bright lights
                        c = c + V3(l.0.min(20.), l.1.min(20.), l.2.min(20.));
                    }
                    c = c / spp as f64;
                    row[x * 3] = tonemap(c.0);
                    row[x * 3 + 1] = tonemap(c.1);
                    row[x * 3 + 2] = tonemap(c.2);
                }
                rows.push((y, row));
                let d = done.fetch_add(1, Ordering::Relaxed) + 1;
                if tid == 0 { eprint!("\r  {:5.1}%", 100.0 * d as f64 / height as f64); }
            }
            rows
        }));
    }
    let mut img = vec![0u8; width * height * 3];
    for h in handles {
        for (y, row) in h.join().unwrap() { img[y * width * 3..(y + 1) * width * 3].copy_from_slice(&row); }
    }
    let secs = start.elapsed().as_secs_f64();
    let rays = (width * height * spp) as f64;
    eprintln!("\r  done in {:.1}s ({:.2} M camera rays/s)", secs, rays / secs / 1e6);
    std::fs::write(&out, encode_png(width, height, &img)).expect("write png");
    eprintln!("wrote {}", out);
}
