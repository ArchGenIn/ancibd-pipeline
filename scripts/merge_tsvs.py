#!/usr/bin/env python3
"""Merge multiple TSV files with a shared header.

This is intentionally *robust* to newline conventions (\n, \r\n, \r) and
optionally tolerates empty files / header-only files.

Rules:
- The first non-empty line of the first readable input is taken as the header.
- For each subsequent file, the first non-empty line is treated as its header.
  If it differs, we fail fast (merging different schemas is unsafe).
- We append all subsequent non-empty lines that are not a repeated header.

Outputs:
- Writes the merged TSV to --out.
- Prints a small stats line to stderr.
"""

import argparse
import sys
from pathlib import Path


def _read_lines(path: Path) -> list[str]:
    # newline=None enables universal newlines (handles \r, \r\n, \n)
    with path.open("r", encoding="utf-8", errors="replace", newline=None) as fh:
        return [ln.rstrip("\n") for ln in fh]


def _first_nonempty(lines: list[str]) -> tuple[int, str] | None:
    for i, ln in enumerate(lines):
        if ln.strip() != "":
            return i, ln
    return None


def merge_tsv(inputs: list[Path], out_path: Path) -> tuple[int, int]:
    if not inputs:
        raise ValueError("No input files provided")

    header: str | None = None
    merged: list[str] = []
    data_lines = 0
    used_files = 0

    for p in inputs:
        if not p.is_file():
            continue
        lines = _read_lines(p)
        hn = _first_nonempty(lines)
        if hn is None:
            # empty/blank-only file
            continue
        h_idx, h_line = hn

        if header is None:
            header = h_line
            merged.append(header)
        else:
            if h_line != header:
                raise ValueError(
                    f"Header mismatch in {p}:\n  expected: {header!r}\n  found:    {h_line!r}"
                )

        # Append data lines after the header line.
        for ln in lines[h_idx + 1 :]:
            if ln.strip() == "":
                continue
            if header is not None and ln == header:
                # tolerate repeated header
                continue
            merged.append(ln)
            data_lines += 1

        used_files += 1

    if header is None:
        raise ValueError("All inputs were empty or unreadable; no header found")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", newline="\n") as out:
        for ln in merged:
            out.write(ln)
            out.write("\n")

    return used_files, data_lines


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("inputs", nargs="+", type=Path)
    args = ap.parse_args(argv)

    try:
        used, data = merge_tsv(args.inputs, args.out)
    except Exception as e:
        print(f"merge_tsvs.py: ERROR: {e}", file=sys.stderr)
        return 2

    print(f"merge_tsvs.py: merged {used} files -> {args.out} ({data} data lines)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
