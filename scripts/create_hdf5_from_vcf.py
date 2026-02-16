#!/usr/bin/env python3
"""Create ancIBD HDF5 for one chromosome from an imputed VCF/BCF.

This wraps ancIBD.IO.prepare_h5.vcf_to_1240K_hdf, so the build happens inside the
Apptainer image where ancIBD and its dependencies (bcftools, h5py, etc.) exist.

We intentionally default to *not* computing an in-sample allele-frequency column
(col_sample_af=""), to reduce sample-dependent metadata in the HDF5.
"""

import argparse
import os
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--in-vcf", required=True, help="Input imputed VCF/BCF (can be .vcf.gz or .bcf).")
    p.add_argument("--marker", required=True, help="Marker file (CSV with 1240k SNPs).")
    p.add_argument("--map", required=True, help="Genetic map SNP file (eigenstrat .snp).")
    p.add_argument("--af", required=True, help="Allele-frequency TSV to merge into variants/AF_ALL.")
    p.add_argument("--ch", required=True, type=int, help="Chromosome number (1-22).")
    p.add_argument("--out-h5", required=True, help="Output .h5 path.")
    p.add_argument("--out-vcf", required=True, help="Output filtered 1240k VCF path.")

    p.add_argument(
        "--col-sample-af",
        default="",
        help=(
            "Name of sample AF column to compute and store in the HDF5. "
            "Default: empty (do not compute)."
        ),
    )

    return p.parse_args()


def main() -> None:
    args = parse_args()

    # Import inside main so that a missing ancIBD gives a clean error.
    from ancIBD.IO.prepare_h5 import vcf_to_1240K_hdf  # type: ignore

    in_vcf = Path(args.in_vcf)
    marker = Path(args.marker)
    map_path = Path(args.map)
    af = Path(args.af)
    out_h5 = Path(args.out_h5)
    out_vcf = Path(args.out_vcf)

    for p in [in_vcf, marker, map_path, af]:
        if not p.exists():
            raise SystemExit(f"Missing input: {p}")

    out_h5.parent.mkdir(parents=True, exist_ok=True)
    out_vcf.parent.mkdir(parents=True, exist_ok=True)

    # Some ancIBD helper functions assume the output paths' parent directories exist.
    # We also ensure we don't leave a partially-written file with the final name.
    tmp_h5 = out_h5.with_suffix(out_h5.suffix + ".tmp")

    # Clean up stale tmp files.
    if tmp_h5.exists():
        tmp_h5.unlink()

    # ancIBD writes to path_h5 directly; we write to tmp then rename.
    print("[create_hdf5] Starting ancIBD.IO.prepare_h5.vcf_to_1240K_hdf")
    print(f"[create_hdf5] in_vcf   = {in_vcf}")
    print(f"[create_hdf5] marker   = {marker}")
    print(f"[create_hdf5] map      = {map_path}")
    print(f"[create_hdf5] af       = {af}")
    print(f"[create_hdf5] out_vcf  = {out_vcf}")
    print(f"[create_hdf5] out_h5   = {out_h5}")
    print(f"[create_hdf5] tmp_h5   = {tmp_h5}")
    print(f"[create_hdf5] ch       = {args.ch}")
    print(f"[create_hdf5] col_sample_af = {args.col_sample_af!r}")

    vcf_to_1240K_hdf(
        in_vcf_path=str(in_vcf),
        path_vcf=str(out_vcf),
        path_h5=str(tmp_h5),
        marker_path=str(marker),
        map_path=str(map_path),
        af_path=str(af),
        col_sample_af=str(args.col_sample_af),
        ch=int(args.ch),
    )

    # Atomic-ish finalize.
    if out_h5.exists():
        out_h5.unlink()
    os.replace(tmp_h5, out_h5)

    print("[create_hdf5] DONE")


if __name__ == "__main__":
    main()
