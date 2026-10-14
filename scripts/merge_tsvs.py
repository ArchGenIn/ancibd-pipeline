#!/usr/bin/env python3
"""Merge multiple TSV files with a shared header.

Rules:
- The first non-empty line of the first non-empty input is taken as the header.
- Every named input must exist; missing inputs fail rather than being skipped.
- For each subsequent file, the first non-empty line is treated as its header.
  If it differs, the merge fails.
- All later non-empty lines are appended, except repeated header lines.

The merge is fully streaming and keeps memory use essentially constant.
"""
import argparse
import os
import sys
import tempfile
from pathlib import Path


def merge_tsv(inputs: list[Path], out_path: Path) -> tuple[int, int]:
    if not inputs:
        raise ValueError("No input files provided")

    # Input is never a valid destination, including symlink/hard-link aliases.
    if any(p.resolve() == out_path.resolve() or
           (p.exists() and out_path.exists() and p.samefile(out_path))
           for p in inputs):
        raise ValueError("Output TSV aliases an input TSV")

    header: str | None = None
    data_lines = 0
    used_files = 0
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Stage in the output directory: a missing input or invalid header cannot
    # truncate the previous successfully merged result.
    fd, name = tempfile.mkstemp(prefix=f".{out_path.name}.tmp.", dir=out_path.parent)
    staged = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as out:
            for p in inputs:
                if not p.is_file():
                    raise FileNotFoundError(f"Missing TSV input: {p}")

                with p.open("r", encoding="utf-8", errors="replace", newline=None) as fh:
                    file_header: str | None = None
                    for raw in fh:
                        line = raw.rstrip("\r\n")
                        if line.strip():
                            file_header = line
                            break
                    if file_header is None:
                        continue
                    if header is None:
                        header = file_header
                        out.write(header + "\n")
                    elif file_header != header:
                        raise ValueError(
                            f"Header mismatch in {p}:\n"
                            f"  expected: {header!r}\n"
                            f"  found:    {file_header!r}"
                        )

                    for raw in fh:
                        line = raw.rstrip("\r\n")
                        if not line.strip() or line == header:
                            continue
                        out.write(line + "\n")
                        data_lines += 1
                    used_files += 1

        if header is None:
            raise ValueError("All inputs were empty or unreadable; no header found")
        os.replace(staged, out_path)
    finally:
        staged.unlink(missing_ok=True)

    return used_files, data_lines


def read_input_list(path: Path) -> list[Path]:
    inputs: list[Path] = []
    with path.open("r", encoding="utf-8") as fh:
        for raw in fh:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            inputs.append(Path(s))
    return inputs


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument(
        "--input-list",
        type=Path,
        default=None,
        help="Optional newline-delimited file containing input TSV paths. Useful when there are too many inputs for argv.",
    )
    ap.add_argument("inputs", nargs="*", type=Path)
    args = ap.parse_args(argv)

    inputs: list[Path] = list(args.inputs)
    if args.input_list is not None:
        if (args.input_list.resolve() == args.out.resolve() or
                (args.out.exists() and args.input_list.samefile(args.out))):
            print("merge_tsvs.py: ERROR: output aliases --input-list", file=sys.stderr)
            return 2
        inputs.extend(read_input_list(args.input_list))

    try:
        used, data = merge_tsv(inputs, args.out)
    except Exception as e:
        print(f"merge_tsvs.py: ERROR: {e}", file=sys.stderr)
        return 2

    print(f"merge_tsvs.py: merged {used} files -> {args.out} ({data} data lines)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
