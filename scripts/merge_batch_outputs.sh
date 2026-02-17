#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

RUN_ID="${RUN_ID:?set RUN_ID env var (use scripts/new_run.sh)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

[[ -e "$RUN_DIR/DONE" ]] && die "Run is DONE: $RUN_DIR"

OUT_BASE="$RUN_DIR/out"

# Enforce completeness: do not merge partial results.
PAIRS_FILE="$RUN_DIR/meta/batchpairs.tsv"
if [[ -f "$PAIRS_FILE" ]]; then
  missing=0
  bad=0
  while IFS=$'\t' read -r b1 b2 rest; do
    [[ -n "${b1:-}" ]] || continue
    tag="$(printf 'b%03d_b%03d' "$b1" "$b2")"
    d="$OUT_BASE/$tag"
    if [[ ! -f "$d/DONE" ]]; then
      missing=$((missing + 1))
      continue
    fi
    if [[ ! -s "$d/ch_all.tsv" || ! -s "$d/ibd_ind.tsv" ]]; then
      bad=$((bad + 1))
    fi
  done < "$PAIRS_FILE"

  if [[ $missing -ne 0 || $bad -ne 0 ]]; then
    echo "Refusing to merge: expected batchpairs are incomplete." >&2
    echo "  missing DONE: $missing" >&2
    echo "  DONE but missing TSVs: $bad" >&2
    echo "Use: ./ancibd-pipeline check-batch (and re-run missing pairs)" >&2
    exit 1
  fi
fi

# Collect all per-batch outputs.
shopt -s nullglob
batch_dirs=("$OUT_BASE"/b*_b*)
shopt -u nullglob

[[ ${#batch_dirs[@]} -gt 0 ]] || die "No batch output folders found under: $OUT_BASE"

mkdir -p "$OUT_BASE/merged"

merge_one() {
  local name="$1"
  local out_path="$2"
  local first=1
  : > "$out_path"

  local f
  for f in "${batch_dirs[@]}"/"$name"; do
    [[ -f "$f" ]] || continue
    if [[ $first -eq 1 ]]; then
      cat "$f" >> "$out_path"
      first=0
    else
      # Skip header
      tail -n +2 "$f" >> "$out_path"
    fi
  done

  [[ -s "$out_path" ]] || die "Merged file is empty: $out_path"
}

merge_one "ch_all.tsv" "$OUT_BASE/merged/ch_all.tsv"
merge_one "ibd_ind.tsv" "$OUT_BASE/merged/ibd_ind.tsv"

# Optional: build deterministic hashes (ignoring row order).
{
  echo "RUN_ID=$RUN_ID"
  echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "BATCH_DIRS=${#batch_dirs[@]}"
  echo
  for f in "$OUT_BASE/merged/ch_all.tsv" "$OUT_BASE/merged/ibd_ind.tsv"; do
    echo "[$(basename "$f")]"
    head -n 1 "$f"
    tail -n +2 "$f" | LC_ALL=C sort | sha256sum
    echo
  done
} > "$OUT_BASE/merged/manifest.txt"

echo "Merged outputs in: $OUT_BASE/merged"

date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN_DIR/DONE"
