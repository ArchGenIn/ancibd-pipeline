#!/usr/bin/env python3
"""Create an ancIBD HDF5 for one chromosome from a (phased) VCF/BCF.

This is a thin wrapper around ``ancIBD.IO.prepare_h5.vcf_to_1240K_hdf`` with two
pipeline-specific choices:

1) We always compute **sample allele frequencies** into ``variants/AF_ALL`` by
   default (matching the ancIBD Python API docs which recommend p_col being
   either ``variants/AF_ALL`` (sample) or ``variants/RAF`` (reference)).

2) Optionally, we can *add* reference allele frequencies into ``variants/RAF``
   from a per-chromosome TSV file.

The final output is written atomically via a ``.tmp`` file.
"""

import argparse
import csv
from pathlib import Path
from typing import Dict, Optional, Tuple


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--in-vcf", required=True)
    p.add_argument("--marker", required=True)
    p.add_argument("--map", required=True)
    p.add_argument("--out-vcf", required=True)
    p.add_argument("--out-h5", required=True)
    p.add_argument("--tmp-h5", required=True)
    p.add_argument("--ch", required=True, type=int)
    p.add_argument(
        "--col-sample-af",
        default="AF_ALL",
        help="Dataset name (under variants/) to store sample AFs. Default: AF_ALL",
    )
    p.add_argument(
        "--raf",
        default="",
        help=(
            "Optional per-chromosome reference AF TSV to add as variants/RAF. "
            "If omitted, variants/RAF is not created."
        ),
    )
    return p.parse_args()


def _pick_column(headers: Tuple[str, ...], candidates: Tuple[str, ...]) -> Optional[str]:
    hset = {h.lower(): h for h in headers}
    for c in candidates:
        if c.lower() in hset:
            return hset[c.lower()]
    return None


def load_pos_to_af(tsv_path: Path) -> Dict[int, float]:
    """Load a POS->AF mapping from a TSV.

    We try to be liberal about column names because files in the wild vary.
    We primarily match by POS, mirroring ancIBD's own merge behavior.
    """

    with tsv_path.open("r", encoding="utf-8") as f:
        # Dialect sniffing can be fragile; assume TSV.
        reader = csv.reader(f, delimiter="\t")
        try:
            header = next(reader)
        except StopIteration:
            raise SystemExit(f"Empty RAF TSV: {tsv_path}")

        headers = tuple(h.strip() for h in header)

        pos_col = _pick_column(headers, ("POS", "pos", "position", "bp", "BP"))
        af_col = _pick_column(
            headers,
            (
                "AF",
                "af",
                "ALT_AF",
                "ALT_FREQ",
                "FREQ",
                "freq",
                "AF_ALL",
                "af_all",
            ),
        )

        # If we didn't find explicit AF column, fall back to the last column.
        if pos_col is None:
            raise SystemExit(
                f"Could not find POS column in RAF TSV {tsv_path}. Headers: {headers}"
            )
        if af_col is None:
            af_col = headers[-1]

        idx = {h: i for i, h in enumerate(headers)}
        i_pos = idx[pos_col]
        i_af = idx[af_col]

        out: Dict[int, float] = {}
        for row in reader:
            if not row or row[0].startswith("#"):
                continue
            try:
                pos = int(row[i_pos])
                af = float(row[i_af])
            except Exception:
                continue
            if af < 0.0 or af > 1.0:
                continue
            out[pos] = af

    if not out:
        raise SystemExit(
            f"Parsed RAF TSV but found 0 usable AF values: {tsv_path} (pos_col={pos_col}, af_col={af_col})"
        )
    return out


def add_raf_dataset(h5_path: Path, raf_tsv: Path) -> None:
    import h5py  # type: ignore
    import numpy as np  # type: ignore

    pos_to_af = load_pos_to_af(raf_tsv)

    with h5py.File(h5_path, "r+") as f:
        if "variants/POS" not in f:
            raise SystemExit(f"Missing variants/POS in {h5_path}; cannot add RAF")

        pos = f["variants/POS"][:]
        n = int(pos.shape[0])
        raf = np.full(n, 0.5, dtype=np.float32)

        hits = 0
        for i, p in enumerate(pos.tolist()):
            v = pos_to_af.get(int(p))
            if v is not None:
                raf[i] = float(v)
                hits += 1

        # Replace if exists.
        if "variants/RAF" in f:
            del f["variants/RAF"]
        f.create_dataset("variants/RAF", data=raf, dtype="f4")

    print(
        f"[create_hdf5] Added variants/RAF from {raf_tsv} (matched {hits}/{n} variants; "
        f"unmatched set to 0.5)"
    )


def main() -> None:
    args = parse_args()

    in_vcf = Path(args.in_vcf)
    marker = Path(args.marker)
    map_path = Path(args.map)
    out_vcf = Path(args.out_vcf)
    out_h5 = Path(args.out_h5)
    tmp_h5 = Path(args.tmp_h5)
    ch = int(args.ch)

    raf_tsv = Path(args.raf) if args.raf else None

    # Report
    print("[create_hdf5] Starting ancIBD.IO.prepare_h5.vcf_to_1240K_hdf")
    print(f"[create_hdf5] in_vcf   = {in_vcf}")
    print(f"[create_hdf5] marker   = {marker}")
    print(f"[create_hdf5] map      = {map_path}")
    print(f"[create_hdf5] raf_tsv  = {raf_tsv if raf_tsv else '(none)'}")
    print(f"[create_hdf5] out_vcf  = {out_vcf}")
    print(f"[create_hdf5] out_h5   = {out_h5}")
    print(f"[create_hdf5] tmp_h5   = {tmp_h5}")
    print(f"[create_hdf5] ch       = {ch}")
    print(f"[create_hdf5] col_sample_af = 'variants/{args.col_sample_af}'")

    # Import here so errors are clean if ancIBD isn't installed.
    from ancIBD.IO.prepare_h5 import vcf_to_1240K_hdf  # type: ignore

    tmp_h5.parent.mkdir(parents=True, exist_ok=True)

    # IMPORTANT: vcf_to_1240K_hdf has changed argument order across ancIBD
    # versions. To avoid "multiple values" bugs we call it with keywords only.
    # We write to tmp_h5 first and then atomically move to out_h5.
    vcf_to_1240K_hdf(
        in_vcf_path=str(in_vcf),
        path_vcf=str(out_vcf),
        path_h5=str(tmp_h5),
        marker_path=str(marker),
        map_path=str(map_path),
        # Do not merge external AF TSVs into AF_ALL here. We always compute
        # in-sample AFs into variants/<col_sample_af>. Reference AFs (optional)
        # are injected into variants/RAF below.
        af_path="",
        col_sample_af=str(args.col_sample_af),
        ch=ch,
    )

    # Optionally add reference allele frequencies.
    if raf_tsv is not None:
        if not raf_tsv.exists():
            raise SystemExit(f"RAF TSV not found: {raf_tsv}")
        add_raf_dataset(tmp_h5, raf_tsv)

    # Atomically move tmp -> final.
    import shutil

    shutil.move(str(tmp_h5), str(out_h5))

    print("[create_hdf5] DONE")


if __name__ == "__main__":
    main()
