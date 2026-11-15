// Arithmetic in GF(2^8) with the QR code field polynomial x^8+x^4+x^3+x^2+1 (0x11D).
#pragma once
#include <array>
#include <cstdint>

namespace gf {

struct Tables {
    std::array<uint8_t, 512> exp{};
    std::array<int, 256> log{};
    Tables() {
        int x = 1;
        for (int i = 0; i < 255; i++) {
            exp[i] = static_cast<uint8_t>(x);
            log[x] = i;
            x <<= 1;
            if (x & 0x100) x ^= 0x11D;
        }
        for (int i = 255; i < 512; i++) exp[i] = exp[i - 255];
        log[0] = -1;
    }
};

inline const Tables& T() { static const Tables t; return t; }

inline uint8_t mul(uint8_t a, uint8_t b) {
    if (a == 0 || b == 0) return 0;
    return T().exp[T().log[a] + T().log[b]];
}
inline uint8_t div(uint8_t a, uint8_t b) {
    if (a == 0) return 0;
    return T().exp[(T().log[a] + 255 - T().log[b]) % 255];
}
inline uint8_t alpha_pow(int e) {
    e %= 255;
    if (e < 0) e += 255;
    return T().exp[e];
}
inline uint8_t inv(uint8_t a) { return T().exp[255 - T().log[a]]; }

}  // namespace gf
