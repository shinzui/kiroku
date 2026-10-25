#!/usr/bin/env python3
"""Exercise fail-closed CSV handling without a database or timed experiment."""
import csv
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


CHECKER = Path(__file__).resolve().with_name("check-gate-spread.sh")
HEADER = ["Name", "Mean (ps)", "2*Stdev (ps)"]


def valid_rows():
    cells = [
        ("append-multi-stream", f"{arm}-{size}")
        for size in (4, 8)
        for arm in ("sequential-control", "production-pipeline")
    ] + [
        ("append-accepted-category", f"{arm}-append-40x32")
        for arm in ("accepted-control", "candidate")
    ] + [
        ("category-read", f"{arm}-{case}")
        for case in (
            "exhausted-category", "page-200-streams-from-0",
            "page-20000-streams-from-0", "plain-caught-up-20000-streams",
            "group-caught-up-20000-streams",
        )
        for arm in ("control", "candidate")
    ]
    return [[f"All.{group}.{cell}", "100", "20"] for group, cell in cells]


class GateSpreadTest(unittest.TestCase):
    def check_csv(self, rows, header=HEADER):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.csv"
            with path.open("w", newline="") as output:
                writer = csv.writer(output)
                writer.writerow(header)
                writer.writerows(rows)
            return subprocess.run(
                ["bash", str(CHECKER), str(path)], capture_output=True, text=True
            )

    def test_bound_is_inclusive_and_warm_cell_is_exempt(self):
        rows = valid_rows() + [["All.append-accepted-category.warm-append-40", "100", "200"]]
        result = self.check_csv(rows)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_every_comparison_arm_is_checked(self):
        for index in range(len(valid_rows())):
            rows = valid_rows()
            rows[index][2] = "21"
            with self.subTest(cell=rows[index][0]):
                result = self.check_csv(rows)
                self.assertEqual(result.returncode, 1)
                for detail in (rows[index][0], "mean=100", "2*stdev=21", "bound=20%"):
                    self.assertIn(detail, result.stderr)

    def test_missing_duplicate_and_unknown_cells_fail(self):
        rows = valid_rows()
        for invalid in (rows[:-1], rows + rows[:1], rows + [["unknown", "100", "1"]], []):
            self.assertEqual(self.check_csv(invalid).returncode, 1)

    def test_historical_control_cannot_replace_accepted_control(self):
        rows = valid_rows()
        for row in rows:
            row[0] = row[0].replace("append-accepted-category.accepted-control-", "append-category-column.control-")
        result = self.check_csv(rows)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected or duplicate cell", result.stderr)

    def test_invalid_numeric_data_fails(self):
        for mean, spread in (("0", "0"), ("-1", "0"), ("nan", "0"),
                             ("inf", "0"), ("100", "nan"), ("100", "-1"),
                             ("100", "inf"), ("100", "")):
            rows = valid_rows()
            rows[0][1:] = [mean, spread]
            with self.subTest(mean=mean, spread=spread):
                self.assertEqual(self.check_csv(rows).returncode, 1)

    def test_columns_are_selected_by_name(self):
        rows = [[row[2], "extra", row[0], row[1]] for row in valid_rows()]
        result = self.check_csv(rows, [HEADER[2], "Allocated", HEADER[0], HEADER[1]])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_incomplete_and_malformed_csv_fails(self):
        self.assertEqual(self.check_csv(valid_rows(), HEADER[:2]).returncode, 1)
        self.assertEqual(self.check_csv(valid_rows(), [HEADER[0]] * 3).returncode, 1)
        self.assertEqual(self.check_csv(valid_rows() + [["short"]]).returncode, 1)

    def test_recipe_rejects_noise_and_preserves_benchmark_failure(self):
        # Run the actual recipe with a stand-in benchmark writer, without timing
        # PostgreSQL. This proves that a green benchmark cannot hide a noisy arm,
        # and a valid CSV cannot hide the benchmark's failure status.
        shown = subprocess.check_output(
            ["just", "--justfile", str(CHECKER.parents[2] / "Justfile"),
             "--show", "perf-workload-gate"], text=True
        )
        recipe = textwrap.dedent(shown.split("perf-workload-gate:\n", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bench = root / "kiroku-store/bench"
            bench.mkdir(parents=True)
            shutil.copy(CHECKER, bench)
            fake = root / "cabal"
            fake.write_text(
                '#!/bin/bash\ncp "$GATE_FIXTURE" '
                'kiroku-store/bench/results/workload-gate.csv\nexit "$GATE_STATUS"\n'
            )
            fake.chmod(0o755)
            fixture = root / "fixture.csv"
            for noisy, status, expected in ((False, "0", 0), (True, "0", 1), (False, "7", 7)):
                rows = valid_rows()
                if noisy:
                    rows[0][2] = "21"
                with fixture.open("w", newline="") as output:
                    writer = csv.writer(output)
                    writer.writerow(HEADER)
                    writer.writerows(rows)
                env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                           GATE_FIXTURE=str(fixture), GATE_STATUS=status)
                result = subprocess.run(["bash", "-c", recipe], cwd=root, env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn("gate spread", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
