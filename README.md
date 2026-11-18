# Daily Projects

One self-contained project every day, each in a different language, built by Claude.

**Languages used so far:** C (1), C++ (1), Go (1), Haskell (1), HTML/JS (1), Java (1), Lua (1), OCaml (1), Python (1), Ruby (1), Rust (1), TypeScript (1), Zig (1)

| Date | Project | Language | What it is |
|------|---------|----------|------------|
| 2026-11-18 | [ludolph](2026-11-18-zig-pi-digits/) | Zig | Computes millions of digits of π, e, √2 and φ from scratch: base-10⁶ bignums, Goldilocks-prime NTT multiplication, Newton division/sqrt, threaded Chudnovsky binary splitting; 10M digits of π in 35 s, every digit identical to GMP |
| 2026-11-17 | [quorum](2026-11-17-ocaml-raft-jepsen/) | OCaml | Jepsen-style tester for Raft: deterministic simulator with partitions/crashes/buggify faults, Wing-Gong-Lowe linearizability checker (verified vs brute force on 50k histories); zero false positives on 3M ops, catches 4 injected Raft bugs incl. the paper's Figure 8 |
| 2026-11-16 | [loom](2026-11-16-lua-wave-function-collapse/) | Lua | Wave Function Collapse texture synthesis: AC-4 constraint propagation with incremental entropy, plus its own PNG/DEFLATE and animated GIF/LZW encoders to watch the collapse; every 3x3 window of 84 test outputs verified against the sample |
| 2026-11-15 | [qrforge](2026-11-15-cpp-qr-codec/) | C++ | Dependency-free QR encoder + decoder: optimal mixed-mode segmentation, Berlekamp-Massey/Forney Reed-Solomon repair, own PNG deflate/inflate; bit-identical to python-qrcode on 1,500 random symbols and uncovered a padding bug in segno |
| 2026-11-14 | [Garnet](2026-11-14-ruby-sql-database/) | Ruby | SQL database from scratch: on-disk B+tree pages, crash-safe rollback journal (survives kill -9 mid-commit), query planner with index/range/hash-join access paths and EXPLAIN; matches SQLite on 143k fuzzed queries |
| 2026-11-13 | [Moss](2026-11-13-haskell-moss-ml/) | Haskell | Tiny ML language with Hindley-Milner inference, algebraic data types, and Maranget exhaustiveness/redundancy checking with counterexamples; a fuzzer runs 200k random programs to empirically verify type soundness |
| 2026-11-12 | [Jolt](2026-11-12-java-jvm-compiler/) | Java | Compiler for a small typed language that writes JVM .class files byte by byte (no ASM); passes the HotSpot verifier, runs ~100x faster than its reference interpreter, and agrees with it on 20k fuzzed programs |
| 2026-11-11 | [linrex](2026-11-11-ts-linear-regex/) | TypeScript | ReDoS-proof regex engine: Thompson NFA, Pike VM captures and lazy DFA; matches V8's semantics exactly across 180k fuzzed cases while staying linear-time where V8 takes >5 s |
| 2026-11-10 | [gosat](2026-11-10-go-cdcl-sat/) | Go | CDCL SAT solver: watched literals, 1UIP learning with minimization, VSIDS, Luby restarts, LBD clause deletion; solves the hardest sudoku, 100-queens, and DIMACS files |
| 2026-11-09 | [pydeflate](2026-11-09-python-deflate/) | Python | gzip/DEFLATE written from scratch: LZ77 with lazy matching, package-merge Huffman, block-type selection; output is within a few bytes of zlib -9 and opens in gunzip |
| 2026-11-08 | [Kestrel Chess Engine](2026-11-08-c-chess-engine/) | C | UCI chess engine with legal movegen (perft-verified), PVS alpha-beta, TT, null-move/LMR and tapered PeSTO eval |
| 2026-11-07 | [Rust Path Tracer](2026-11-07-rust-path-tracer/) | Rust | Zero-dependency Monte Carlo path tracer with BVH, glass, depth of field and a hand-written PNG encoder |
| 2026-11-07 | [Particle Life](2026-11-07-particle-life/) | HTML/JS | Colored particles follow attract/repel rules and form lifelike creatures |
