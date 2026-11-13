#!/usr/bin/env bash
# Golden-output tests for every example + inferred types, then the soundness fuzzer.
#   tests/run.sh           check against tests/expected/
#   tests/run.sh --update  regenerate the expected files
set -uo pipefail
cd "$(dirname "$0")/.."
[ -x ./moss ] || ./build.sh
mkdir -p tests/expected
fail=0
check() { # name, command...
  local name=$1; shift
  local out; out=$("$@" 2>&1; echo "[exit $?]")
  if [ "${UPDATE:-0}" = 1 ]; then printf '%s\n' "$out" > "tests/expected/$name.out"; echo "updated $name"; return; fi
  if diff -u "tests/expected/$name.out" <(printf '%s\n' "$out") > /dev/null; then echo "PASS $name"
  else echo "FAIL $name"; diff -u "tests/expected/$name.out" <(printf '%s\n' "$out") | head -20; fail=1; fi
}
[ "${1:-}" = "--update" ] && UPDATE=1
for f in examples/*.moss examples/errors/*.moss; do
  name=$(echo "${f#examples/}" | tr / _); check "${name%.moss}" ./moss "$f"
done
check types ./moss --types tests/types.moss
check repl sh -c './moss < tests/repl.txt'
echo "--- soundness fuzzer"
./moss --fuzz 200000 | tail -8 || fail=1
[ $fail = 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
