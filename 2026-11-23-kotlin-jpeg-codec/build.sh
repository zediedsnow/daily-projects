#!/usr/bin/env bash
# Builds ochre.jar (needs kotlinc on PATH or KOTLINC=/path/to/kotlinc)
set -euo pipefail
cd "$(dirname "$0")"
"${KOTLINC:-kotlinc}" src/*.kt -include-runtime -d ochre.jar 2>&1 | grep -v '^warning' || true
test -f ochre.jar && echo "built ochre.jar"
