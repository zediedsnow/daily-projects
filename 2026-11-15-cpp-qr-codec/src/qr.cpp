#include "qr.hpp"

#include <algorithm>
#include <climits>
#include <cstdio>
#include <cstdlib>

#include "reedsolomon.hpp"

namespace qr {

// ---------------------------------------------------------------- tables (ISO 18004 table 9)

static const int8_t ECC_PER_BLOCK[4][41] = {
    {-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
    {-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28},
    {-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
    {-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
};
static const int8_t NUM_BLOCKS[4][41] = {
    {-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25},
    {-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49},
    {-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68},
    {-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81},
};

static const char* ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

static int alnumIndex(uint8_t c) {
    for (int i = 0; i < 45; i++)
        if ((uint8_t)ALNUM[i] == c) return i;
    return -1;
}
static bool isDigit(uint8_t c) { return c >= '0' && c <= '9'; }

const char* eccName(Ecc e) { static const char* n[4] = {"L", "M", "Q", "H"}; return n[(int)e]; }
const char* modeName(Mode m) { return m == Mode::Numeric ? "numeric" : m == Mode::Alnum ? "alphanumeric" : "byte"; }
bool parseEcc(const std::string& s, Ecc* out) {
    if (s.size() != 1) return false;
    switch (s[0] | 0x20) {
        case 'l': *out = Ecc::L; return true;
        case 'm': *out = Ecc::M; return true;
        case 'q': *out = Ecc::Q; return true;
        case 'h': *out = Ecc::H; return true;
    }
    return false;
}

static int formatBitsOf(Ecc e) { static const int f[4] = {1, 0, 3, 2}; return f[(int)e]; }
static Ecc eccFromFormatBits(int b) { static const Ecc m[4] = {Ecc::M, Ecc::L, Ecc::H, Ecc::Q}; return m[b & 3]; }

static int numRawDataModules(int ver) {
    int r = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
        int na = ver / 7 + 2;
        r -= (25 * na - 10) * na - 55;
        if (ver >= 7) r -= 36;
    }
    return r;
}
int numRawCodewords(int v) { return numRawDataModules(v) / 8; }
int eccCodewordsPerBlock(int v, Ecc e) { return ECC_PER_BLOCK[(int)e][v]; }
int numBlocks(int v, Ecc e) { return NUM_BLOCKS[(int)e][v]; }
int numDataCodewords(int v, Ecc e) { return numRawCodewords(v) - eccCodewordsPerBlock(v, e) * numBlocks(v, e); }

int charCountBits(Mode m, int ver) {
    int i = ver <= 9 ? 0 : ver <= 26 ? 1 : 2;
    static const int t[3][3] = {{10, 12, 14}, {9, 11, 13}, {8, 16, 16}};
    return t[(int)m][i];
}
int segmentBits(Mode m, int n) {
    switch (m) {
        case Mode::Numeric: return 10 * (n / 3) + (n % 3 == 1 ? 4 : n % 3 == 2 ? 7 : 0);
        case Mode::Alnum: return 11 * (n / 2) + 6 * (n % 2);
        default: return 8 * n;
    }
}
static int modeIndicator(Mode m) { return m == Mode::Numeric ? 1 : m == Mode::Alnum ? 2 : 4; }

// ---------------------------------------------------------------- bit buffer

struct Bits {
    std::vector<uint8_t> b;
    void put(uint32_t v, int n) { for (int i = n - 1; i >= 0; i--) b.push_back((v >> i) & 1); }
};

// ---------------------------------------------------------------- segmentation

// Exact shortest bitstream for a given version: DP over segment boundaries.
// cost[j] = min over i<j and modes m that can encode text[i..j) of cost[i] + header + payload.
static std::vector<Segment> optimalSegments(const std::vector<uint8_t>& t, int ver, long* totalBits) {
    const int n = (int)t.size();
    std::vector<long> cost(n + 1, LONG_MAX / 2);
    std::vector<int> from(n + 1, -1), how(n + 1, -1);
    cost[0] = 0;
    for (int j = 1; j <= n; j++) {
        for (int m = 0; m < 3; m++) {
            Mode mode = (Mode)m;
            int maxLen = (1 << charCountBits(mode, ver)) - 1;
            long hdr = 4 + charCountBits(mode, ver);
            for (int i = j - 1; i >= 0 && j - i <= maxLen; i--) {
                uint8_t c = t[i];
                if (mode == Mode::Numeric && !isDigit(c)) break;
                if (mode == Mode::Alnum && alnumIndex(c) < 0) break;
                long c2 = cost[i] + hdr + segmentBits(mode, j - i);
                if (c2 < cost[j]) { cost[j] = c2; from[j] = i; how[j] = m; }
            }
        }
    }
    std::vector<Segment> segs;
    for (int j = n; j > 0; j = from[j])
        segs.insert(segs.begin(), Segment{(Mode)how[j], std::vector<uint8_t>(t.begin() + from[j], t.begin() + j)});
    *totalBits = n == 0 ? 0 : cost[n];
    return segs;
}

static std::vector<Segment> singleSegment(const std::vector<uint8_t>& t, int ver, long* totalBits) {
    Mode m = Mode::Numeric;
    if (!std::all_of(t.begin(), t.end(), isDigit)) m = Mode::Alnum;
    if (m == Mode::Alnum && !std::all_of(t.begin(), t.end(), [](uint8_t c) { return alnumIndex(c) >= 0; })) m = Mode::Byte;
    if ((long)t.size() >= (1L << charCountBits(m, ver))) { *totalBits = LONG_MAX / 2; return {}; }
    *totalBits = 4 + charCountBits(m, ver) + segmentBits(m, (int)t.size());
    return {Segment{m, t}};
}

static void appendSegment(Bits& bb, const Segment& s, int ver) {
    bb.put(modeIndicator(s.mode), 4);
    bb.put((uint32_t)s.chars.size(), charCountBits(s.mode, ver));
    const auto& c = s.chars;
    size_t i = 0;
    switch (s.mode) {
        case Mode::Numeric:
            for (; i + 3 <= c.size(); i += 3) bb.put((c[i] - '0') * 100 + (c[i + 1] - '0') * 10 + (c[i + 2] - '0'), 10);
            if (c.size() - i == 2) bb.put((c[i] - '0') * 10 + (c[i + 1] - '0'), 7);
            else if (c.size() - i == 1) bb.put(c[i] - '0', 4);
            break;
        case Mode::Alnum:
            for (; i + 2 <= c.size(); i += 2) bb.put(alnumIndex(c[i]) * 45 + alnumIndex(c[i + 1]), 11);
            if (i < c.size()) bb.put(alnumIndex(c[i]), 6);
            break;
        case Mode::Byte:
            for (uint8_t x : c) bb.put(x, 8);
            break;
    }
}

// ---------------------------------------------------------------- symbol geometry

struct Grid {
    int size;
    std::vector<uint8_t> mod, fn;
    explicit Grid(int s) : size(s), mod(s * s, 0), fn(s * s, 0) {}
    uint8_t& m(int x, int y) { return mod[y * size + x]; }
    bool isFn(int x, int y) const { return fn[y * size + x]; }
    void setFn(int x, int y, bool dark) { mod[y * size + x] = dark; fn[y * size + x] = 1; }
};

static std::vector<int> alignmentPositions(int ver) {
    if (ver == 1) return {};
    int na = ver / 7 + 2, size = ver * 4 + 17;
    int step = ver == 32 ? 26 : (ver * 4 + na * 2 + 1) / (na * 2 - 2) * 2;
    std::vector<int> r(na);
    r[0] = 6;
    for (int i = na - 1, pos = size - 7; i >= 1; i--, pos -= step) r[i] = pos;
    return r;
}

static int formatCode(int data5) {
    int rem = data5;
    for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return ((data5 << 10) | rem) ^ 0x5412;
}
static int versionCode(int ver) {
    int rem = ver;
    for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    return (ver << 12) | rem;
}

static void drawFormat(Grid& g, Ecc ecc, int mask) {
    int bits = formatCode(formatBitsOf(ecc) << 3 | mask);
    auto bit = [&](int i) { return ((bits >> i) & 1) != 0; };
    int s = g.size;
    for (int i = 0; i <= 5; i++) g.setFn(8, i, bit(i));
    g.setFn(8, 7, bit(6));
    g.setFn(8, 8, bit(7));
    g.setFn(7, 8, bit(8));
    for (int i = 9; i < 15; i++) g.setFn(14 - i, 8, bit(i));
    for (int i = 0; i < 8; i++) g.setFn(s - 1 - i, 8, bit(i));
    for (int i = 8; i < 15; i++) g.setFn(8, s - 15 + i, bit(i));
    g.setFn(8, s - 8, true);  // the "dark module"
}

static void drawFunctionPatterns(Grid& g, int ver) {
    int s = g.size;
    for (int i = 0; i < s; i++) { g.setFn(6, i, i % 2 == 0); g.setFn(i, 6, i % 2 == 0); }
    auto finder = [&](int cx, int cy) {
        for (int dy = -4; dy <= 4; dy++)
            for (int dx = -4; dx <= 4; dx++) {
                int x = cx + dx, y = cy + dy;
                if (x < 0 || y < 0 || x >= s || y >= s) continue;
                int d = std::max(std::abs(dx), std::abs(dy));
                g.setFn(x, y, d != 2 && d != 4);
            }
    };
    finder(3, 3); finder(s - 4, 3); finder(3, s - 4);
    auto al = alignmentPositions(ver);
    int n = (int)al.size();
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) {
            if ((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0)) continue;
            for (int dy = -2; dy <= 2; dy++)
                for (int dx = -2; dx <= 2; dx++) g.setFn(al[i] + dx, al[j] + dy, std::max(std::abs(dx), std::abs(dy)) != 1);
        }
    drawFormat(g, Ecc::L, 0);  // placeholder, reserves the area
    if (ver >= 7) {
        int bits = versionCode(ver);
        for (int i = 0; i < 18; i++) {
            bool b = (bits >> i) & 1;
            int a = s - 11 + i % 3, c = i / 3;
            g.setFn(a, c, b);
            g.setFn(c, a, b);
        }
    }
}

std::vector<uint8_t> functionMap(int ver) {
    Grid g(ver * 4 + 17);
    drawFunctionPatterns(g, ver);
    return g.fn;
}

// Visits data modules in placement order: two-column strips from the right, snaking up and down.
template <class F>
static void forEachDataModule(const Grid& g, F f) {
    int s = g.size;
    for (int right = s - 1; right >= 1; right -= 2) {
        if (right == 6) right = 5;
        bool upward = ((right + 1) & 2) == 0;
        for (int v = 0; v < s; v++)
            for (int j = 0; j < 2; j++) {
                int x = right - j, y = upward ? s - 1 - v : v;
                if (!g.isFn(x, y)) f(x, y);
            }
    }
}

std::vector<int> dataModuleOrder(int ver) {
    Grid g(ver * 4 + 17);
    drawFunctionPatterns(g, ver);
    std::vector<int> r;
    forEachDataModule(g, [&](int x, int y) { r.push_back(y * g.size + x); });
    return r;
}

std::vector<std::pair<int, bool>> codewordBlocks(int ver, Ecc ecc) {
    int nb = numBlocks(ver, ecc), eccLen = eccCodewordsPerBlock(ver, ecc), raw = numRawCodewords(ver);
    int numShort = nb - raw % nb, shortLen = raw / nb;
    std::vector<std::pair<int, bool>> r;
    for (int i = 0; i <= shortLen; i++)
        for (int j = 0; j < nb; j++)
            if (i != shortLen - eccLen || j >= numShort) r.push_back({j, i > shortLen - eccLen});
    return r;
}

static bool maskBit(int mask, int x, int y) {
    switch (mask) {
        case 0: return (x + y) % 2 == 0;
        case 1: return y % 2 == 0;
        case 2: return x % 3 == 0;
        case 3: return (x + y) % 3 == 0;
        case 4: return (x / 3 + y / 2) % 2 == 0;
        case 5: return x * y % 2 + x * y % 3 == 0;
        case 6: return (x * y % 2 + x * y % 3) % 2 == 0;
        default: return ((x + y) % 2 + x * y % 3) % 2 == 0;
    }
}
static void applyMask(Grid& g, int mask) {
    for (int y = 0; y < g.size; y++)
        for (int x = 0; x < g.size; x++)
            if (!g.isFn(x, y) && maskBit(mask, x, y)) g.m(x, y) ^= 1;
}

// ISO 18004 section 7.8.3 penalty rules N1..N4.
static long penalty(Grid& g) {
    const int s = g.size;
    long p = 0;
    for (int pass = 0; pass < 2; pass++) {
        auto at = [&](int line, int i) -> int { return pass == 0 ? g.m(i, line) : g.m(line, i); };
        for (int line = 0; line < s; line++) {
            int run = 1;
            for (int i = 1; i <= s; i++) {
                if (i < s && at(line, i) == at(line, i - 1)) run++;
                else { if (run >= 5) p += 3 + (run - 5); run = 1; }
            }
            // N3: 1:1:3:1:1 finder-like pattern with 4 light modules on either side.
            static const int pat[7] = {1, 0, 1, 1, 1, 0, 1};
            for (int i = 0; i + 7 <= s; i++) {
                bool ok = true;
                for (int k = 0; k < 7 && ok; k++) ok = at(line, i + k) == pat[k];
                if (!ok) continue;
                auto light = [&](int a, int b) {
                    for (int k = a; k < b; k++) if (k >= 0 && k < s && at(line, k)) return false;
                    return true;
                };
                if (light(i - 4, i) || light(i + 7, i + 11)) p += 40;
            }
        }
    }
    for (int y = 0; y + 1 < s; y++)
        for (int x = 0; x + 1 < s; x++) {
            int c = g.m(x, y);
            if (c == g.m(x + 1, y) && c == g.m(x, y + 1) && c == g.m(x + 1, y + 1)) p += 3;
        }
    long dark = 0, total = (long)s * s;
    for (uint8_t v : g.mod) dark += v;
    long k = (std::labs(dark * 20 - total * 10) + total - 1) / total - 1;
    p += k * 10;
    return p;
}

// Split into blocks, append RS ECC to each, interleave.
static std::vector<uint8_t> addEccAndInterleave(const std::vector<uint8_t>& data, int ver, Ecc ecc) {
    int nb = numBlocks(ver, ecc), eccLen = eccCodewordsPerBlock(ver, ecc), raw = numRawCodewords(ver);
    int numShort = nb - raw % nb, shortLen = raw / nb;
    auto gen = rs::generator(eccLen);
    std::vector<std::vector<uint8_t>> blocks;
    for (int i = 0, k = 0; i < nb; i++) {
        int dlen = shortLen - eccLen + (i < numShort ? 0 : 1);
        std::vector<uint8_t> d(data.begin() + k, data.begin() + k + dlen);
        k += dlen;
        auto e = rs::remainder(d, gen);
        if (i < numShort) d.push_back(0);
        d.insert(d.end(), e.begin(), e.end());
        blocks.push_back(d);
    }
    std::vector<uint8_t> out;
    for (size_t i = 0; i < blocks[0].size(); i++)
        for (int j = 0; j < nb; j++)
            if ((int)i != shortLen - eccLen || j >= numShort) out.push_back(blocks[j][i]);
    return out;
}

// ---------------------------------------------------------------- encoder

Symbol encode(const std::vector<uint8_t>& data, const Options& opt) {
    if (opt.minVersion < 1 || opt.maxVersion > 40 || opt.minVersion > opt.maxVersion) throw Error("invalid version range");
    if (opt.mask < -1 || opt.mask > 7) throw Error("mask must be 0-7");
    Ecc ecc = opt.ecc;
    int ver = 0;
    long bits = 0;
    std::vector<Segment> segs;
    for (int v = opt.minVersion; v <= opt.maxVersion; v++) {
        segs = opt.optimize ? optimalSegments(data, v, &bits) : singleSegment(data, v, &bits);
        if (bits <= numDataCodewords(v, ecc) * 8L) { ver = v; break; }
    }
    if (!ver) throw Error("data too long: " + std::to_string(data.size()) + " bytes do not fit in version " +
                          std::to_string(opt.maxVersion) + "-" + eccName(ecc));
    if (opt.boost)
        for (int e = (int)ecc + 1; e <= 3; e++)
            if (bits <= numDataCodewords(ver, (Ecc)e) * 8L) ecc = (Ecc)e;

    Bits bb;
    for (auto& s : segs) appendSegment(bb, s, ver);
    int cap = numDataCodewords(ver, ecc) * 8;
    bb.put(0, std::min(4, cap - (int)bb.b.size()));
    bb.put(0, (8 - (int)bb.b.size() % 8) % 8);
    std::vector<uint8_t> cw;
    for (size_t i = 0; i < bb.b.size(); i += 8) {
        uint8_t v = 0;
        for (int k = 0; k < 8; k++) v = v << 1 | bb.b[i + k];
        cw.push_back(v);
    }
    for (uint8_t pad = 0xEC; (int)cw.size() < cap / 8; pad ^= 0xEC ^ 0x11) cw.push_back(pad);

    auto all = addEccAndInterleave(cw, ver, ecc);
    Grid g(ver * 4 + 17);
    drawFunctionPatterns(g, ver);
    size_t i = 0;
    forEachDataModule(g, [&](int x, int y) {
        if (i < all.size() * 8) g.m(x, y) = (all[i >> 3] >> (7 - (i & 7))) & 1;
        i++;  // remainder bits stay light
    });

    Symbol sym;
    for (auto& p : sym.penalty) p = -1;
    int mask = opt.mask;
    if (mask < 0) {
        long best = LONG_MAX;
        for (int m = 0; m < 8; m++) {
            applyMask(g, m);
            drawFormat(g, ecc, m);
            long p = penalty(g);
            sym.penalty[m] = p;
            if (p < best) { best = p; mask = m; }
            applyMask(g, m);
        }
    }
    applyMask(g, mask);
    drawFormat(g, ecc, mask);
    if (opt.mask >= 0) sym.penalty[mask] = penalty(g);

    sym.version = ver; sym.size = g.size; sym.mask = mask; sym.ecc = ecc;
    sym.modules = g.mod; sym.segments = segs;
    sym.dataBits = (int)bits; sym.capacityBits = cap;
    return sym;
}

// ---------------------------------------------------------------- decoder

Decoded decode(int size, const std::vector<uint8_t>& mods) {
    if (size < 21 || size > 177 || (size - 17) % 4 != 0) throw Error("bad symbol size " + std::to_string(size));
    if ((int)mods.size() != size * size) throw Error("module count does not match size");
    const int ver = (size - 17) / 4;
    auto at = [&](int x, int y) { return (int)(mods[y * size + x] & 1); };

    // Format information: two copies, BCH(15,5); choose the nearest valid codeword.
    int f1 = 0, f2 = 0;
    for (int i = 0; i <= 5; i++) f1 |= at(8, i) << i;
    f1 |= at(8, 7) << 6 | at(8, 8) << 7 | at(7, 8) << 8;
    for (int i = 9; i < 15; i++) f1 |= at(14 - i, 8) << i;
    for (int i = 0; i < 8; i++) f2 |= at(size - 1 - i, 8) << i;
    for (int i = 8; i < 15; i++) f2 |= at(8, size - 15 + i) << i;
    int bestD = 99, best = -1;
    for (int d = 0; d < 32; d++) {
        int c = formatCode(d);
        int dist = std::min(__builtin_popcount(c ^ f1), __builtin_popcount(c ^ f2));
        if (dist < bestD) { bestD = dist; best = d; }
    }
    if (bestD > 3) throw Error("format information unreadable");
    Decoded out;
    out.version = ver;
    out.ecc = eccFromFormatBits(best >> 3);
    out.mask = best & 7;
    out.formatDistance = bestD;

    Grid g(size);
    drawFunctionPatterns(g, ver);
    for (int y = 0; y < size; y++)
        for (int x = 0; x < size; x++)
            if (!g.isFn(x, y)) g.m(x, y) = at(x, y);
    applyMask(g, out.mask);

    int raw = numRawCodewords(ver);
    std::vector<uint8_t> cw(raw, 0);
    size_t i = 0;
    forEachDataModule(g, [&](int x, int y) {
        if ((int)(i >> 3) < raw) cw[i >> 3] |= g.m(x, y) << (7 - (i & 7));
        i++;
    });

    // De-interleave (the exact inverse of addEccAndInterleave).
    Ecc ecc = out.ecc;
    int nb = numBlocks(ver, ecc), eccLen = eccCodewordsPerBlock(ver, ecc);
    int numShort = nb - raw % nb, shortLen = raw / nb;
    std::vector<std::vector<uint8_t>> blocks(nb);
    for (int j = 0; j < nb; j++) blocks[j].resize(shortLen + (j < numShort ? 0 : 1));
    size_t k = 0;
    for (int ii = 0; ii <= shortLen; ii++)
        for (int j = 0; j < nb; j++) {
            if (ii == shortLen - eccLen && j < numShort) continue;
            int idx = (j < numShort && ii > shortLen - eccLen) ? ii - 1 : ii;
            blocks[j][idx] = cw[k++];
        }
    std::vector<uint8_t> data;
    out.blocks = nb;
    for (int j = 0; j < nb; j++) {
        int r = rs::decode(blocks[j], eccLen);
        if (r < 0) throw Error("block " + std::to_string(j + 1) + "/" + std::to_string(nb) + " has too many errors (max " +
                               std::to_string(eccLen / 2) + " bytes)");
        out.errorsPerBlock.push_back(r);
        out.correctedBytes += r;
        data.insert(data.end(), blocks[j].begin(), blocks[j].end() - eccLen);
    }

    // Parse the bit stream.
    size_t pos = 0, total = data.size() * 8;
    auto read = [&](int n) {
        if (pos + n > total) throw Error("bit stream truncated");
        uint32_t v = 0;
        for (int q = 0; q < n; q++, pos++) v = v << 1 | ((data[pos >> 3] >> (7 - (pos & 7))) & 1);
        return v;
    };
    while (pos + 4 <= total) {
        int mi = read(4);
        if (mi == 0) break;
        Segment seg{Mode::Byte, {}};
        if (mi == 1) {
            seg.mode = Mode::Numeric;
            int n = read(charCountBits(Mode::Numeric, ver));
            auto digits = [&](int bitsN, int count, int limit) {
                uint32_t v = read(bitsN);
                if ((int)v >= limit) throw Error("invalid numeric group");
                char buf[4];
                snprintf(buf, sizeof buf, "%0*u", count, v);
                seg.chars.insert(seg.chars.end(), buf, buf + count);
            };
            for (; n >= 3; n -= 3) digits(10, 3, 1000);
            if (n == 2) digits(7, 2, 100);
            else if (n == 1) digits(4, 1, 10);
        } else if (mi == 2) {
            seg.mode = Mode::Alnum;
            int n = read(charCountBits(Mode::Alnum, ver));
            for (; n >= 2; n -= 2) {
                uint32_t v = read(11);
                if (v >= 45 * 45) throw Error("invalid alphanumeric pair");
                seg.chars.push_back(ALNUM[v / 45]);
                seg.chars.push_back(ALNUM[v % 45]);
            }
            if (n == 1) {
                uint32_t v = read(6);
                if (v >= 45) throw Error("invalid alphanumeric char");
                seg.chars.push_back(ALNUM[v]);
            }
        } else if (mi == 4) {
            int n = read(charCountBits(Mode::Byte, ver));
            for (int q = 0; q < n; q++) seg.chars.push_back((uint8_t)read(8));
        } else if (mi == 7) {
            uint32_t a = read(8);
            if ((a & 0x80) == 0) out.eci = a;
            else if ((a & 0xC0) == 0x80) out.eci = (a & 0x3F) << 8 | read(8);
            else out.eci = (a & 0x1F) << 16 | read(16);
            continue;
        } else {
            throw Error("unsupported mode indicator " + std::to_string(mi));
        }
        out.text.insert(out.text.end(), seg.chars.begin(), seg.chars.end());
        out.segments.push_back(std::move(seg));
    }
    return out;
}

}  // namespace qr
