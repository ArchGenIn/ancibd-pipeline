#!/usr/bin/env python3
"""Lightweight validation for an ancIBD HDF5 file.

Exit codes:
  0: looks OK
  2: missing/broken

This is intentionally conservative: if anything looks off, return 2 so the
wrapper can rebuild the file.
"""
import argparse
from pathlib import Path


AF_KEYS = [
    "variants/AF_ALL",
    "variants/AF_SAMPLE",
    "variants/RAF",
    "variants/AF_REF",
]


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
            required = [
                "variants/POS",
                "variants/MAP",
                "calldata/GP",
            ]
            for key in required:
                if key not in f:
                    raise SystemExit(2)

            n_var = f["variants/POS"].shape[0]
            for af_key in AF_KEYS:
                if af_key in f and f[af_key].shape[0] != n_var:
                    raise SystemExit(2)

            if "samples" not in f:
                raise SystemExit(2)
            if n_var == 0:
                raise SystemExit(2)
            if f["calldata/GP"].shape[0] == 0:
                raise SystemExit(2)

    except SystemExit:
        raise
    except Exception:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
