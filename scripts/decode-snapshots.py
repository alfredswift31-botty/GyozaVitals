#!/usr/bin/env python3
"""Extract the UI snapshots CI prints into its log.

Usage: decode-snapshots.py <job-log-file> <output-dir>

The log file is either plain text or the JSON the GitHub job-logs tool saves
({"logs_content": ...}). Each snapshot is printed as SNAPSHOT-BEGIN <name>,
SNAPSHOT-DATA <base64>... and SNAPSHOT-END <name>; this writes <name>.jpg.
"""
import base64
import json
import os
import re
import sys

log_path, out_dir = sys.argv[1], sys.argv[2]
raw = open(log_path, encoding="utf-8", errors="replace").read()
try:
    text = json.loads(raw)["logs_content"]
except (ValueError, KeyError, TypeError):
    text = raw
os.makedirs(out_dir, exist_ok=True)
current, chunks, written = None, [], []
for line in text.split("\n"):
    match = re.search(r"SNAPSHOT-(BEGIN|DATA|END) ([A-Za-z0-9+/=_.-]+)\s*$", line)
    if not match:
        continue
    kind, value = match.groups()
    if kind == "BEGIN":
        current, chunks = value, []
    elif kind == "DATA" and current:
        chunks.append(value)
    elif kind == "END" and current:
        data = "".join(chunks)
        data += "=" * (-len(data) % 4)
        path = os.path.join(out_dir, current + ".jpg")
        with open(path, "wb") as handle:
            handle.write(base64.b64decode(data))
        written.append(path)
        current = None
print("\n".join(written) if written else "No snapshots found.")
