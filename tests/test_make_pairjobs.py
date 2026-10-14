#!/usr/bin/env python3
"""Regression tests for pair-history coverage semantics."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "make_pairjobs.py"


def write_run(run: Path, iids: list[str], rows: list[str], pairs: dict[str, list[tuple[str, str]]]) -> None:
    (run / "meta").mkdir(parents=True)
    (run / "out").mkdir()
    (run / "work" / "plans").mkdir(parents=True)
    (run / "meta" / "iids.txt").write_text("".join(f"{iid}\n" for iid in iids), encoding="utf-8")
    header = "job_id\tb1\tb2\tmode\tplan\tn_left\tn_right\tn_preload\tn_pairs\n"
    (run / "meta" / "pairjobs.tsv").write_text(header + "".join(rows), encoding="utf-8")
    for job_id, job_pairs in pairs.items():
        out = run / "out" / job_id
        out.mkdir(parents=True)
        (out / "DONE").touch()
        (run / "work" / "plans" / f"{job_id}.pairs").write_text(
            "".join(f"{a}\t{b}\n" for a, b in job_pairs), encoding="utf-8"
        )
    for row in rows:
        job_id = row.split("\t", 1)[0]
        out = run / "out" / job_id
        out.mkdir(parents=True, exist_ok=True)
        (out / "DONE").touch()


def planned_pairs(plans_dir: Path) -> set[tuple[str, str]]:
    result: set[tuple[str, str]] = set()
    for path in plans_dir.glob("*.pairs"):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line:
                a, b = line.split("\t")
                result.add((a, b))
    return result


class PairHistorySemanticsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)

        self.r1 = self.base / "R1"
        write_run(
            self.r1,
            ["A", "B"],
            ["b000_b000\t0\t0\twithin\tall\t2\t2\t2\t1\n"],
            {},
        )

        self.r2 = self.base / "R2"
        write_run(
            self.r2,
            ["A", "B", "C"],
            ["b000_b001_missing\t0\t1\texact\tpairhistory\t2\t1\t3\t2\n"],
            {"b000_b001_missing": [("A", "C"), ("B", "C")]},
        )

        self.iids = self.base / "current.iids"
        self.iids.write_text("A\nB\nC\nD\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_planner(self, previous_runs: list[Path], batch_size: int = 2) -> set[tuple[str, str]]:
        suffix = "_".join(p.name for p in previous_runs) + f"_bs{batch_size}"
        plans = self.base / ("plans_" + suffix)
        jobs = self.base / ("jobs_" + suffix + ".tsv")
        cmd = [
            sys.executable,
            str(SCRIPT),
            "--iids", str(self.iids),
            "--batch-size", str(batch_size),
            "--mode", "pair-history",
            "--plans-dir", str(plans),
            "--out-jobs", str(jobs),
        ]
        for run in previous_runs:
            cmd.extend(["--previous-run", str(run)])
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return planned_pairs(plans)

    def test_only_explicit_pairhistory_run_counts(self) -> None:
        # R2 directly contains AC and BC. Its own R1 ancestry must not be assumed.
        self.assertEqual(
            self.run_planner([self.r2]),
            {("A", "B"), ("A", "D"), ("B", "D"), ("C", "D")},
        )

    def test_explicit_full_and_pairhistory_runs_are_unioned(self) -> None:
        # R1 contributes AB and R2 contributes AC/BC, so only pairs with D remain.
        self.assertEqual(
            self.run_planner([self.r1, self.r2]),
            {("A", "D"), ("B", "D"), ("C", "D")},
        )

    def test_pairhistory_is_rebucketed_for_current_batch_size(self) -> None:
        self.assertEqual(
            self.run_planner([self.r2], batch_size=3),
            {("A", "B"), ("A", "D"), ("B", "D"), ("C", "D")},
        )


if __name__ == "__main__":
    unittest.main()
