#!/usr/bin/env python3
"""Extract sample IDs (IIDs) from an ancIBD HDF5.

ancIBD stores sample IDs in the top-level dataset: "samples".
We print one IID per line to stdout or write to an output file.

This helper exists because some workflows start from prebuilt HDF5s without
having the original VCF/BCF inputs available.
"""
import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("h5", help="Path to a chromosome HDF5")
    p.add_argument(
        "--out",
        default="",
        help="Optional output path. If omitted, print to stdout.",
    )
    return p.parse_args()


def _decode(x: object) -> str:
    if isinstance(x, (bytes, bytearray)):
        return x.decode("utf-8")
    return str(x)


def main() -> None:
    args = parse_args()
    h5_path = Path(args.h5)
    if not h5_path.exists():
        raise SystemExit(f"Missing HDF5: {h5_path}")

    import h5py  # type: ignore

    with h5py.File(h5_path, "r") as f:
        if "samples" not in f:
            raise SystemExit(f"HDF5 does not contain a 'samples' dataset: {h5_path}")
        samples = [_decode(x) for x in f["samples"][:]]

    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(out.suffix + ".tmp")
        tmp.write_text("\n".join(samples) + "\n", encoding="utf-8")
        tmp.replace(out)
    else:
        for s in samples:
            print(s)


if __name__ == "__main__":
    main()
