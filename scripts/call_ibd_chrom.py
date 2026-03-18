#!/usr/bin/env python3
"""Run ancIBD for one chromosome from a prebuilt HDF5."""
import argparse
import os
import tempfile
from pathlib import Path
from typing import List, Tuple


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--h5", required=True, help="Chromosome HDF5.")
    p.add_argument("--ch", required=True, type=int, help="Chromosome number (1-22)")
    p.add_argument("--out-dir", required=True, help="Directory for <prefix>.ch<CH>.tsv")
    p.add_argument("--prefix", required=True, help="Output prefix")
    p.add_argument("--pcol", default="AF_ALL", help="AF field to use: AF_ALL, RAF, or AF_REF.")
    p.add_argument("--iids-file", default="", help="Optional file with one IID per line.")
    p.add_argument(
        "--pairs-file",
        default="",
        help="Optional file with IID pairs in two whitespace-separated columns.",
    )
    p.add_argument("--min-cm", type=float, default=6.0, help="Minimum IBD segment length in cM.")
    return p.parse_args()


def _read_lines(path: Path) -> List[str]:
    lines: List[str] = []
    with path.open("r", encoding="utf-8") as f:
        for raw in f:
            s = raw.strip()
            if s and not s.startswith("#"):
                lines.append(s)
    return lines


def read_iids(iids_file: str) -> List[str]:
    return [] if not iids_file else _read_lines(Path(iids_file))


def read_pairs(pairs_file: str) -> List[Tuple[str, str]]:
    if not pairs_file:
        return []
    pairs: List[Tuple[str, str]] = []
    with Path(pairs_file).open("r", encoding="utf-8") as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            parts = s.split()
            if len(parts) < 2:
                raise SystemExit(f"Bad pairs line (expected 2 columns): {raw!r}")
            pairs.append((parts[0], parts[1]))
    return pairs


def prepare_folder_in(h5_path: Path, ch: int, *, tmp_root: Path) -> tuple[str, Path]:
    tmpdir = Path(tempfile.mkdtemp(prefix="ancibd_h5link_", dir=str(tmp_root)))
    prefix = str(tmpdir / "h5.")
    Path(f"{prefix}{ch}.h5").symlink_to(h5_path)
    return prefix, tmpdir


def ensure_pcol_exists(h5_path: Path, pcol: str) -> None:
    import h5py  # type: ignore

    with h5py.File(h5_path, "r") as f:
        if pcol not in f:
            if pcol == "variants/RAF":
                raise SystemExit(
                    f"Requested p_col={pcol} but it is missing in {h5_path}. "
                    "Use --pcol AF_ALL or rebuild from an input VCF/BCF that provides RAF."
                )
            if pcol == "variants/AF_REF":
                raise SystemExit(
                    f"Requested p_col={pcol} but it is missing in {h5_path}. "
                    "Rebuild the HDF5 with --with-ref-af or use --pcol AF_ALL or RAF."
                )
            raise SystemExit(f"Requested p_col={pcol} but it is missing in {h5_path}.")


def normalize_pcol(value: str) -> str:
    pcol_norm = value.strip().upper()
    if pcol_norm == "AF_ALL":
        return "variants/AF_ALL"
    if pcol_norm == "RAF":
        return "variants/RAF"
    if pcol_norm == "AF_REF":
        return "variants/AF_REF"
    raise SystemExit(f"Invalid --pcol value: {value!r} (expected AF_ALL, RAF, or AF_REF)")


def main() -> None:
    args = parse_args()

    h5_path = Path(args.h5)
    if not h5_path.exists():
        raise SystemExit(f"Missing HDF5: {h5_path}")

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    pcol = normalize_pcol(args.pcol)
    ensure_pcol_exists(h5_path, pcol)

    from ancIBD.run import hapBLOCK_chroms  # type: ignore

    tmp_root = Path(os.environ.get("TMPDIR") or "/tmp")
    folder_in, tmpdir = prepare_folder_in(h5_path, args.ch, tmp_root=tmp_root)
    iids = read_iids(args.iids_file)
    run_iids = read_pairs(args.pairs_file)

    try:
        hapBLOCK_chroms(
            folder_in=folder_in,
            iids=iids,
            run_iids=run_iids,
            ch=int(args.ch),
            folder_out=str(out_dir),
            output=False,
            prefix_out="",
            logfile=False,
            l_model="h5",
            e_model="haploid_gl2",
            h_model="FiveStateScaled",
            t_model="standard",
            p_col=pcol,
            ibd_in=1,
            ibd_out=10,
            ibd_jump=400,
            min_cm=float(args.min_cm),
            cutoff_post=0.99,
            max_gap=0.0075,
        )
    finally:
        try:
            for p in tmpdir.iterdir():
                p.unlink(missing_ok=True)  # type: ignore[arg-type]
            tmpdir.rmdir()
        except Exception:
            pass

    tmp_path = out_dir / f"ch{int(args.ch)}.tsv"
    final_path = out_dir / f"{args.prefix}.ch{int(args.ch)}.tsv"
    if not tmp_path.exists():
        raise SystemExit(f"ancIBD did not produce expected output file: {tmp_path}. Check logs for ancIBD errors.")
    if final_path.exists():
        final_path.unlink()
    tmp_path.rename(final_path)


if __name__ == "__main__":
    main()
