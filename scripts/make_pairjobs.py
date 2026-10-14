#!/usr/bin/env python3
"""Create exact ancIBD pairjobs and their per-job plan files.

Each job has:
  * <job_id>.iids   preload IID list for ancIBD-run --iid
  * <job_id>.pairs  exact IID pairs for ancIBD-run --pair

Modes:
  all
      Cover all unique IID pairs using the existing coarse batches.

  incremental
      Legacy IID-delta mode. Cover only pairs with at least one IID in the
      target set. The target set is either supplied directly (delta-kind=new)
      or defined as the complement of an already-analysed IID list
      (delta-kind=analyzed).

  pair-history
      Pair-aware incremental mode. Cover exactly those pairs among the current
      IID set that are not directly covered by the explicitly supplied complete
      previous prod/prod-incremental runs.
"""
import argparse
import atexit
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
import shutil
import sys
import tempfile
from typing import Iterable, Iterator, TextIO


@dataclass(frozen=True)
class Job:
    job_id: str
    b1: int
    b2: int
    mode: str
    plan: str
    left: list[str]
    right: list[str]
    exact_pairs: list[tuple[str, str]] | None = None


@dataclass(frozen=True)
class HistoryRun:
    path: Path
    iids: frozenset[str]
    coverage_kind: str
    target_iids: frozenset[str] | None = None
    pair_files: tuple[tuple[Path, int | None], ...] = ()


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


def read_pairjobs(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        raise SystemExit(f"Missing pairjobs file in previous run: {path}")

    lines = [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not lines:
        raise SystemExit(f"Pairjobs file is empty: {path}")

    header = lines[0].split("\t")
    required = {"job_id", "plan"}
    missing_cols = sorted(required - set(header))
    if missing_cols:
        raise SystemExit(f"Pairjobs file lacks required columns {missing_cols}: {path}")

    rows: list[dict[str, str]] = []
    for lineno, line in enumerate(lines[1:], start=2):
        fields = line.split("\t")
        if len(fields) != len(header):
            raise SystemExit(
                f"Malformed pairjobs row at {path}:{lineno}: expected {len(header)} fields, got {len(fields)}"
            )
        rows.append(dict(zip(header, fields)))

    if not rows:
        raise SystemExit(f"Pairjobs file has no jobs: {path}")
    return rows


def load_history_run(path: Path) -> HistoryRun:
    meta = path / "meta"
    out = path / "out"
    iids_path = meta / "iids.txt"
    jobs_path = meta / "pairjobs.tsv"

    if not path.is_dir():
        raise SystemExit(f"Previous run directory does not exist: {path}")
    if not iids_path.is_file():
        raise SystemExit(f"Previous run lacks meta/iids.txt: {path}")

    rows = read_pairjobs(jobs_path)

    missing_done = [row["job_id"] for row in rows if not (out / row["job_id"] / "DONE").is_file()]
    if missing_done:
        preview = ", ".join(missing_done[:10])
        suffix = " ..." if len(missing_done) > 10 else ""
        raise SystemExit(
            f"Previous run is not complete at the pairjob level: {path}\n"
            f"Missing DONE for {len(missing_done)} job(s): {preview}{suffix}"
        )

    plans = {row["plan"] for row in rows}
    iids = frozenset(read_iids(iids_path))

    if plans == {"all"}:
        # A completed full prod run directly covers the full clique on its IID set.
        return HistoryRun(path=path, iids=iids, coverage_kind="all")

    if plans == {"pairhistory"}:
        # A pair-history run directly covers only the exact pairs that it itself
        # executed. Do not recursively assume that its own --previous-run inputs
        # are available or should count for the current plan.
        plans_dir = path / "work" / "plans"
        pair_files: list[tuple[Path, int | None]] = []
        for row in rows:
            pair_path = plans_dir / f"{row['job_id']}.pairs"
            if not pair_path.is_file():
                raise SystemExit(
                    f"Previous pair-history run lacks exact pair plan: {pair_path}\n"
                    "Pair-history runs can be reused only while their work/plans/*.pairs files are retained."
                )
            expected: int | None = None
            if row.get("n_pairs", ""):
                try:
                    expected = int(row["n_pairs"])
                except ValueError:
                    raise SystemExit(f"Invalid n_pairs for {row['job_id']} in {jobs_path}")
            pair_files.append((pair_path, expected))
        return HistoryRun(
            path=path,
            iids=iids,
            coverage_kind="pairhistory",
            pair_files=tuple(pair_files),
        )

    target_path = meta / "target_iids.txt"
    if not target_path.is_file():
        raise SystemExit(
            f"Previous run appears to use legacy IID-delta planning but lacks "
            f"meta/target_iids.txt: {path}"
        )
    target_list = read_iids(target_path)
    unknown = [iid for iid in target_list if iid not in iids]
    if unknown:
        preview = ", ".join(unknown[:10])
        raise SystemExit(
            f"Previous run target_iids.txt contains IID(s) absent from meta/iids.txt: {preview}"
        )
    return HistoryRun(
        path=path,
        iids=iids,
        coverage_kind="incremental",
        target_iids=frozenset(target_list),
    )


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


def stable_pair_endpoints(pairs: Iterable[tuple[str, str]]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for iid1, iid2 in pairs:
        for iid in (iid1, iid2):
            if iid in seen:
                continue
            seen.add(iid)
            out.append(iid)
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
    if job.exact_pairs is None:
        preload = job.left if job.mode == "within" else stable_union(job.left, job.right)
        pair_iter: Iterable[str] = pair_lines(job.left, job.right, job.mode)
        expected_pairs = pair_count(job.left, job.right, job.mode)
    else:
        preload = stable_pair_endpoints(job.exact_pairs)
        pair_iter = (f"{iid1}\t{iid2}" for iid1, iid2 in job.exact_pairs)
        expected_pairs = len(job.exact_pairs)

    preload_count = write_lines(plans_dir / f"{job.job_id}.iids", preload)
    pairs_written = write_lines(plans_dir / f"{job.job_id}.pairs", pair_iter)
    if pairs_written != expected_pairs:
        raise SystemExit(
            f"Internal error for {job.job_id}: wrote {pairs_written} pairs, expected {expected_pairs}"
        )
    return preload_count, pairs_written


def build_all_jobs(batches: list[list[str]]) -> Iterator[Job]:
    for b1, left in enumerate(batches):
        for b2 in range(b1, len(batches)):
            right = batches[b2]
            if b1 == b2:
                if len(left) < 2:
                    continue
                yield Job(
                    job_id=f"b{b1:03d}_b{b2:03d}",
                    b1=b1,
                    b2=b2,
                    mode="within",
                    plan="all",
                    left=left,
                    right=left,
                )
            else:
                yield Job(
                    job_id=f"b{b1:03d}_b{b2:03d}",
                    b1=b1,
                    b2=b2,
                    mode="cross",
                    plan="all",
                    left=left,
                    right=right,
                )


def build_incremental_jobs(batches: list[list[str]], target: set[str]) -> Iterator[Job]:
    for b1, left in enumerate(batches):
        left_new = [iid for iid in left if iid in target]
        left_old = [iid for iid in left if iid not in target]
        for b2 in range(b1, len(batches)):
            right = batches[b2]
            right_new = [iid for iid in right if iid in target]
            right_old = [iid for iid in right if iid not in target]

            if b1 == b2:
                if len(left_new) >= 2:
                    yield Job(
                        job_id=f"b{b1:03d}_b{b2:03d}_newnew",
                        b1=b1,
                        b2=b2,
                        mode="within",
                        plan="newnew",
                        left=left_new,
                        right=left_new,
                    )
                if left_new and left_old:
                    yield Job(
                        job_id=f"b{b1:03d}_b{b2:03d}_newold",
                        b1=b1,
                        b2=b2,
                        mode="cross",
                        plan="newold",
                        left=left_new,
                        right=left_old,
                    )
                continue

            if left_new and right:
                yield Job(
                    job_id=f"b{b1:03d}_b{b2:03d}_newleft",
                    b1=b1,
                    b2=b2,
                    mode="cross",
                    plan="newleft",
                    left=left_new,
                    right=right,
                )
            if left_old and right_new:
                yield Job(
                    job_id=f"b{b1:03d}_b{b2:03d}_newright",
                    b1=b1,
                    b2=b2,
                    mode="cross",
                    plan="newright",
                    left=left_old,
                    right=right_new,
                )


def iid_history_signature(iid: str, history: list[HistoryRun]) -> tuple[int, int]:
    """Coverage signature for full and legacy IID-delta histories only."""
    present_mask = 0
    target_mask = 0
    structural_idx = 0
    for run in history:
        if run.coverage_kind == "pairhistory":
            continue
        bit = 1 << structural_idx
        structural_idx += 1
        if iid not in run.iids:
            continue
        present_mask |= bit
        if run.coverage_kind == "all" or (run.target_iids is not None and iid in run.target_iids):
            target_mask |= bit
    return present_mask, target_mask


def pair_is_covered(sig1: tuple[int, int], sig2: tuple[int, int]) -> bool:
    present1, target1 = sig1
    present2, target2 = sig2
    shared_runs = present1 & present2
    return bool(shared_runs & (target1 | target2))


def index_pairhistory_pairs(
    history: list[HistoryRun],
    iid_to_index: dict[str, int],
    batch_size: int,
    index_dir: Path,
) -> dict[tuple[int, int], Path]:
    """Partition exact pairs from supplied pair-history runs by current batch rectangle.

    The index is disk-backed so a large historical pair set does not need to be
    resident in memory. Only pairs whose endpoints are both in the current IID
    set are retained.
    """
    index_dir.mkdir(parents=True, exist_ok=True)
    bucket_paths: dict[tuple[int, int], Path] = {}
    handles: OrderedDict[tuple[int, int], TextIO] = OrderedDict()
    max_open = 64

    def get_handle(bucket: tuple[int, int]) -> TextIO:
        if bucket in handles:
            fh = handles.pop(bucket)
            handles[bucket] = fh
            return fh
        if len(handles) >= max_open:
            _, old = handles.popitem(last=False)
            old.close()
        path = index_dir / f"b{bucket[0]:06d}_b{bucket[1]:06d}.pairs"
        bucket_paths[bucket] = path
        fh = path.open("a", encoding="utf-8", newline="\n")
        handles[bucket] = fh
        return fh

    try:
        for run in history:
            if run.coverage_kind != "pairhistory":
                continue
            for pair_path, expected in run.pair_files:
                n_lines = 0
                with pair_path.open("r", encoding="utf-8") as src:
                    for lineno, raw in enumerate(src, start=1):
                        line = raw.rstrip("\n")
                        if not line:
                            continue
                        fields = line.split("\t")
                        if len(fields) != 2 or not fields[0] or not fields[1]:
                            raise SystemExit(f"Malformed pair at {pair_path}:{lineno}")
                        iid1, iid2 = fields
                        if iid1 == iid2:
                            raise SystemExit(f"Self-pair at {pair_path}:{lineno}: {iid1}")
                        if iid1 not in run.iids or iid2 not in run.iids:
                            raise SystemExit(
                                f"Pair endpoint absent from previous run meta/iids.txt at "
                                f"{pair_path}:{lineno}: {iid1}, {iid2}"
                            )
                        n_lines += 1
                        if iid1 not in iid_to_index or iid2 not in iid_to_index:
                            continue
                        i = iid_to_index[iid1]
                        j = iid_to_index[iid2]
                        if i > j:
                            i, j = j, i
                        bucket = (i // batch_size, j // batch_size)
                        fh = get_handle(bucket)
                        fh.write(f"{i}\t{j}\n")
                if expected is not None and n_lines != expected:
                    raise SystemExit(
                        f"Previous pair plan count mismatch for {pair_path}: "
                        f"pairjobs.tsv says {expected}, file contains {n_lines}"
                    )
    finally:
        for fh in handles.values():
            fh.close()

    return bucket_paths


def load_exact_bucket(path: Path | None) -> set[tuple[int, int]]:
    if path is None or not path.is_file():
        return set()
    covered: set[tuple[int, int]] = set()
    with path.open("r", encoding="utf-8") as fh:
        for raw in fh:
            if not raw.strip():
                continue
            a, b = raw.rstrip("\n").split("\t")
            covered.add((int(a), int(b)))
    return covered


def group_batch_by_signature(
    batch: list[str], history: list[HistoryRun]
) -> list[tuple[tuple[int, int], list[str]]]:
    groups: OrderedDict[tuple[int, int], list[str]] = OrderedDict()
    for iid in batch:
        sig = iid_history_signature(iid, history)
        groups.setdefault(sig, []).append(iid)
    return list(groups.items())


def missing_pairs_between_batches(
    left_groups: list[tuple[tuple[int, int], list[str]]],
    right_groups: list[tuple[tuple[int, int], list[str]]],
    same_batch: bool,
    iid_to_index: dict[str, int],
    exact_covered: set[tuple[int, int]],
) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []

    def is_exactly_covered(iid1: str, iid2: str) -> bool:
        i = iid_to_index[iid1]
        j = iid_to_index[iid2]
        if i > j:
            i, j = j, i
        return (i, j) in exact_covered

    if not same_batch:
        for sig1, ids1 in left_groups:
            for sig2, ids2 in right_groups:
                if pair_is_covered(sig1, sig2):
                    continue
                for iid1 in ids1:
                    for iid2 in ids2:
                        if not is_exactly_covered(iid1, iid2):
                            pairs.append((iid1, iid2))
        return pairs

    for g1, (sig1, ids1) in enumerate(left_groups):
        for g2 in range(g1, len(left_groups)):
            sig2, ids2 = left_groups[g2]
            if pair_is_covered(sig1, sig2):
                continue
            if g1 == g2:
                for i, iid1 in enumerate(ids1):
                    for iid2 in ids1[i + 1 :]:
                        if not is_exactly_covered(iid1, iid2):
                            pairs.append((iid1, iid2))
            else:
                for iid1 in ids1:
                    for iid2 in ids2:
                        if not is_exactly_covered(iid1, iid2):
                            pairs.append((iid1, iid2))
    return pairs


def build_pair_history_jobs(
    batches: list[list[str]],
    history: list[HistoryRun],
    iid_to_index: dict[str, int],
    exact_bucket_paths: dict[tuple[int, int], Path],
) -> Iterator[Job]:
    grouped_batches = [group_batch_by_signature(batch, history) for batch in batches]

    for b1, left in enumerate(batches):
        for b2 in range(b1, len(batches)):
            right = batches[b2]
            exact_covered = load_exact_bucket(exact_bucket_paths.get((b1, b2)))
            pairs = missing_pairs_between_batches(
                grouped_batches[b1],
                grouped_batches[b2],
                same_batch=(b1 == b2),
                iid_to_index=iid_to_index,
                exact_covered=exact_covered,
            )
            if not pairs:
                continue

            left_seen = {iid1 for iid1, _ in pairs}
            right_seen = {iid2 for _, iid2 in pairs}
            left_used = [iid for iid in left if iid in left_seen or (b1 == b2 and iid in right_seen)]
            right_used = [iid for iid in right if iid in right_seen or (b1 == b2 and iid in left_seen)]

            yield Job(
                job_id=f"b{b1:03d}_b{b2:03d}_missing",
                b1=b1,
                b2=b2,
                mode="exact",
                plan="pairhistory",
                left=left_used,
                right=right_used,
                exact_pairs=pairs,
            )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iids", required=True, type=Path, help="Global IID list (one IID per line)")
    ap.add_argument("--batch-size", required=True, type=int, help="Batch size")
    ap.add_argument("--mode", required=True, choices=["all", "incremental", "pair-history"])
    ap.add_argument("--plans-dir", required=True, type=Path, help="Directory for per-job .iids/.pairs files")
    ap.add_argument("--out-jobs", required=True, type=Path, help="Output TSV describing all jobs")
    ap.add_argument("--delta-iids", type=Path, help="One-column IID list for legacy incremental mode")
    ap.add_argument("--delta-kind", choices=["new", "analyzed"], help="Interpretation of --delta-iids")
    ap.add_argument("--out-target-iids", type=Path, help="Write the final legacy incremental target IID set here")
    ap.add_argument(
        "--previous-run",
        action="append",
        type=Path,
        default=[],
        help="Complete previous run directory for pair-aware incremental mode; repeat as needed",
    )
    args = ap.parse_args()

    if args.batch_size <= 0:
        raise SystemExit("--batch-size must be > 0")

    iids = read_iids(args.iids)
    batches = batch_slices(iids, args.batch_size)
    args.plans_dir.mkdir(parents=True, exist_ok=True)

    if args.mode == "all":
        if args.delta_iids is not None or args.delta_kind is not None or args.previous_run:
            raise SystemExit("all mode does not accept incremental-history arguments")
        jobs: Iterable[Job] = build_all_jobs(batches)
        history: list[HistoryRun] = []
    elif args.mode == "incremental":
        if args.previous_run:
            raise SystemExit("legacy incremental mode does not accept --previous-run")
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
        history = []
        if args.out_target_iids is not None:
            target_ordered = [iid for iid in iids if iid in target]
            write_lines(args.out_target_iids, target_ordered)
    else:
        if args.delta_iids is not None or args.delta_kind is not None:
            raise SystemExit("pair-history mode is mutually exclusive with --delta-iids/--delta-kind")
        if not args.previous_run:
            raise SystemExit("pair-history mode requires at least one --previous-run")
        history = [load_history_run(path) for path in args.previous_run]
        iid_to_index = {iid: idx for idx, iid in enumerate(iids)}
        history_index_dir = Path(
            tempfile.mkdtemp(prefix=".pairhistory-index-", dir=args.plans_dir.parent)
        )
        atexit.register(shutil.rmtree, history_index_dir, ignore_errors=True)
        exact_bucket_paths = index_pairhistory_pairs(
            history, iid_to_index, args.batch_size, history_index_dir
        )
        jobs = build_pair_history_jobs(
            batches, history, iid_to_index, exact_bucket_paths
        )

    rows: list[str] = ["job_id\tb1\tb2\tmode\tplan\tn_left\tn_right\tn_preload\tn_pairs"]
    total_pairs = 0
    total_preload = 0
    n_jobs = 0
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
        n_jobs += 1

    if n_jobs == 0:
        if args.mode == "pair-history":
            raise SystemExit(
                "No missing pairs remain among the current IID set after applying the supplied previous-run history"
            )
        raise SystemExit("Incremental target IID set produced no jobs")

    write_lines(args.out_jobs, rows)

    summary = [
        f"mode={args.mode}",
        f"n_iids={len(iids)}",
        f"batch_size={args.batch_size}",
        f"n_batches={len(batches)}",
        f"n_jobs={n_jobs}",
        f"total_pairs={total_pairs}",
        f"total_preload={total_preload}",
    ]
    if args.mode == "pair-history":
        summary.append(f"n_previous_runs={len(history)}")
    print(" ".join(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
