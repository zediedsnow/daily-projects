// QR code (ISO/IEC 18004) model 2 encoder and decoder, versions 1-40, ECC levels L/M/Q/H.
#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace qr {

enum class Ecc { L = 0, M = 1, Q = 2, H = 3 };
enum class Mode { Numeric, Alnum, Byte };

struct Segment {
    Mode mode;
    std::vector<uint8_t> chars;
};

struct Options {
    Ecc ecc = Ecc::M;
    int minVersion = 1, maxVersion = 40;
    int mask = -1;          // -1: pick the mask with the lowest penalty score
    bool boost = true;      // raise the ECC level when it fits in the same version
    bool optimize = true;   // split the input into optimal numeric/alnum/byte segments
};

struct Symbol {
    int version = 0, size = 0, mask = 0;
    Ecc ecc = Ecc::M;
    std::vector<uint8_t> modules;  // row-major, 1 = dark
    std::vector<Segment> segments;
    int dataBits = 0, capacityBits = 0;
    long penalty[8] = {0};  // penalty score of every mask that was evaluated (-1 = not evaluated)
    bool get(int x, int y) const { return modules[y * size + x] != 0; }
};

struct Decoded {
    std::vector<uint8_t> text;
    int version = 0, mask = 0, eci = -1;
    Ecc ecc = Ecc::M;
    int formatDistance = 0;
    int correctedBytes = 0, blocks = 0;
    std::vector<int> errorsPerBlock;
    std::vector<Segment> segments;
};

struct Error : std::runtime_error { using std::runtime_error::runtime_error; };

Symbol encode(const std::vector<uint8_t>& data, const Options& opt);
Decoded decode(int size, const std::vector<uint8_t>& modules);

// Which modules of a symbol of this version are function patterns (finders, timing, format...).
std::vector<uint8_t> functionMap(int version);

// Data modules (index y*size+x) in placement order; bit i of the interleaved codeword stream goes to entry i.
std::vector<int> dataModuleOrder(int version);
// For each interleaved codeword: (block number, whether it is an ECC byte).
std::vector<std::pair<int, bool>> codewordBlocks(int version, Ecc ecc);

int numDataCodewords(int version, Ecc ecc);
int numRawCodewords(int version);
int eccCodewordsPerBlock(int version, Ecc ecc);
int numBlocks(int version, Ecc ecc);
int segmentBits(Mode m, int n);
int charCountBits(Mode m, int version);
const char* eccName(Ecc e);
const char* modeName(Mode m);
bool parseEcc(const std::string& s, Ecc* out);

}  // namespace qr
