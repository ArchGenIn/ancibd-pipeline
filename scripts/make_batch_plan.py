#!/usr/bin/env python3
"""Create per-job IID and pair files for ancIBD batch runs.

ancIBD-run supports:
  --iid  : one IID per line (limits what gets loaded into memory)
  --pair : two IIDs per line separated by whitespace (limits what pairs are evaluated)

This tool takes a global IID list (one per line) and a batch definition, and writes:
  * an IID file containing the *union* of batch i and batch j (preload set)
  * a pair file containing all pairs to run between the two batches

Batches are 0-indexed.
"""
import argparse
from pathlib import Path


def read_iids(path: Path) -> list[str]:
    iids: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        iids.append(s)
    if not iids:
        raise SystemExit(f"IID list is empty: {path}")
    return iids


def slice_batch(iids: list[str], batch: int, batch_size: int) -> list[str]:
    start = batch * batch_size
    end = min(len(iids), (batch + 1) * batch_size)
    if start >= len(iids):
        raise SystemExit(
            f"Batch index out of range: batch={batch} with n_iids={len(iids)} and batch_size={batch_size}"
        )
    return iids[start:end]


def write_lines(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    tmp.replace(path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iids", required=True, type=Path, help="Global IID list (one per line)")
    ap.add_argument("--batch-size", required=True, type=int, help="Batch size (e.g., 500)")
    ap.add_argument("--b1", required=True, type=int, help="Batch index 1 (0-indexed)")
    ap.add_argument("--b2", required=True, type=int, help="Batch index 2 (0-indexed)")
    ap.add_argument("--out-iids", required=True, type=Path, help="Output IID file")
    ap.add_argument("--out-pairs", required=True, type=Path, help="Output pairs file")
    args = ap.parse_args()

    iids = read_iids(args.iids)
    if args.batch_size <= 0:
        raise SystemExit("--batch-size must be > 0")

    b1 = args.b1
    b2 = args.b2

    a = slice_batch(iids, b1, args.batch_size)
    b = slice_batch(iids, b2, args.batch_size)

    # IID preload set: union, but keep a stable order for reproducibility.
    if b1 == b2:
        preload = a
    else:
        preload = a + b

    pairs: list[str] = []
    if b1 == b2:
        # Within-batch unique combinations.
        for i in range(len(a)):
            for j in range(i + 1, len(a)):
                pairs.append(f"{a[i]}\t{a[j]}")
    else:
        # All cross pairs.
        for x in a:
            for y in b:
                pairs.append(f"{x}\t{y}")

    write_lines(args.out_iids, preload)
    write_lines(args.out_pairs, pairs)

    # A tiny bit of machine-friendly info on stdout.
    n_batches = (len(iids) + args.batch_size - 1) // args.batch_size
    print(
        " ".join(
            [
                f"n_iids={len(iids)}",
                f"batch_size={args.batch_size}",
                f"n_batches={n_batches}",
                f"b1={b1}",
                f"b2={b2}",
                f"n_preload={len(preload)}",
                f"n_pairs={len(pairs)}",
            ]
        )
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
