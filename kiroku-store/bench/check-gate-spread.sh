#!/usr/bin/env bash
# Validate the complete controlled-workload CSV, including both sides of each pair.
set -euo pipefail
if [[ $# != 1 ]]; then
    echo "usage: $0 RESULTS.csv" >&2
    exit 1
fi
python3 - "$1" <<'PY'
import csv
import math
import sys

bound = 0.20
groups = {
    "append-multi-stream": [
        f"{arm}-{size}"
        for size in (4, 8)
        for arm in ("sequential-control", "production-pipeline")
    ],
    "append-category-column": ["control-append-40", "candidate-append-40"],
    "category-read": [
        f"{arm}-{case}"
        for case in (
            "exhausted-category", "page-200-streams-from-0",
            "page-20000-streams-from-0", "plain-caught-up-20000-streams",
            "group-caught-up-20000-streams",
        )
        for arm in ("control", "candidate")
    ],
}
expected = {f"All.{group}.{cell}" for group, cells in groups.items() for cell in cells}
warm = "All.append-category-column.warm-append-40"

try:
    with open(sys.argv[1], newline="") as source:
        reader = csv.DictReader(source, strict=True)
        required = {"Name", "Mean (ps)", "2*Stdev (ps)"}
        if not reader.fieldnames or not required.issubset(reader.fieldnames):
            raise ValueError("missing CSV columns: Name, Mean (ps), 2*Stdev (ps)")
        if len(reader.fieldnames) != len(set(reader.fieldnames)):
            raise ValueError("duplicate CSV columns")
        seen = set()
        failed = False
        for row in reader:
            name = row["Name"]
            if name not in expected | {warm} or name in seen:
                raise ValueError(f"unexpected or duplicate cell: {name}")
            seen.add(name)
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"malformed CSV row: {name}")
            mean, spread = float(row["Mean (ps)"]), float(row["2*Stdev (ps)"])
            if not math.isfinite(mean) or mean <= 0 or not math.isfinite(spread) or spread < 0:
                raise ValueError(f"invalid mean or doubled standard deviation: {name}")
            # The throwaway cell may be noisy; it is never a comparison arm.
            if name in expected and spread > bound * mean:
                print(f"gate spread FAIL: {name}: mean={mean:g} ps, "
                      f"2*stdev={spread:g} ps ({spread / mean:.1%}); bound=20% of mean",
                      file=sys.stderr)
                failed = True
        missing = expected - seen
        if missing:
            raise ValueError("missing compared cells: " + ", ".join(sorted(missing)))
        if failed:
            sys.exit(1)
except (OSError, ValueError, csv.Error) as error:
    sys.exit(f"gate spread FAIL: {error}")

print("gate spread OK: every compared arm within 20% of its mean")
PY
