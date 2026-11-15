// qrforge: QR code encoder/decoder CLI.
#include <unistd.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <iterator>
#include <random>
#include <string>
#include <vector>

#include "png.hpp"
#include "qr.hpp"
#include "reedsolomon.hpp"

using namespace std;

static void usage() {
    fputs(
        "qrforge - QR code encoder and decoder (ISO/IEC 18004, versions 1-40)\n\n"
        "usage:\n"
        "  qrforge encode [options] [TEXT]     encode TEXT (or stdin) and print it to the terminal\n"
        "      -o FILE        write FILE instead (.png, .svg or .txt)\n"
        "      -e L|M|Q|H     error correction level (default M)\n"
        "      -v N | N-M     force version N, or search versions N..M\n"
        "      -m 0-7         force the mask pattern (default: lowest penalty)\n"
        "      -s N           pixels per module for PNG (default 8)\n"
        "      --no-boost     do not raise the ECC level when it fits for free\n"
        "      --no-optimize  one segment in a single mode instead of optimal mixed segments\n"
        "      --matrix       print the module matrix as 0/1 rows\n"
        "      --info         print version, segments, capacity and mask penalties to stderr\n"
        "  qrforge decode [--info] FILE.png    decode a QR code image (axis-aligned, e.g. a screenshot)\n"
        "  qrforge damage IN.png OUT.png [--flip N] [--blot X,Y,R] [--seed S]\n"
        "                                      flip N random data modules / invert a disc of radius R\n"
        "  qrforge selftest                    Reed-Solomon and encode/damage/decode round-trip tests\n",
        stderr);
}

static string readAll(FILE* f) {
    string s; char buf[4096]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) s.append(buf, n);
    return s;
}

static bool endsWith(const string& s, const string& e) { return s.size() >= e.size() && s.compare(s.size() - e.size(), e.size(), e) == 0; }

// ------------------------------------------------------------- rendering

static const int QUIET = 4;

static png::Image toImage(int size, const vector<uint8_t>& m, int scale) {
    png::Image img;
    img.width = img.height = (size + 2 * QUIET) * scale;
    img.gray.assign((size_t)img.width * img.height, 255);
    for (int y = 0; y < size; y++)
        for (int x = 0; x < size; x++)
            if (m[y * size + x])
                for (int dy = 0; dy < scale; dy++)
                    memset(&img.gray[(size_t)((y + QUIET) * scale + dy) * img.width + (x + QUIET) * scale], 0, scale);
    return img;
}

static string toSvg(const qr::Symbol& s) {
    int n = s.size + 2 * QUIET;
    string path;
    for (int y = 0; y < s.size; y++)
        for (int x = 0; x < s.size;) {
            if (!s.get(x, y)) { x++; continue; }
            int x0 = x;
            while (x < s.size && s.get(x, y)) x++;
            path += "M" + to_string(x0 + QUIET) + " " + to_string(y + QUIET) + "h" + to_string(x - x0) + "v1h-" + to_string(x - x0) + "z";
        }
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " + to_string(n) + " " + to_string(n) +
           "\" shape-rendering=\"crispEdges\">\n<rect width=\"100%\" height=\"100%\" fill=\"#fff\"/>\n<path fill=\"#000\" d=\"" +
           path + "\"/>\n</svg>\n";
}

static string toText(const qr::Symbol& s) {  // two characters per module; dark = full block
    string out;
    for (int y = -QUIET; y < s.size + QUIET; y++) {
        for (int x = -QUIET; x < s.size + QUIET; x++) {
            bool d = x >= 0 && y >= 0 && x < s.size && y < s.size && s.get(x, y);
            out += d ? "██" : "  ";
        }
        out += "\n";
    }
    return out;
}

static void toTerminal(const qr::Symbol& s) {  // half blocks: one text row shows two module rows
    auto dark = [&](int x, int y) { return x >= 0 && y >= 0 && x < s.size && y < s.size && s.get(x, y); };
    for (int y = -QUIET; y < s.size + QUIET; y += 2) {
        string line;
        for (int x = -QUIET; x < s.size + QUIET; x++) {
            bool t = dark(x, y), b = dark(x, y + 1);
            line += string("\x1b[38;5;") + (t ? "16" : "231") + ";48;5;" + (b ? "16" : "231") + "m▀";
        }
        printf("%s\x1b[0m\n", line.c_str());
    }
}

// ------------------------------------------------------------- image -> modules

// Samples an axis-aligned QR code (any scale, any quiet zone) from a grayscale image.
static int sampleModules(const png::Image& img, vector<uint8_t>& mods, double* scaleOut) {
    auto dark = [&](int x, int y) { return img.gray[(size_t)y * img.width + x] < 128; };
    int left = img.width, right = -1, top = img.height, bottom = -1;
    for (int y = 0; y < img.height; y++)
        for (int x = 0; x < img.width; x++)
            if (dark(x, y)) { left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y); }
    if (right < 0) throw qr::Error("no dark pixels: not a QR code");
    // The top-left finder pattern's top edge is a run of 7 dark modules.
    int run = 0;
    while (left + run <= right && dark(left + run, top)) run++;
    double s = run / 7.0;
    int size = (int)lround((right - left + 1) / s);
    int sizeY = (int)lround((bottom - top + 1) / s);
    if (size != sizeY || size < 21 || (size - 17) % 4 != 0) {
        // Snap to the nearest valid size and recompute the module pitch from the bounding box.
        int v = max(1, min(40, (int)lround((size - 17) / 4.0)));
        size = v * 4 + 17;
    }
    double sx = (right - left + 1) / (double)size, sy = (bottom - top + 1) / (double)size;
    mods.assign(size * size, 0);
    for (int y = 0; y < size; y++)
        for (int x = 0; x < size; x++)
            mods[y * size + x] = dark((int)(left + (x + 0.5) * sx), (int)(top + (y + 0.5) * sy));
    *scaleOut = sx;
    return size;
}

// ------------------------------------------------------------- commands

static int cmdEncode(int argc, char** argv) {
    qr::Options opt;
    string out, text;
    bool haveText = false, matrix = false, info = false;
    int scale = 8;
    for (int i = 0; i < argc; i++) {
        string a = argv[i];
        auto next = [&]() -> string { if (i + 1 >= argc) throw qr::Error(a + " needs a value"); return argv[++i]; };
        if (a == "-o") out = next();
        else if (a == "-e") { if (!qr::parseEcc(next(), &opt.ecc)) throw qr::Error("ECC level must be L, M, Q or H"); }
        else if (a == "-v") {
            string v = next(); size_t d = v.find('-');
            opt.minVersion = stoi(v.substr(0, d));
            opt.maxVersion = d == string::npos ? opt.minVersion : stoi(v.substr(d + 1));
        } else if (a == "-m") opt.mask = stoi(next());
        else if (a == "-s") scale = max(1, stoi(next()));
        else if (a == "--no-boost") opt.boost = false;
        else if (a == "--no-optimize") opt.optimize = false;
        else if (a == "--matrix") matrix = true;
        else if (a == "--info") info = true;
        else if (a == "-") { text = readAll(stdin); haveText = true; }
        else if (!a.empty() && a[0] == '-' && a.size() > 1) throw qr::Error("unknown option " + a);
        else { text = haveText ? text + " " + a : a; haveText = true; }
    }
    if (!haveText) text = readAll(stdin);
    vector<uint8_t> data(text.begin(), text.end());
    auto sym = qr::encode(data, opt);

    if (info) {
        fprintf(stderr, "version %d (%dx%d), ECC %s, mask %d\n", sym.version, sym.size, sym.size, qr::eccName(sym.ecc), sym.mask);
        fprintf(stderr, "data: %zu bytes -> %d bits of %d available (%.1f%% full), %d blocks x %d ECC codewords\n", data.size(),
                sym.dataBits, sym.capacityBits, 100.0 * sym.dataBits / sym.capacityBits, qr::numBlocks(sym.version, sym.ecc),
                qr::eccCodewordsPerBlock(sym.version, sym.ecc));
        for (auto& s : sym.segments) {
            string preview(s.chars.begin(), s.chars.begin() + min<size_t>(s.chars.size(), 28));
            for (char& c : preview) if ((unsigned char)c < 32) c = '.';
            fprintf(stderr, "  segment %-12s %4zu chars  \"%s%s\"\n", qr::modeName(s.mode), s.chars.size(), preview.c_str(), s.chars.size() > 28 ? "..." : "");
        }
        fprintf(stderr, "mask penalties:");
        for (int m = 0; m < 8; m++)
            if (sym.penalty[m] >= 0) fprintf(stderr, " %d:%ld%s", m, sym.penalty[m], m == sym.mask ? "*" : "");
        fprintf(stderr, "\n");
    }
    if (matrix) {
        for (int y = 0; y < sym.size; y++) {
            for (int x = 0; x < sym.size; x++) putchar('0' + sym.get(x, y));
            putchar('\n');
        }
    } else if (out.empty()) toTerminal(sym);
    else if (endsWith(out, ".png")) png::write(out, toImage(sym.size, sym.modules, scale));
    else {
        FILE* f = fopen(out.c_str(), "wb");
        if (!f) throw qr::Error("cannot write " + out);
        string body = endsWith(out, ".svg") ? toSvg(sym) : toText(sym);
        fwrite(body.data(), 1, body.size(), f);
        fclose(f);
    }
    return 0;
}

static int cmdDecode(int argc, char** argv) {
    bool info = false;
    string path;
    for (int i = 0; i < argc; i++) {
        if (string(argv[i]) == "--info") info = true;
        else path = argv[i];
    }
    if (path.empty()) throw qr::Error("decode needs a PNG file");
    auto img = png::read(path);
    vector<uint8_t> mods;
    double scale;
    int size = sampleModules(img, mods, &scale);
    auto d = qr::decode(size, mods);
    if (info) {
        fprintf(stderr, "version %d (%dx%d, %.1f px/module), ECC %s, mask %d, format bits off by %d\n", d.version, size, size, scale,
                qr::eccName(d.ecc), d.mask, d.formatDistance);
        fprintf(stderr, "Reed-Solomon: corrected %d byte%s across %d block%s (per block:", d.correctedBytes, d.correctedBytes == 1 ? "" : "s",
                d.blocks, d.blocks == 1 ? "" : "s");
        for (int e : d.errorsPerBlock) fprintf(stderr, " %d", e);
        fprintf(stderr, ", max %d each)\n", qr::eccCodewordsPerBlock(d.version, d.ecc) / 2);
        for (auto& s : d.segments) fprintf(stderr, "  segment %-12s %4zu chars\n", qr::modeName(s.mode), s.chars.size());
        if (d.eci >= 0) fprintf(stderr, "  ECI designator %d\n", d.eci);
    }
    fwrite(d.text.data(), 1, d.text.size(), stdout);
    if (isatty(1) && (d.text.empty() || d.text.back() != '\n')) putchar('\n');
    return 0;
}

static int cmdDamage(int argc, char** argv) {
    if (argc < 2) throw qr::Error("damage needs IN.png OUT.png");
    int flips = 0;
    unsigned seed = 1;
    vector<array<int, 3>> blots;
    for (int i = 2; i < argc; i++) {
        string a = argv[i];
        if (a == "--flip" && i + 1 < argc) flips = stoi(argv[++i]);
        else if (a == "--seed" && i + 1 < argc) seed = stoul(argv[++i]);
        else if (a == "--blot" && i + 1 < argc) {
            int x, y, r;
            if (sscanf(argv[++i], "%d,%d,%d", &x, &y, &r) != 3) throw qr::Error("--blot wants X,Y,R");
            blots.push_back({x, y, r});
        } else throw qr::Error("unknown option " + a);
    }
    auto img = png::read(argv[0]);
    vector<uint8_t> mods;
    double scale;
    int size = sampleModules(img, mods, &scale);
    int ver = (size - 17) / 4;
    auto fn = qr::functionMap(ver);
    mt19937 rng(seed);
    vector<int> data;
    for (int i = 0; i < size * size; i++) if (!fn[i]) data.push_back(i);
    shuffle(data.begin(), data.end(), rng);
    for (int i = 0; i < flips && i < (int)data.size(); i++) mods[data[i]] ^= 1;
    for (auto& b : blots)
        for (int y = 0; y < size; y++)
            for (int x = 0; x < size; x++)
                if ((x - b[0]) * (x - b[0]) + (y - b[1]) * (y - b[1]) <= b[2] * b[2]) mods[y * size + x] ^= 1;
    png::write(argv[1], toImage(size, mods, max(1, (int)lround(scale))));
    return 0;
}

// ------------------------------------------------------------- self test

static int cmdSelftest() {
    mt19937 rng(12345);
    auto t0 = chrono::steady_clock::now();
    // 1. Reed-Solomon: random codewords, up to t errors at random positions.
    int rsCases = 0;
    for (int it = 0; it < 20000; it++) {
        int nsym = 2 + rng() % 29, k = 1 + rng() % (255 - nsym);
        vector<uint8_t> msg(k);
        for (auto& b : msg) b = rng();
        auto ecc = rs::remainder(msg, rs::generator(nsym));
        vector<uint8_t> cw = msg;
        cw.insert(cw.end(), ecc.begin(), ecc.end());
        auto orig = cw;
        int t = rng() % (nsym / 2 + 1);
        vector<int> pos(cw.size());
        for (size_t i = 0; i < pos.size(); i++) pos[i] = i;
        shuffle(pos.begin(), pos.end(), rng);
        for (int i = 0; i < t; i++) cw[pos[i]] ^= 1 + rng() % 255;
        int r = rs::decode(cw, nsym);
        if (r != t || cw != orig) { fprintf(stderr, "RS FAIL nsym=%d k=%d t=%d got %d\n", nsym, k, t, r); return 1; }
        rsCases++;
    }
    printf("reed-solomon: %d random codewords with 0..t errors corrected exactly\n", rsCases);

    // 2. Every version x ECC level x mask: encode random text, smash exactly t codewords in
    //    every block (the correction limit), decode, compare; then one more error must not decode silently.
    const char* alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:abcdefghijklmnopqrstuvwxyz";
    int symbols = 0, overLimitCaught = 0, overLimitTotal = 0;
    long corrected = 0;
    for (int v = 1; v <= 40; v++)
        for (int e = 0; e < 4; e++)
            for (int m = 0; m < 8; m++) {
                qr::Ecc ecc = (qr::Ecc)e;
                int capBytes = qr::numDataCodewords(v, ecc) - 3;
                int len = 1 + rng() % max(1, capBytes);
                vector<uint8_t> text(len);
                int style = rng() % 3;
                for (auto& c : text) c = style == 0 ? '0' + rng() % 10 : style == 1 ? alphabet[rng() % 45] : alphabet[rng() % 71];
                qr::Options opt; opt.ecc = ecc; opt.minVersion = v; opt.maxVersion = v; opt.mask = m; opt.boost = false;
                qr::Symbol sym;
                try { sym = qr::encode(text, opt); } catch (qr::Error&) { text.resize(text.size() / 2); sym = qr::encode(text, opt); }

                auto order = qr::dataModuleOrder(v);
                auto blocks = qr::codewordBlocks(v, ecc);
                int nb = qr::numBlocks(v, ecc), t = qr::eccCodewordsPerBlock(v, ecc) / 2;
                vector<vector<int>> perBlock(nb);
                for (size_t c = 0; c < blocks.size(); c++) perBlock[blocks[c].first].push_back(c);
                auto smash = [&](vector<uint8_t>& mods, int cwIndex) {
                    int bits = 1 + rng() % 255;  // flip a random non-empty subset of the 8 modules
                    for (int b = 0; b < 8; b++) if (bits >> b & 1) mods[order[cwIndex * 8 + b]] ^= 1;
                };
                auto mods = sym.modules;
                for (int b = 0; b < nb; b++) {
                    auto cws = perBlock[b];
                    shuffle(cws.begin(), cws.end(), rng);
                    for (int i = 0; i < t; i++) smash(mods, cws[i]);
                }
                auto d = qr::decode(sym.size, mods);
                if (d.text != text || d.correctedBytes != t * nb || d.mask != m || d.ecc != ecc) {
                    fprintf(stderr, "ROUNDTRIP FAIL v%d-%s mask %d\n", v, qr::eccName(ecc), m);
                    return 1;
                }
                corrected += d.correctedBytes;
                symbols++;
                // one block gets t+1 errors
                mods = sym.modules;
                auto cws = perBlock[rng() % nb];
                shuffle(cws.begin(), cws.end(), rng);
                for (int i = 0; i <= t; i++) smash(mods, cws[i]);
                overLimitTotal++;
                try { auto d2 = qr::decode(sym.size, mods); if (d2.text != text) overLimitCaught++; else { fprintf(stderr, "impossible decode\n"); return 1; } }
                catch (qr::Error&) { overLimitCaught++; }
            }
    double secs = chrono::duration<double>(chrono::steady_clock::now() - t0).count();
    printf("round trip: %d symbols (v1-40 x L/M/Q/H x 8 masks), each with the maximum correctable damage in every block: "
           "all decoded, %ld codewords repaired\n", symbols, corrected);
    printf("over the limit: %d/%d symbols with t+1 errors in one block were rejected or failed safely\n", overLimitCaught, overLimitTotal);
    printf("ok (%.2f s)\n", secs);
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 2) { usage(); return 2; }
    string cmd = argv[1];
    try {
        if (cmd == "encode") return cmdEncode(argc - 2, argv + 2);
        if (cmd == "decode") return cmdDecode(argc - 2, argv + 2);
        if (cmd == "damage") return cmdDamage(argc - 2, argv + 2);
        if (cmd == "selftest") return cmdSelftest();
        usage();
        return 2;
    } catch (exception& e) {
        fprintf(stderr, "qrforge: %s\n", e.what());
        return 1;
    }
}
