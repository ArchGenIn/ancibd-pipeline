#!/usr/bin/env python3
"""Create exact ancIBD pairjobs and their per-job plan files.

Each job has:
  * <job_id>.iids   preload IID list for ancIBD-run --iid
  * <job_id>.pairs  exact IID pairs for ancIBD-run --pair

Modes:
  all
      Cover all unique IID pairs using the existing coarse batches.

  incremental
      Cover only pairs with at least one IID in the target set. The target set
      is either supplied directly (delta-kind=new) or defined as the complement
      of an already-analysed IID list (delta-kind=analyzed).
"""
import argparse
from dataclasses import dataclass
from pathlib import Path
import sys
from typing import Iterable


@dataclass(frozen=True)
class Job:
    job_id: str
    b1: int
    b2: int
    mode: str
    plan: str
    left: list[str]
    right: list[str]


def read_iids(path: Path) -> list[str]:
    items: list[str] = []
    seen: set[str] = set()
    duplicate_count = 0
    duplicate_examples: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        iid = s.split()[0]
        if iid in seen:
            duplicate_count += 1
            if len(duplicate_examples) < 10 and iid not in duplicate_examples:
                duplicate_examples.append(iid)
            continue
        items.append(iid)
        seen.add(iid)
    if duplicate_count:
        preview = ", ".join(duplicate_examples)
        noun = "entry" if duplicate_count == 1 else "entries"
        suffix = f" ({preview})" if preview else ""
        print(
            f"Note: dropped {duplicate_count} duplicate IID {noun} while reading {path}{suffix}",
            file=sys.stderr,
        )
    if not items:
        raise SystemExit(f"IID list is empty: {path}")
    return items


def batch_slices(iids: list[str], batch_size: int) -> list[list[str]]:
    return [iids[i : i + batch_size] for i in range(0, len(iids), batch_size)]


def stable_union(left: list[str], right: list[str]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for iid in left + right:
        if iid in seen:
            continue
        out.append(iid)
        seen.add(iid)
    return out


def write_lines(path: Path, lines: Iterable[str]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    count = 0
    with tmp.open("w", encoding="utf-8", newline="\n") as fh:
        for line in lines:
            fh.write(line)
            fh.write("\n")
            count += 1
    tmp.replace(path)
    return count


def pair_lines(left: list[str], right: list[str], mode: str) -> Iterable[str]:
    if mode == "within":
        for i, iid1 in enumerate(left):
            for iid2 in left[i + 1 :]:
                yield f"{iid1}\t{iid2}"
        return

    for iid1 in left:
        for iid2 in right:
            yield f"{iid1}\t{iid2}"


def pair_count(left: list[str], right: list[str], mode: str) -> int:
    if mode == "within":
        n = len(left)
        return n * (n - 1) // 2
    return len(left) * len(right)


def write_job_files(job: Job, plans_dir: Path) -> tuple[int, int]:
    preload = job.left if job.mode == "within" else stable_union(job.left, job.right)
    preload_count = write_lines(plans_dir / f"{job.job_id}.iids", preload)
    pairs_written = write_lines(plans_dir / f"{job.job_id}.pairs", pair_lines(job.left, job.right, job.mode))
    expected_pairs = pair_count(job.left, job.right, job.mode)
    if pairs_written != expected_pairs:
        raise SystemExit(
            f"Internal error for {job.job_id}: wrote {pairs_written} pairs, expected {expected_pairs}"
        )
    return preload_count, pairs_written


def build_all_jobs(batches: list[list[str]]) -> list[Job]:
    jobs: list[Job] = []
    for b1, left in enumerate(batches):
        for b2 in range(b1, len(batches)):
            right = batches[b2]
            if b1 == b2:
                if len(left) < 2:
                    continue
                jobs.append(
                    Job(
                        job_id=f"b{b1:03d}_b{b2:03d}",
                        b1=b1,
                        b2=b2,
                        mode="within",
                        plan="all",
                        left=left,
                        right=left,
                    )
                )
            else:
                jobs.append(
                    Job(
                        job_id=f"b{b1:03d}_b{b2:03d}",
                        b1=b1,
                        b2=b2,
                        mode="cross",
                        plan="all",
                        left=left,
                        right=right,
                    )
                )
    return jobs


def build_incremental_jobs(batches: list[list[str]], target: set[str]) -> list[Job]:
    jobs: list[Job] = []
    for b1, left in enumerate(batches):
        left_new = [iid for iid in left if iid in target]
        left_old = [iid for iid in left if iid not in target]
        for b2 in range(b1, len(batches)):
            right = batches[b2]
            right_new = [iid for iid in right if iid in target]
            right_old = [iid for iid in right if iid not in target]

            if b1 == b2:
                if len(left_new) >= 2:
                    jobs.append(
                        Job(
                            job_id=f"b{b1:03d}_b{b2:03d}_newnew",
                            b1=b1,
                            b2=b2,
                            mode="within",
                            plan="newnew",
                            left=left_new,
                            right=left_new,
                        )
                    )
                if left_new and left_old:
                    jobs.append(
                        Job(
                            job_id=f"b{b1:03d}_b{b2:03d}_newold",
                            b1=b1,
                            b2=b2,
                            mode="cross",
                            plan="newold",
                            left=left_new,
                            right=left_old,
                        )
                    )
                continue

            if left_new and right:
                jobs.append(
                    Job(
                        job_id=f"b{b1:03d}_b{b2:03d}_newleft",
                        b1=b1,
                        b2=b2,
                        mode="cross",
                        plan="newleft",
                        left=left_new,
                        right=right,
                    )
                )
            if left_old and right_new:
                jobs.append(
                    Job(
                        job_id=f"b{b1:03d}_b{b2:03d}_newright",
                        b1=b1,
                        b2=b2,
                        mode="cross",
                        plan="newright",
                        left=left_old,
                        right=right_new,
                    )
                )
    return jobs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iids", required=True, type=Path, help="Global IID list (one IID per line)")
    ap.add_argument("--batch-size", required=True, type=int, help="Batch size")
    ap.add_argument("--mode", required=True, choices=["all", "incremental"])
    ap.add_argument("--plans-dir", required=True, type=Path, help="Directory for per-job .iids/.pairs files")
    ap.add_argument("--out-jobs", required=True, type=Path, help="Output TSV describing all jobs")
    ap.add_argument("--delta-iids", type=Path, help="One-column IID list for incremental mode")
    ap.add_argument("--delta-kind", choices=["new", "analyzed"], help="Interpretation of --delta-iids")
    ap.add_argument("--out-target-iids", type=Path, help="Write the final incremental target IID set here")
    args = ap.parse_args()

    if args.batch_size <= 0:
        raise SystemExit("--batch-size must be > 0")

    iids = read_iids(args.iids)
    batches = batch_slices(iids, args.batch_size)

    if args.mode == "all":
        jobs = build_all_jobs(batches)
    else:
        if args.delta_iids is None or args.delta_kind is None:
            raise SystemExit("incremental mode requires --delta-iids and --delta-kind")
        listed = read_iids(args.delta_iids)
        global_iids = set(iids)
        unknown = [iid for iid in listed if iid not in global_iids]
        if unknown:
            preview = ", ".join(unknown[:10])
            raise SystemExit(f"IIDs not present in global IID list: {preview}")
        listed_set = set(listed)
        target = listed_set if args.delta_kind == "new" else (global_iids - listed_set)
        if not target:
            raise SystemExit("Incremental target IID set is empty")
        jobs = build_incremental_jobs(batches, target)
        if not jobs:
            raise SystemExit("Incremental target IID set produced no jobs")
        if args.out_target_iids is not None:
            target_ordered = [iid for iid in iids if iid in target]
            write_lines(args.out_target_iids, target_ordered)

    args.plans_dir.mkdir(parents=True, exist_ok=True)

    rows: list[str] = ["job_id\tb1\tb2\tmode\tplan\tn_left\tn_right\tn_preload\tn_pairs"]
    total_pairs = 0
    total_preload = 0
    for job in jobs:
        n_preload, n_pairs = write_job_files(job, args.plans_dir)
        rows.append(
            "\t".join(
                [
                    job.job_id,
                    str(job.b1),
                    str(job.b2),
                    job.mode,
                    job.plan,
                    str(len(job.left)),
                    str(len(job.right)),
                    str(n_preload),
                    str(n_pairs),
                ]
            )
        )
        total_pairs += n_pairs
        total_preload += n_preload

    write_lines(args.out_jobs, rows)

    print(
        " ".join(
            [
                f"mode={args.mode}",
                f"n_iids={len(iids)}",
                f"batch_size={args.batch_size}",
                f"n_batches={len(batches)}",
                f"n_jobs={len(jobs)}",
                f"total_pairs={total_pairs}",
                f"total_preload={total_preload}",
            ]
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
