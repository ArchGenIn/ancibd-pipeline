#!/usr/bin/env python3
"""Merge multiple TSV files with a shared header.

Rules:
- The first non-empty line of the first readable input is taken as the header.
- For each subsequent file, the first non-empty line is treated as its header.
  If it differs, the merge fails.
- All later non-empty lines are appended, except repeated header lines.

The merge is fully streaming and keeps memory use essentially constant.
"""
import argparse
import sys
from pathlib import Path


def merge_tsv(inputs: list[Path], out_path: Path) -> tuple[int, int]:
    if not inputs:
        raise ValueError("No input files provided")

    header: str | None = None
    data_lines = 0
    used_files = 0

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", newline="\n") as out:
        for p in inputs:
            if not p.is_file():
                continue

            with p.open("r", encoding="utf-8", errors="replace", newline=None) as fh:
                file_header: str | None = None
                for raw in fh:
                    line = raw.rstrip("\r\n")
                    if line.strip() == "":
                        continue
                    file_header = line
                    break

                if file_header is None:
                    continue

                if header is None:
                    header = file_header
                    out.write(header)
                    out.write("\n")
                elif file_header != header:
                    raise ValueError(
                        f"Header mismatch in {p}:\n"
                        f"  expected: {header!r}\n"
                        f"  found:    {file_header!r}"
                    )

                for raw in fh:
                    line = raw.rstrip("\r\n")
                    if line.strip() == "":
                        continue
                    if line == header:
                        continue
                    out.write(line)
                    out.write("\n")
                    data_lines += 1

                used_files += 1

    if header is None:
        raise ValueError("All inputs were empty or unreadable; no header found")

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
