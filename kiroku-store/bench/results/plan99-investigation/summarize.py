"""Reproduce retained-log summaries; descriptive intervals are not promotion gates."""
import csv
import json
import math
from pathlib import Path
import statistics
import sys

ROOT = Path(__file__).resolve().parent


def summarize(label):
    lines = (ROOT / f"{label}.log").read_text().splitlines()
    pair_lines = [line for line in lines if line.startswith("PAIR,")]
    rows = list(csv.DictReader(pair_lines))
    if len(rows) != 12:
        raise ValueError(f"{label}: expected 12 pairs, got {len(rows)}")
    ratios = []
    for row in rows:
        for phase in ("before", "after"):
            if row[f"control_{phase}"] != row[f"candidate_{phase}"]:
                raise ValueError(f"{label}: arms have unequal work counts")
        if int(row["control_after"]) - int(row["control_before"]) != 32:
            raise ValueError(f"{label}: batch does not contain 32 iterations")
        ratios.append(int(row["candidate_ns"]) / int(row["control_ns"]))
    logs = list(map(math.log, ratios))
    mean = statistics.mean(logs)
    standard_error = statistics.stdev(logs) / math.sqrt(len(logs))
    # t(11): descriptive only, since consecutive pairs may be autocorrelated.
    interval = [math.exp(mean + sign * 2.200985 * standard_error) for sign in (-1, 1)]
    counts = [line for line in lines if line.startswith("COUNTS,")]
    if len(counts) != 2:
        raise ValueError(f"{label}: both database-count validations are required")
    result = {
        "label": label,
        "pairs": len(rows),
        "pre_gc": all(row.get("pre_gc") == "1" for row in rows),
        "ratio": math.exp(mean),
        "ratio_sd": statistics.stdev(ratios),
        "ratio_range": [min(ratios), max(ratios)],
        "descriptive_t_interval": interval,
        "by_order": {
            order: math.exp(statistics.mean(
                math.log(int(row["candidate_ns"]) / int(row["control_ns"]))
                for row in rows if row["first"] == order
            ))
            for order in ("control", "candidate")
        },
        "mean_ms_per_workload": {
            arm: statistics.mean(int(row[f"{arm}_ns"]) / 32 / 1e6 for row in rows)
            for arm in ("control", "candidate")
        },
        "counts": counts,
    }
    (ROOT / f"{label}.csv").write_text("\n".join(pair_lines) + "\n")
    (ROOT / f"{label}-summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    for label in sys.argv[1:]:
        summarize(label)
