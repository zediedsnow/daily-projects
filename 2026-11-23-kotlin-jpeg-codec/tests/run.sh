#!/usr/bin/env bash
# Full test: build, differential fuzz vs libjpeg-turbo, corruption fuzz.  usage: tests/run.sh [cases] [seed]
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f ochre.jar ] || ./build.sh
python3 tests/fuzz.py "${1:-2000}" "${2:-1}"
T=$(mktemp -d)
python3 - "$T" <<'PY'
import sys
from PIL import Image
t = sys.argv[1]
im = Image.open("examples/render.png").convert("RGB").crop((100, 100, 357, 301))
im.save(f"{t}/a.jpg", quality=80)
im.save(f"{t}/b.jpg", quality=60, progressive=True)
im.convert("L").save(f"{t}/c.jpg", progressive=True, restart_marker_blocks=3)
im.save(f"{t}/d.jpg", quality=90, subsampling=1, restart_marker_blocks=2)
PY
java -jar ochre.jar corrupt "$T/a.jpg,$T/b.jpg,$T/c.jpg,$T/d.jpg" 3000
rm -rf "$T"
