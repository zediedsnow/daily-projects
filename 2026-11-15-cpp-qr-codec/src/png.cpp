#include "png.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

namespace png {

static uint32_t crc32(const uint8_t* d, size_t n, uint32_t c = 0) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t k = i;
            for (int j = 0; j < 8; j++) k = (k & 1) ? 0xEDB88320u ^ (k >> 1) : k >> 1;
            table[i] = k;
        }
        init = true;
    }
    c ^= 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = table[(c ^ d[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

std::vector<uint8_t> deflate(const std::vector<uint8_t>& in, size_t stride);

static void be32(std::vector<uint8_t>& v, uint32_t x) {
    for (int s = 24; s >= 0; s -= 8) v.push_back((x >> s) & 0xFF);
}

static void chunk(std::vector<uint8_t>& out, const char* type, const std::vector<uint8_t>& body) {
    be32(out, (uint32_t)body.size());
    std::vector<uint8_t> tb(type, type + 4);
    tb.insert(tb.end(), body.begin(), body.end());
    out.insert(out.end(), tb.begin(), tb.end());
    be32(out, crc32(tb.data(), tb.size()));
}

void write(const std::string& path, const Image& img) {
    std::vector<uint8_t> raw;
    for (int y = 0; y < img.height; y++) {
        raw.push_back(0);  // filter: none
        raw.insert(raw.end(), img.gray.begin() + (size_t)y * img.width, img.gray.begin() + (size_t)(y + 1) * img.width);
    }
    std::vector<uint8_t> z{0x78, 0x01};
    auto body = deflate(raw, (size_t)img.width + 1);
    z.insert(z.end(), body.begin(), body.end());
    uint32_t a = 1, b = 0;
    for (uint8_t c : raw) { a = (a + c) % 65521; b = (b + a) % 65521; }
    be32(z, b << 16 | a);

    std::vector<uint8_t> out{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    std::vector<uint8_t> ihdr;
    be32(ihdr, img.width); be32(ihdr, img.height);
    ihdr.insert(ihdr.end(), {8, 0, 0, 0, 0});  // 8-bit grayscale
    chunk(out, "IHDR", ihdr);
    chunk(out, "IDAT", z);
    chunk(out, "IEND", {});
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) throw std::runtime_error("cannot write " + path);
    fwrite(out.data(), 1, out.size(), f);
    fclose(f);
}

// ------------------------------------------------------------------ inflate (RFC 1951)

namespace {
struct In {
    const uint8_t* d; size_t n, pos = 0;
    uint32_t buf = 0; int cnt = 0;
    int bits(int need) {
        uint32_t v = buf;
        while (cnt < need) {
            if (pos >= n) throw std::runtime_error("inflate: unexpected end of data");
            v |= (uint32_t)d[pos++] << cnt;
            cnt += 8;
        }
        buf = v >> need; cnt -= need;
        return (int)(v & ((1u << need) - 1));
    }
};
struct Huff { short count[16]; short sym[320]; };

int build(Huff& h, const short* len, int n) {
    std::memset(h.count, 0, sizeof h.count);
    for (int i = 0; i < n; i++) h.count[len[i]]++;
    if (h.count[0] == n) return 0;
    int left = 1;
    for (int l = 1; l < 16; l++) { left <<= 1; left -= h.count[l]; if (left < 0) return -1; }
    short offs[16]; offs[1] = 0;
    for (int l = 1; l < 15; l++) offs[l + 1] = offs[l] + h.count[l];
    for (int i = 0; i < n; i++) if (len[i]) h.sym[offs[len[i]]++] = (short)i;
    return left;
}
int decodeSym(In& s, const Huff& h) {
    int code = 0, first = 0, index = 0;
    for (int l = 1; l < 16; l++) {
        code |= s.bits(1);
        int c = h.count[l];
        if (code - c < first) return h.sym[index + (code - first)];
        index += c; first += c; first <<= 1; code <<= 1;
    }
    throw std::runtime_error("inflate: bad Huffman code");
}

const short LBASE[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
const short LEXT[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
const short DBASE[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
const short DEXT[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

void codes(In& s, std::vector<uint8_t>& out, const Huff& lc, const Huff& dc) {
    for (;;) {
        int sym = decodeSym(s, lc);
        if (sym < 256) { out.push_back((uint8_t)sym); continue; }
        if (sym == 256) return;
        sym -= 257;
        if (sym >= 29) throw std::runtime_error("inflate: bad length symbol");
        int len = LBASE[sym] + s.bits(LEXT[sym]);
        int ds = decodeSym(s, dc);
        if (ds >= 30) throw std::runtime_error("inflate: bad distance symbol");
        size_t dist = DBASE[ds] + s.bits(DEXT[ds]);
        if (dist > out.size()) throw std::runtime_error("inflate: distance too far back");
        for (int i = 0; i < len; i++) out.push_back(out[out.size() - dist]);
    }
}
}  // namespace

// Deflate with the fixed Huffman code and a two-candidate LZ77: "same as the previous byte"
// (distance 1) and "same as the row above" (distance = stride). QR images are long runs of
// identical rows, so this tiny matcher already shrinks them by 50-100x.
std::vector<uint8_t> deflate(const std::vector<uint8_t>& in, size_t stride) {
    std::vector<uint8_t> out;
    uint32_t acc = 0;
    int nacc = 0;
    auto put = [&](uint32_t v, int n) {  // LSB-first
        acc |= v << nacc;
        nacc += n;
        while (nacc >= 8) { out.push_back(acc & 0xFF); acc >>= 8; nacc -= 8; }
    };
    auto huff = [&](uint32_t code, int len) {  // Huffman codes are sent MSB-first
        uint32_t r = 0;
        for (int i = 0; i < len; i++) r |= ((code >> i) & 1) << (len - 1 - i);
        put(r, len);
    };
    auto lit = [&](int v) {
        if (v < 144) huff(0x30 + v, 8);
        else if (v < 256) huff(0x190 + v - 144, 9);
        else if (v < 280) huff(v - 256, 7);
        else huff(0xC0 + v - 280, 8);
    };
    put(1, 1);  // final block
    put(1, 2);  // fixed Huffman
    for (size_t i = 0; i < in.size();) {
        size_t bestLen = 0, bestDist = 0;
        for (size_t d : {(size_t)1, stride}) {
            if (d == 0 || d > i || d > 32768) continue;
            size_t l = 0;
            while (l < 258 && i + l < in.size() && in[i + l] == in[i + l - d]) l++;
            if (l > bestLen) { bestLen = l; bestDist = d; }
        }
        if (bestLen < 3) { lit(in[i]); i++; continue; }
        int ls = 28;
        while (LBASE[ls] > (int)bestLen) ls--;
        lit(257 + ls);
        put(bestLen - LBASE[ls], LEXT[ls]);
        int ds = 29;
        while (DBASE[ds] > (int)bestDist) ds--;
        huff(ds, 5);
        put(bestDist - DBASE[ds], DEXT[ds]);
        i += bestLen;
    }
    lit(256);
    if (nacc) out.push_back(acc & 0xFF);
    return out;
}

std::vector<uint8_t> inflate(const uint8_t* data, size_t len) {
    In s{data, len};
    std::vector<uint8_t> out;
    int last;
    do {
        last = s.bits(1);
        int type = s.bits(2);
        if (type == 0) {
            s.buf = 0; s.cnt = 0;
            if (s.pos + 4 > s.n) throw std::runtime_error("inflate: truncated stored block");
            unsigned n = s.d[s.pos] | s.d[s.pos + 1] << 8;
            unsigned nn = s.d[s.pos + 2] | s.d[s.pos + 3] << 8;
            if (n != (~nn & 0xFFFF)) throw std::runtime_error("inflate: stored length mismatch");
            s.pos += 4;
            if (s.pos + n > s.n) throw std::runtime_error("inflate: truncated stored block");
            out.insert(out.end(), s.d + s.pos, s.d + s.pos + n);
            s.pos += n;
        } else if (type == 1) {
            static Huff lc, dc;
            static bool init = false;
            if (!init) {
                short l[288];
                for (int i = 0; i < 288; i++) l[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
                build(lc, l, 288);
                for (int i = 0; i < 30; i++) l[i] = 5;
                build(dc, l, 30);
                init = true;
            }
            codes(s, out, lc, dc);
        } else if (type == 2) {
            int nlen = s.bits(5) + 257, ndist = s.bits(5) + 1, ncode = s.bits(4) + 4;
            static const short order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
            short lengths[320] = {0};
            for (int i = 0; i < ncode; i++) lengths[order[i]] = (short)s.bits(3);
            Huff lencode, lc, dc;
            if (build(lencode, lengths, 19) != 0) throw std::runtime_error("inflate: bad code-length code");
            int idx = 0;
            while (idx < nlen + ndist) {
                int sym = decodeSym(s, lencode);
                if (sym < 16) { lengths[idx++] = (short)sym; continue; }
                short v = 0; int rep;
                if (sym == 16) { if (idx == 0) throw std::runtime_error("inflate: repeat with no previous"); v = lengths[idx - 1]; rep = 3 + s.bits(2); }
                else if (sym == 17) rep = 3 + s.bits(3);
                else rep = 11 + s.bits(7);
                if (idx + rep > nlen + ndist) throw std::runtime_error("inflate: too many lengths");
                while (rep--) lengths[idx++] = v;
            }
            int e1 = build(lc, lengths, nlen);
            if (e1 < 0 || (e1 > 0 && nlen - lc.count[0] != 1)) throw std::runtime_error("inflate: bad literal code");
            int e2 = build(dc, lengths + nlen, ndist);
            if (e2 < 0 || (e2 > 0 && ndist - dc.count[0] != 1)) throw std::runtime_error("inflate: bad distance code");
            codes(s, out, lc, dc);
        } else {
            throw std::runtime_error("inflate: invalid block type");
        }
    } while (!last);
    return out;
}

// ------------------------------------------------------------------ reader

static uint32_t rd32(const uint8_t* p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

Image read(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) throw std::runtime_error("cannot open " + path);
    std::vector<uint8_t> file;
    uint8_t tmp[65536];
    size_t r;
    while ((r = fread(tmp, 1, sizeof tmp, f)) > 0) file.insert(file.end(), tmp, tmp + r);
    fclose(f);
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    if (file.size() < 8 || std::memcmp(file.data(), sig, 8) != 0) throw std::runtime_error(path + ": not a PNG file");

    int w = 0, h = 0, depth = 0, ctype = 0;
    std::vector<uint8_t> idat, plte, trns;
    for (size_t p = 8; p + 12 <= file.size();) {
        uint32_t n = rd32(&file[p]);
        if (p + 12 + n > file.size()) throw std::runtime_error("truncated PNG chunk");
        std::string type((const char*)&file[p + 4], 4);
        const uint8_t* body = &file[p + 8];
        if (crc32(&file[p + 4], n + 4) != rd32(body + n)) throw std::runtime_error("PNG CRC mismatch in " + type);
        if (type == "IHDR") {
            w = rd32(body); h = rd32(body + 4); depth = body[8]; ctype = body[9];
            if (body[12] != 0) throw std::runtime_error("interlaced PNGs are not supported");
        } else if (type == "PLTE") plte.assign(body, body + n);
        else if (type == "tRNS") trns.assign(body, body + n);
        else if (type == "IDAT") idat.insert(idat.end(), body, body + n);
        else if (type == "IEND") break;
        p += 12 + n;
    }
    if (w <= 0 || h <= 0 || idat.size() < 6) throw std::runtime_error("PNG has no image data");
    auto raw = inflate(idat.data() + 2, idat.size() - 6);

    int ch = ctype == 0 ? 1 : ctype == 2 ? 3 : ctype == 3 ? 1 : ctype == 4 ? 2 : ctype == 6 ? 4 : 0;
    if (!ch) throw std::runtime_error("unknown PNG colour type");
    size_t stride = ((size_t)w * ch * depth + 7) / 8;
    int bpp = std::max(1, ch * depth / 8);
    if (raw.size() < (stride + 1) * h) throw std::runtime_error("PNG image data too short");
    std::vector<uint8_t> px(stride * h), prev(stride, 0);
    for (int y = 0; y < h; y++) {
        int ft = raw[y * (stride + 1)];
        const uint8_t* src = &raw[y * (stride + 1) + 1];
        uint8_t* dst = &px[y * stride];
        for (size_t x = 0; x < stride; x++) {
            int a = x >= (size_t)bpp ? dst[x - bpp] : 0, b = prev[x], c = x >= (size_t)bpp ? prev[x - bpp] : 0;
            int pred = 0;
            switch (ft) {
                case 0: pred = 0; break;
                case 1: pred = a; break;
                case 2: pred = b; break;
                case 3: pred = (a + b) / 2; break;
                case 4: {
                    int p = a + b - c, pa = std::abs(p - a), pb = std::abs(p - b), pc = std::abs(p - c);
                    pred = (pa <= pb && pa <= pc) ? a : pb <= pc ? b : c;
                    break;
                }
                default: throw std::runtime_error("bad PNG filter type");
            }
            dst[x] = (uint8_t)(src[x] + pred);
        }
        std::memcpy(prev.data(), dst, stride);
    }

    Image img; img.width = w; img.height = h; img.gray.resize((size_t)w * h);
    auto sample = [&](const uint8_t* row, int i) -> int {  // i-th sample in the row, scaled to 0..255
        if (depth == 8) return row[i];
        if (depth == 16) return row[2 * i];
        int perByte = 8 / depth, v = (row[i / perByte] >> (8 - depth * (i % perByte + 1))) & ((1 << depth) - 1);
        return ctype == 3 ? v : v * 255 / ((1 << depth) - 1);
    };
    for (int y = 0; y < h; y++) {
        const uint8_t* row = &px[y * stride];
        for (int x = 0; x < w; x++) {
            int r, g, b, a = 255;
            if (ctype == 0 || ctype == 4) { r = g = b = sample(row, x * ch); if (ctype == 4) a = sample(row, x * ch + 1); }
            else if (ctype == 3) {
                int i = sample(row, x);
                if ((size_t)i * 3 + 2 >= plte.size()) throw std::runtime_error("palette index out of range");
                r = plte[i * 3]; g = plte[i * 3 + 1]; b = plte[i * 3 + 2];
                if ((size_t)i < trns.size()) a = trns[i];
            } else { r = sample(row, x * ch); g = sample(row, x * ch + 1); b = sample(row, x * ch + 2); if (ctype == 6) a = sample(row, x * ch + 3); }
            int lum = (r * 299 + g * 587 + b * 114) / 1000;
            img.gray[(size_t)y * w + x] = (uint8_t)((lum * a + 255 * (255 - a)) / 255);
        }
    }
    return img;
}

}  // namespace png
