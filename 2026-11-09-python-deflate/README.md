# pydeflate: gzip written from scratch in pure Python

A complete DEFLATE (RFC 1951) and gzip (RFC 1952) compressor and decompressor written without `zlib`, the `gzip` module or any other library. The files it writes open in `gunzip`, `zcat` and Python's `gzip` module, and it can read the files those tools write.

At level 9 its output is the same size as zlib's to within a few bytes, and on some inputs it is a few bytes smaller.

## Why it's interesting

DEFLATE is one of the most widely used compression formats: it is inside gzip, zip, PNG, HTTP compression and git objects. Writing a decoder is fairly easy. Writing an encoder whose output is as small as zlib's means getting several hard parts right:

- **LZ77 with hash chains.** Every 3-byte prefix is hashed. Earlier occurrences are kept in a linked chain, and each chain is followed back through a 32 KiB window to find the longest earlier match. The match finder first checks the one byte that would make a candidate longer than the current best. It then compares 16 bytes at a time using slices.
- **Lazy matching.** After finding a match at position *i*, the encoder also checks *i+1*. If the match there is longer, it emits a literal at *i* and uses the longer match. This is the same trick gzip uses. The match found at *i+1* is cached, so it isn't searched twice.
- **Length-limited Huffman codes using package-merge.** Ordinary Huffman codes can be longer than DEFLATE's 15-bit limit (7 bits for the code-length alphabet). Package-merge (Larmore and Hirschberg, 1990) gives the *optimal* code under that limit, instead of the heuristic fix-up most encoders use. The tests check it against plain Huffman when the limit doesn't apply, and against Fibonacci-weighted inputs that would otherwise produce 24-bit codes.
- **Choosing a block type.** For each block of 16K tokens, the encoder works out the exact cost in bits of a *stored*, *fixed-Huffman* or *dynamic-Huffman* encoding and writes the cheapest. The dynamic cost includes the run-length-coded header (symbols 16/17/18). This is why random data grows by only 15 bytes in 40 KB.
- **Table-driven inflater.** It builds one lookup table, so each symbol is decoded with one peek and one table read. It handles all three block types, overlapping copies (where distance is less than length), concatenated gzip members, and CRC-32 and ISIZE checks. Corrupt input raises a `DeflateError` instead of crashing.

## Run it

Needs Python 3.8 or newer and nothing else.

```bash
python3 pydeflate.py compress  big.log -l 9      # -> big.log.gz
python3 pydeflate.py decompress big.log.gz       # -> big.log
python3 pydeflate.py inspect   big.log.gz        # show each DEFLATE block
python3 pydeflate.py bench -l 9                  # compare with zlib (zlib used only as a reference)
python3 -m unittest -v test_pydeflate            # 19 tests
```

It also works as a library:

```python
import pydeflate
gz  = pydeflate.gzip_compress(b"hello " * 1000, level=9)
raw = pydeflate.gzip_decompress(gz)
```

## Sample output

**Size compared with zlib** at the same level (raw DEFLATE bytes). Every row is round-trip checked both ways: zlib decompresses pydeflate's output and pydeflate decompresses zlib's.

```
pydeflate level 9 vs zlib level 9 (raw DEFLATE sizes)

  input                       size  pydeflate      zlib    diff     comp  decomp  interop
  pydeflate.py (source)      31518       9635      9636   -0.0%    0.13s   0.01s  ok
  zipf english               49488      13022     13024   -0.0%    0.53s   0.01s  ok
  csv table                 101531      35728     35736   -0.0%    0.34s   0.02s  ok
  random DNA                 60000      18137     18144   -0.0%    1.52s   0.01s  ok
  random bytes               40000      40015     40015   +0.0%    0.04s   0.00s  ok
  one byte x 100k           100000        114       114   +0.0%    0.03s   0.00s  ok
```

**Checked with the real gzip tools:**

```
$ python3 pydeflate.py compress sample.txt -l 9
sample.txt: 73.8 KiB -> 22.1 KiB (29.9%) in 0.36s, blocks: 1 dynamic  => sample.txt.gz
$ gunzip -t sample.txt.gz && zcat sample.txt.gz | cmp - sample.txt
gunzip -t: OK
zcat identical
$ gzip -9 -c sample.txt | wc -c
22513                                     # pydeflate: 22586
```

**Choosing a block type on mixed input** (source code, then 30 KB of random bytes, then a repeated DNA pattern, then the source again). The random section is written as a stored block:

```
$ python3 pydeflate.py inspect mixed.bin.gz
mixed.bin.gz: 51834 bytes compressed, 173022 bytes original, 3 block(s), CRC-32 a9279477 ok

    #  type         output  compressed  bits/byte
    0  dynamic       41881       21341      4.077  ####################
    1  stored        16428       16433      8.002  ########################################
    2  dynamic      114713       14031      0.979  #####
```

## How it works

```
data ──► LZ77 (hash chains + lazy match) ──► tokens: literal | (length, distance)
                                                  │  split into 16K-token blocks
                                                  ▼
                 symbol frequencies ──► package-merge ──► code lengths (≤15 bits)
                                                  │
                    cost(stored), cost(fixed), cost(dynamic + RLE header)
                                                  ▼
                     cheapest block ──► LSB-first BitWriter ──► gzip header + CRC-32
```

| Piece | Where |
|---|---|
| CRC-32 (table-driven, reflected 0xEDB88320) | `crc32` |
| LSB-first bit packing / unpacking | `BitWriter`, `BitReader` |
| Optimal length-limited code lengths | `package_merge` |
| Canonical code assignment (RFC 1951 §3.2.2) | `canonical_codes` |
| Match finder and lazy evaluation | `lz77_tokens` |
| Code-length RLE (symbols 16/17/18) | `_rle_code_lengths` |
| Block-type choice and emission | `write_block` |
| One-table Huffman decoder | `HuffmanDecoder` |
| Inflate (all block types) | `inflate` |
| gzip members, FNAME/FEXTRA/FCOMMENT/FHCRC, trailer checks | `gzip_compress`, `gzip_decompress` |

Compression levels 1 to 9 set the hash-chain depth, the "good enough" match length and the lazy-matching threshold, similar to zlib's configuration table. Level 0 writes stored blocks only.

**Limits:** this is pure Python, so it runs at roughly 100 to 300 KB/s when compressing and about 5 MB/s when decompressing. The point is a correct, readable reference implementation, not speed. The whole input is held in memory.
