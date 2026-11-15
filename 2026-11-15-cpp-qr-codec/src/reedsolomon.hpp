// Reed-Solomon over GF(256) as used by QR codes: generator roots alpha^0 .. alpha^(n-1).
// Encoder is an LFSR division; decoder is Berlekamp-Massey + Chien search + Forney.
#pragma once
#include <cstdint>
#include <vector>

#include "gf256.hpp"

namespace rs {

// Coefficients of the monic generator polynomial, highest degree first, leading 1 omitted.
inline std::vector<uint8_t> generator(int n) {
    std::vector<uint8_t> r(n, 0);
    r[n - 1] = 1;
    uint8_t root = 1;
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            r[j] = gf::mul(r[j], root);
            if (j + 1 < n) r[j] ^= r[j + 1];
        }
        root = gf::mul(root, 2);
    }
    return r;
}

// Remainder of data(x) * x^n divided by the generator: the n ECC bytes.
inline std::vector<uint8_t> remainder(const std::vector<uint8_t>& data, const std::vector<uint8_t>& gen) {
    std::vector<uint8_t> res(gen.size(), 0);
    for (uint8_t b : data) {
        uint8_t factor = b ^ res[0];
        res.erase(res.begin());
        res.push_back(0);
        for (size_t i = 0; i < res.size(); i++) res[i] ^= gf::mul(gen[i], factor);
    }
    return res;
}

// Evaluate a polynomial stored lowest-degree first.
inline uint8_t eval_low(const std::vector<uint8_t>& p, uint8_t x) {
    uint8_t y = 0;
    for (size_t i = p.size(); i-- > 0;) y = gf::mul(y, x) ^ p[i];
    return y;
}

inline std::vector<uint8_t> syndromes(const std::vector<uint8_t>& block, int nsym, bool* allZero) {
    std::vector<uint8_t> s(nsym, 0);
    *allZero = true;
    for (int j = 0; j < nsym; j++) {
        // block[0] is the coefficient of x^(N-1): Horner from the front.
        uint8_t x = gf::alpha_pow(j), y = 0;
        for (uint8_t c : block) y = gf::mul(y, x) ^ c;
        s[j] = y;
        if (y) *allZero = false;
    }
    return s;
}

// Corrects `block` (data followed by nsym ECC bytes) in place.
// Returns the number of corrected bytes, or -1 if the block is uncorrectable.
inline int decode(std::vector<uint8_t>& block, int nsym, std::vector<int>* positions = nullptr) {
    const int N = static_cast<int>(block.size());
    bool clean;
    std::vector<uint8_t> S = syndromes(block, nsym, &clean);
    if (clean) return 0;

    // Berlekamp-Massey: find the shortest LFSR (error locator Lambda) generating S.
    std::vector<uint8_t> C{1}, B{1};
    int L = 0, m = 1;
    uint8_t b = 1;
    for (int r = 0; r < nsym; r++) {
        uint8_t d = S[r];
        for (int i = 1; i <= L && i < (int)C.size(); i++) d ^= gf::mul(C[i], S[r - i]);
        if (d == 0) { m++; continue; }
        std::vector<uint8_t> Tm = C;
        uint8_t coef = gf::div(d, b);
        if (C.size() < B.size() + m) C.resize(B.size() + m, 0);
        for (size_t i = 0; i < B.size(); i++) C[i + m] ^= gf::mul(coef, B[i]);
        if (2 * L <= r) { L = r + 1 - L; B = Tm; b = d; m = 1; }
        else m++;
    }
    C.resize(L + 1);
    if (2 * L > nsym) return -1;

    // Chien search: position k holds the coefficient of x^p with p = N-1-k; locator X = alpha^p.
    std::vector<int> errPos;
    std::vector<uint8_t> errX;
    for (int k = 0; k < N; k++) {
        int p = N - 1 - k;
        uint8_t Xinv = gf::alpha_pow(-p);
        if (eval_low(C, Xinv) == 0) { errPos.push_back(k); errX.push_back(gf::alpha_pow(p)); }
    }
    if ((int)errPos.size() != L) return -1;  // roots outside the block: too many errors

    // Omega(x) = S(x) * Lambda(x) mod x^nsym
    std::vector<uint8_t> Om(nsym, 0);
    for (int i = 0; i < nsym; i++)
        for (int j = 0; j <= L && i + j < nsym; j++) Om[i + j] ^= gf::mul(S[i], C[j]);
    // Formal derivative of Lambda (characteristic 2: only odd terms survive).
    std::vector<uint8_t> dC(L > 0 ? L : 1, 0);
    for (int i = 1; i <= L; i += 2) dC[i - 1] = C[i];

    // Forney with first consecutive root alpha^0: e = X * Omega(X^-1) / Lambda'(X^-1)
    for (size_t i = 0; i < errPos.size(); i++) {
        uint8_t Xinv = gf::inv(errX[i]);
        uint8_t den = eval_low(dC, Xinv);
        if (den == 0) return -1;
        uint8_t e = gf::mul(errX[i], gf::div(eval_low(Om, Xinv), den));
        block[errPos[i]] ^= e;
    }
    syndromes(block, nsym, &clean);
    if (!clean) return -1;
    if (positions) *positions = errPos;
    return L;
}

}  // namespace rs
