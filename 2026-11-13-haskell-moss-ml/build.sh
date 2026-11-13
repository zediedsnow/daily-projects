#!/usr/bin/env bash
# Build the `moss` binary. Needs only GHC (tested with 9.4) and its bundled
# libraries (containers, mtl, transformers, template-haskell).
set -euo pipefail
cd "$(dirname "$0")"
ghc -O1 -isrc -outputdir build -o moss src/Main.hs
