#!/usr/bin/env python3
"""Lightweight validation for an ancIBD HDF5 file.

Exit codes:
  0: looks OK
  2: missing/broken

This is intentionally conservative: if anything looks off, we return 2 so the
wrapper can rebuild the file.
"""

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("path", help="Path to .h5")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    path = Path(args.path)
    if not path.exists() or path.stat().st_size == 0:
        raise SystemExit(2)

    try:
        import h5py  # type: ignore

        with h5py.File(path, "r") as f:
            # Required-ish datasets for ancIBD.
            required = [
                "variants/POS",
                "variants/AF_ALL",
                "variants/MAP",
                "calldata/GP",
            ]
            for k in required:
                if k not in f:
                    raise SystemExit(2)

            # Samples are typically stored as a dataset called "samples".
            if "samples" not in f:
                raise SystemExit(2)

            # Very small sanity checks.
            if f["variants/POS"].shape[0] == 0:
                raise SystemExit(2)
            if f["calldata/GP"].shape[0] == 0:
                raise SystemExit(2)

    except SystemExit:
        raise
    except Exception:
        raise SystemExit(2)


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        raise
