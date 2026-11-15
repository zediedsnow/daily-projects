// Minimal PNG codec with no dependencies: a writer (fixed-Huffman deflate with a run/row matcher) and a
// reader with a full
// inflate implementation (stored, fixed and dynamic Huffman blocks), all filter types, all colour types.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace png {

struct Image {
    int width = 0, height = 0;
    std::vector<uint8_t> gray;  // 8-bit luminance, row-major, alpha composited onto white
};

void write(const std::string& path, const Image& img);
Image read(const std::string& path);
std::vector<uint8_t> inflate(const uint8_t* data, size_t len);
std::vector<uint8_t> deflate(const std::vector<uint8_t>& in, size_t stride);

}  // namespace png
