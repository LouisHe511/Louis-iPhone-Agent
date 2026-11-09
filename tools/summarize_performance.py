#!/usr/bin/env python3
"""Summarize fixed-stage numeric diagnostics without printing task content or IDs."""
import argparse
from collections import defaultdict
from datetime import datetime
import json
import math
from pathlib import Path

STAGES = {"encode", "first_response", "total", "ocr", "local.screenshot", "local.tap", "local.drag", "local.type", "local.home", "local.launch_app", "local.louis_geometry", "local.list_apps", "local.config"}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="Local performance-stages.jsonl; never upload the app container")
    parser.add_argument("--since", help="ISO-8601 timestamp with timezone")
    args = parser.parse_args()
    since = datetime.fromisoformat(args.since.replace("Z", "+00:00")) if args.since else None
    if since is not None and since.tzinfo is None:
        parser.error("--since requires an explicit timezone")
    groups = defaultdict(list)
    failures = defaultdict(int)
    skipped = 0
    with args.path.open() as source:
        for line in source:
            try:
                row = json.loads(line)
                phase = row["phase"]
                elapsed = row["elapsed_ms"]
                if phase not in STAGES or isinstance(elapsed, bool) or not isinstance(elapsed, (int, float)) or not math.isfinite(elapsed) or elapsed < 0:
                    raise ValueError()
                if since is not None and datetime.fromisoformat(row["time"].replace("Z", "+00:00")) < since:
                    continue
                if row.get("succeeded") is False:
                    failures[phase] += 1
                else:
                    groups[phase].append(float(elapsed))
            except (ValueError, KeyError, TypeError):
                skipped += 1
    print("stage,successes,failures,p50_ms,p95_ms")
    for phase in sorted(groups.keys() | failures.keys()):
        values = sorted(groups[phase])
        def percentile(fraction):
            return f"{values[max(0, math.ceil(len(values) * fraction) - 1)]:.1f}" if values else ""
        print(f"{phase},{len(values)},{failures[phase]},{percentile(.5)},{percentile(.95)}")
    if skipped:
        print(f"# skipped_invalid_rows={skipped}")

if __name__ == "__main__":
    main()
