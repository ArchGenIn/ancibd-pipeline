#!/usr/bin/env python3
"""Run ancIBD for one chromosome from a prebuilt HDF5.

HDF5 inputs contain sample allele frequencies at variants/AF_ALL.
Optional reference frequencies can be stored at variants/RAF.
Select which one ancIBD uses with --pcol (AF_ALL or RAF).

We call the ancIBD Python API so we can pass p_col explicitly.
ancIBD writes ch<CH>.tsv; we rename it to <prefix>.ch<CH>.tsv so
ancIBD-summary can consume a folder of per-chromosome TSVs.
"""
import argparse
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--h5",
        required=True,
        help=(
            "Path to chromosome HDF5. The filename can be arbitrary as long as it "
            "contains the data for the requested chromosome."
        ),
    )
    p.add_argument("--ch", required=True, type=int, help="Chromosome number (1-22)")
    p.add_argument("--out-dir", required=True, help="Output directory to write <prefix>.ch<CH>.tsv")
    p.add_argument("--prefix", required=True, help="Output prefix (e.g. example_hazelton)")
    p.add_argument(
        "--pcol",
        default="AF_ALL",
        help="Which allele-frequency column to use: AF_ALL (sample, default) or RAF (reference)",
    )
    p.add_argument(
        "--iids-file",
        default="",
        help="Optional file with one IID per line. If omitted, all samples in the HDF5 are loaded.",
    )
    p.add_argument(
        "--pairs-file",
        default="",
        help=(
            "Optional file with IID pairs (two columns, whitespace-separated). "
            "If omitted, all pairs among loaded IIDs are run."
        ),
    )
    p.add_argument(
        "--min-cm",
        type=float,
        default=6.0,
        help="Minimum IBD segment length in cM (default: 6).",
    )
    return p.parse_args()


def _read_lines(path: Path) -> List[str]:
    lines: List[str] = []
    with path.open("r", encoding="utf-8") as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            lines.append(s)
    return lines


def read_iids(iids_file: str) -> List[str]:
    if not iids_file:
        return []
    return _read_lines(Path(iids_file))


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
    """Prepare an ancIBD-compatible folder_in prefix for an arbitrary HDF5 filename.

    ancIBD's hapBLOCK_chroms expects a *prefix* (folder_in) and constructs the input
    file as: folder_in + f"{ch}.h5".

    If the provided HDF5 path does not match that naming scheme, we create a
    temporary symlink that does. This lets the pipeline use HDF5s named like:
      chr2.merged.1240k.20250825.h5
    without renaming them.
    """
    import tempfile

    tmpdir = Path(tempfile.mkdtemp(prefix="ancibd_h5link_", dir=str(tmp_root)))
    # Use a prefix that yields a file name ending in "{ch}.h5".
    prefix = str(tmpdir / "h5.")
    link_path = Path(f"{prefix}{ch}.h5")
    try:
        # Absolute symlink is fine inside the container.
        link_path.symlink_to(h5_path)
    except FileExistsError:
        pass
    return prefix, tmpdir


def ensure_pcol_exists(h5_path: Path, pcol: str) -> None:
    """If pcol points to an HDF5 dataset, ensure it exists."""
    import h5py  # type: ignore

    with h5py.File(h5_path, "r") as f:
        if pcol not in f:
            # Helpful hint for the common confusion.
            if pcol == "variants/RAF":
                raise SystemExit(
                    f"Requested p_col={pcol} but it is missing in {h5_path}. "
                    "Rebuild HDF5 with reference AFs (build-hdf5 --with-raf), "
                    "or run with --pcol AF_ALL."
                )
            raise SystemExit(f"Requested p_col={pcol} but it is missing in {h5_path}.")


def main() -> None:
    args = parse_args()

    h5_path = Path(args.h5)
    if not h5_path.exists():
        raise SystemExit(f"Missing HDF5: {h5_path}")

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    pcol_norm = args.pcol.strip().upper()
    if pcol_norm in {"AF_ALL", "AFALL", "AF"}:
        pcol = "variants/AF_ALL"
    elif pcol_norm == "RAF":
        pcol = "variants/RAF"
    else:
        raise SystemExit(f"Invalid --pcol value: {args.pcol!r} (expected AF_ALL or RAF)")

    ensure_pcol_exists(h5_path, pcol)

    # Import inside main so missing ancIBD gives a clean error.
    from ancIBD.run import hapBLOCK_chroms  # type: ignore

    # Prepare an ancIBD folder_in prefix regardless of HDF5 naming.
    import os
    tmp_root = Path(os.environ.get("TMPDIR") or "/tmp")
    folder_in, tmpdir = prepare_folder_in(h5_path, args.ch, tmp_root=tmp_root)

    iids = read_iids(args.iids_file)
    run_iids = read_pairs(args.pairs_file)

    # Run and save.
    # NOTE: hapBLOCK_chroms always writes: <folder_out>/ch<CH>.tsv
    # (prefix_out is treated as a *subfolder* by ancIBD). We keep prefix_out
    # empty and rename the produced file to match the ancIBD CLI convention.
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
        # Best-effort cleanup of the temporary symlink directory.
        try:
            for p in tmpdir.iterdir():
                p.unlink(missing_ok=True)  # type: ignore[arg-type]
            tmpdir.rmdir()
        except Exception:
            pass

    tmp_path = out_dir / f"ch{int(args.ch)}.tsv"
    final_path = out_dir / f"{args.prefix}.ch{int(args.ch)}.tsv"

    if not tmp_path.exists():
        raise SystemExit(
            f"ancIBD did not produce expected output file: {tmp_path}. "
            "Check logs for ancIBD errors."
        )

    # Overwrite final path if it already exists (idempotence / reruns).
    if final_path.exists():
        final_path.unlink()

    tmp_path.rename(final_path)


if __name__ == "__main__":
    main()
