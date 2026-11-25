#!/usr/bin/env bash
# Run the full nutmeg verification suite; logs land in out/.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
run() { echo "== $1"; Rscript "$1" 2>&1 | tee "out/$(basename "$1" .R).log"; }
run tests/test_ad.R            # autodiff vs finite differences (~10 s)
run tests/test_diagnostics.R   # R-hat/ESS vs the posterior package (~1 min)
run tests/test_posteriors.R    # 7 closed-form posteriors (~1.5 min)
run examples/eight_schools.R   # divergences in the funnel, writes screenshot.png (~1.5 min)
run tests/sbc.R                # simulation-based calibration (~12 min)
run tests/vs_stan.R            # head-to-head with rstan (~7 min, mostly Stan compiling)
