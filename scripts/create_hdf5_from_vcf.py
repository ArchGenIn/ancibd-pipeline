#!/usr/bin/env python3
"""Create an ancIBD HDF5 for one chromosome from a phased VCF/BCF."""

import argparse
from pathlib import Path

REF_AF_FIELD = "variants/AF_REF"


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
        help="Dataset name under variants/ for sample AFs.",
    )
    p.add_argument(
        "--ref-af",
        default="",
        help="Optional per-chromosome reference-AF TSV with 'pos' and 'af' columns.",
    )
    return p.parse_args()


def add_ref_af_dataset(h5_path: Path, ref_af_tsv: Path) -> None:
    import h5py  # type: ignore
    from ancIBD.IO.h5_modify import lift_af_df  # type: ignore

    with h5py.File(h5_path, "a") as f:
        if REF_AF_FIELD in f:
            del f[REF_AF_FIELD]

    lift_af_df(h5_target=str(h5_path), path_df=str(ref_af_tsv), field=REF_AF_FIELD)


def main() -> None:
    args = parse_args()

    in_vcf = Path(args.in_vcf)
    marker = Path(args.marker)
    map_path = Path(args.map)
    out_vcf = Path(args.out_vcf)
    out_h5 = Path(args.out_h5)
    tmp_h5 = Path(args.tmp_h5)
    ref_af_tsv = Path(args.ref_af) if args.ref_af else None

    print("[create_hdf5] Starting ancIBD.IO.prepare_h5.vcf_to_1240K_hdf")
    print(f"[create_hdf5] in_vcf        = {in_vcf}")
    print(f"[create_hdf5] marker        = {marker}")
    print(f"[create_hdf5] map           = {map_path}")
    print(f"[create_hdf5] ref_af_tsv    = {ref_af_tsv if ref_af_tsv else '(none)'}")
    print(f"[create_hdf5] out_vcf       = {out_vcf}")
    print(f"[create_hdf5] out_h5        = {out_h5}")
    print(f"[create_hdf5] tmp_h5        = {tmp_h5}")
    print(f"[create_hdf5] ch            = {args.ch}")
    print(f"[create_hdf5] col_sample_af = 'variants/{args.col_sample_af}'")
    print(f"[create_hdf5] ref_af_field  = '{REF_AF_FIELD}'")

    from ancIBD.IO.prepare_h5 import vcf_to_1240K_hdf  # type: ignore

    tmp_h5.parent.mkdir(parents=True, exist_ok=True)

    vcf_to_1240K_hdf(
        in_vcf_path=str(in_vcf),
        path_vcf=str(out_vcf),
        path_h5=str(tmp_h5),
        marker_path=str(marker),
        map_path=str(map_path),
        af_path="",
        col_sample_af=str(args.col_sample_af),
        ch=int(args.ch),
    )

    if ref_af_tsv is not None:
        if not ref_af_tsv.exists():
            raise SystemExit(f"Reference-AF TSV not found: {ref_af_tsv}")
        add_ref_af_dataset(tmp_h5, ref_af_tsv)

    tmp_h5.replace(out_h5)
    print("[create_hdf5] DONE")


if __name__ == "__main__":
    main()
