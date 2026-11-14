#!/usr/bin/env python3
"""Reference oracle for the differential fuzzer: runs SQL in SQLite.

Protocol: one JSON object per line on stdin, one JSON reply per line.
  {"reset": true}           -> fresh in-memory database
  {"sql": "..."}            -> {"rows": [[...], ...]} or {"error": "..."}
"""
import json
import sqlite3
import sys

db = sqlite3.connect(":memory:", isolation_level=None)
for line in sys.stdin:
    req = json.loads(line)
    if req.get("reset"):
        db.close()
        db = sqlite3.connect(":memory:", isolation_level=None)
        out = {"ok": True}
    else:
        try:
            cur = db.execute(req["sql"])
            out = {"rows": [list(r) for r in cur.fetchall()]}
        except Exception as e:  # noqa: BLE001 - report any SQLite error
            out = {"error": str(e)}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
