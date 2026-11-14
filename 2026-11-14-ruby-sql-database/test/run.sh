#!/usr/bin/env bash
# Runs the storage tests and a differential fuzz against SQLite.
set -euo pipefail
cd "$(dirname "$0")/.."
ruby test/test_storage.rb
ruby test/fuzz.rb "${1:-300}" "${2:-1}"
