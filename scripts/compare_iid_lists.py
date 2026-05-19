#!/usr/bin/env python3
"""Write the list of HDF5 IIDs not present in the analysed IID file."""
from pathlib import Path
import argparse
import sys


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--analyzed-iids", required=True)
    p.add_argument("--hdf5-iids", required=True)
    p.add_argument("--out", required=True)
    return p.parse_args()


def read_iids(path: Path) -> list[str]:
    items: list[str] = []
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        iid = s.split()[0]
        if iid in seen:
            continue
        items.append(iid)
        seen.add(iid)
    return items


def main() -> None:
    args = parse_args()
    analyzed_path = Path(args.analyzed_iids)
    hdf5_path = Path(args.hdf5_iids)
    out_path = Path(args.out)

    analyzed = read_iids(analyzed_path)
    hdf5_iids = read_iids(hdf5_path)
    hdf5_set = set(hdf5_iids)
    analyzed_set = set(analyzed)
    unknown = [iid for iid in analyzed if iid not in hdf5_set]
    new_samples = [iid for iid in hdf5_iids if iid not in analyzed_set]

    out_path.write_text("".join(f"{iid}\n" for iid in new_samples), encoding="utf-8")

    if unknown:
        preview = ", ".join(unknown[:10])
        extra = "" if len(unknown) <= 10 else ", ..."
        print(
            f"WARNING: analyzed IID file contains {len(unknown)} IID(s) not present in the HDF5 sample list: {preview}{extra}",
            file=sys.stderr,
        )
    elif len(analyzed_set) == len(hdf5_set):
        print(
            "WARNING: analyzed IID file equals the HDF5 sample list; the output new-sample list is empty.",
            file=sys.stderr,
        )

    print(f"Wrote {out_path} (n={len(new_samples)})")


if __name__ == "__main__":
    main()
