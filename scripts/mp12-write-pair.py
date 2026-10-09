#!/usr/bin/env python3
"""Run one predeclared MP-12 write cell; preserve every raw paired trial.

This is deliberately a fail-closed pilot gate, not the completed matrix. A
wide interval or a possible positive slowdown never counts as equivalence.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys
import time


def run(binary, workload):
    completed = subprocess.run([str(binary), *workload], capture_output=True, text=True)
    if completed.returncode:
        raise RuntimeError(completed.stdout + completed.stderr)
    rows = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith("{")]
    if len(rows) != 1:
        raise RuntimeError("probe did not emit exactly one JSON result")
    row = rows[0]
    if row["durability"] != "on,on,on" or not row["durable_drained"]:
        raise RuntimeError("durability or progress precondition failed")
    if row["workload"]["mode"] != "none" and row["events"] != row["delivered"]:
        raise RuntimeError("subscriber did not deliver exactly the appended work")
    if row["elapsed"] < 60:
        raise RuntimeError("measurement interval was shorter than 60 seconds")
    return row


def interval(values):
    # Two-sided 95% Student-t; conservative 2.1 for >=30 paired samples.
    critical = {
        4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262,
        10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145,
        15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093,
        20: 2.086, 21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064,
        25: 2.060, 26: 2.056, 27: 2.052, 28: 2.048, 29: 2.045,
    }.get(len(values) - 1, 2.1)
    center = statistics.mean(values)
    half = critical * statistics.stdev(values) / math.sqrt(len(values))
    return {"estimate_pct": 100 * math.expm1(center),
            "lower_pct": 100 * math.expm1(center - half),
            "upper_pct": 100 * math.expm1(center + half),
            "half_width_pct": 100 * math.expm1(half)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["none", "all", "category", "group", "adapter"], default="group")
    parser.add_argument("--width", type=int, default=1)
    parser.add_argument("--append-batch", type=int, default=1)
    parser.add_argument("--checkpoint-batch", choices=[1, 100], type=int, default=1)
    parser.add_argument("--fresh", action="store_true")
    parser.add_argument("--offered", type=int, default=100)
    parser.add_argument("--seconds", type=int, default=61)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--calibrate", action="store_true")
    args = parser.parse_args()
    if args.pairs < 5 or args.seconds < 61:
        parser.error("at least five pairs and 61 scheduled seconds are required")
    if args.output.exists():
        parser.error("output already exists; choose a new path to preserve evidence")
    binaries = {label: path.resolve() for label, path in [("control", args.control), ("candidate", args.candidate)]}
    hashes = {label: hashlib.sha256(path.read_bytes()).hexdigest() for label, path in binaries.items()}
    if args.calibrate and hashes["control"] != hashes["candidate"]:
        parser.error("control/control calibration requires identical binary hashes")
    workload = [str(args.seconds), args.mode, str(args.width), str(args.append_batch),
                str(args.checkpoint_batch), str(args.fresh), str(args.offered)]
    evidence = {"binary_sha256": hashes, "binaries": {k: str(v) for k, v in binaries.items()},
                "command": sys.argv, "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "workload": workload, "calibration": args.calibrate, "trials": [],
                "complete_matrix": False, "status": "running"}
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        temporary = args.output.with_suffix(args.output.suffix + ".tmp")
        temporary.write_text(json.dumps(evidence, indent=2) + "\n")
        temporary.replace(args.output)

    save()
    try:
        for pair in range(args.pairs):
            trial = {}
            order = ["control", "candidate"] if pair % 2 == 0 else ["candidate", "control"]
            for label in order:
                print(f"pair {pair + 1}/{args.pairs}: {label}", flush=True)
                trial[label] = run(binaries[label], workload)
                if trial[label]["workload"] != {"seconds": args.seconds, "mode": args.mode,
                    "width": args.width, "append_batch": args.append_batch,
                    "checkpoint_batch": args.checkpoint_batch, "fresh": args.fresh, "offered": args.offered}:
                    raise RuntimeError("probe workload differs from requested cell")
                # Preserve even an interrupted half-pair rather than discarding it.
                evidence["partial_trial"] = trial
                save()
            if trial["control"]["server"] != trial["candidate"]["server"]:
                raise RuntimeError("pair used different PostgreSQL builds")
            evidence["trials"].append(trial)
            del evidence["partial_trial"]
            save()

        comparisons = {}
        fields = [("append_p50_ms", 1), ("append_p95_ms", 3), ("append_p99_ms", 3)] if args.offered else [("events_per_second", 1)]
        for field, resolution in fields:
            ratios = [math.log(t["control"][field] / t["candidate"][field]) if field == "events_per_second"
                      else math.log(t["candidate"][field] / t["control"][field]) for t in evidence["trials"]]
            result = interval(ratios)
            result["required_resolution_pct"] = resolution
            if result["half_width_pct"] > resolution:
                result["status"] = "inconclusive"
            elif args.calibrate:
                result["status"] = "calibrated" if result["lower_pct"] <= 0 <= result["upper_pct"] else "order_bias"
            else:
                result["status"] = "regression" if result["lower_pct"] > 0 else "passes" if result["upper_pct"] <= 0 else "inconclusive"
            comparisons[field] = result
        evidence["comparisons"] = comparisons
        statuses = {r["status"] for r in comparisons.values()}
        evidence["status"] = "regression" if "regression" in statuses else "inconclusive" if statuses & {"inconclusive", "order_bias"} else "calibrated" if args.calibrate else "passes"
        save()
        print(json.dumps({"status": evidence["status"], "comparisons": comparisons}, indent=2))
        return 1 if evidence["status"] == "regression" else 2 if evidence["status"] == "inconclusive" else 0
    except BaseException as error:
        evidence["status"] = "failed"
        evidence["error"] = str(error)
        save()
        raise


if __name__ == "__main__":
    sys.exit(main())
