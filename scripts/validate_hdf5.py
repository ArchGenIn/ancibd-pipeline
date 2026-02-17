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
            #
            # NOTE: We intentionally do *not* require an allele-frequency column here.
            # ancIBD can calculate allele frequencies from the samples if no external AF
            # is provided. (If present, we sanity-check that it has the right length.)
            required = [
                "variants/POS",
                "variants/MAP",
                "calldata/GP",
            ]
            for k in required:
                if k not in f:
                    raise SystemExit(2)

            # If any AF columns exist, they should match variant count.
            n_var = f["variants/POS"].shape[0]
            for af_key in ["variants/AF_ALL", "variants/AF_SAMPLE", "variants/RAF"]:
                if af_key in f and f[af_key].shape[0] != n_var:
                    raise SystemExit(2)

            # Samples are typically stored as a dataset called "samples".
            if "samples" not in f:
                raise SystemExit(2)

            # Very small sanity checks.
            if n_var == 0:
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
