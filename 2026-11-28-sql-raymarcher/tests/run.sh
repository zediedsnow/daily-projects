#!/usr/bin/env bash
# Runs every test: the SQL property tests and the PNG differential tests.
set -euo pipefail
cd "$(dirname "$0")"
psql -X -f test_scene.sql
python3 test_png.py
