#!/usr/bin/env python3
"""Lightweight validation for an ancIBD HDF5 file."""
import argparse
from pathlib import Path

AF_KEYS = ["variants/AF_ALL", "variants/RAF", "variants/AF_REF"]


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
            for key in ["variants/POS", "variants/MAP", "calldata/GP", "samples"]:
                if key not in f:
                    raise SystemExit(2)

            n_var = f["variants/POS"].shape[0]
            if n_var == 0 or f["calldata/GP"].shape[0] == 0:
                raise SystemExit(2)

            for af_key in AF_KEYS:
                if af_key in f and f[af_key].shape[0] != n_var:
                    raise SystemExit(2)

    except SystemExit:
        raise
    except Exception:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
