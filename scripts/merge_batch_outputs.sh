#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run <tag>)}"
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

    # Be tolerant to an optional header, but otherwise validate.
    if [[ "$b1" == "b1" && "$b2" == "b2" ]]; then
      continue
    fi
    [[ "$b1" =~ ^[0-9]+$ ]] || die "Invalid B1 in $PAIRS_FILE: '$b1'"
    [[ "$b2" =~ ^[0-9]+$ ]] || die "Invalid B2 in $PAIRS_FILE: '$b2'"

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

# Convert a host path under $RUN_DIR into a path visible inside the container.
to_cont_path() {
  local host_path="$1"
  local rel="${host_path#"$RUN_DIR"/}"
  echo "/work/run/$rel"
}

count_lines_in_container() {
  local cont_path="$1"
  apptainer exec --cleanenv \
    --bind "$RUN_DIR:/work/run" \
    --pwd /work \
    "$SIF_IMAGE" \
    python3 - "$cont_path" <<'PY'
import sys
p=sys.argv[1]
with open(p,'r',encoding='utf-8',errors='replace',newline=None) as fh:
    n=sum(1 for _ in fh)
print(n)
PY
}

merge_one() {
  local name="$1"
  local out_host="$2"

  local inputs_host=()
  local d f
  for d in "${batch_dirs[@]}"; do
    f="$d/$name"
    [[ -f "$f" ]] || continue
    inputs_host+=("$f")
  done

  [[ ${#inputs_host[@]} -gt 0 ]] || die "No input files found for $name under: $OUT_BASE"

  # Build container-visible paths.
  local out_cont
  out_cont="$(to_cont_path "$out_host")"

  local inputs_cont=()
  local h
  for h in "${inputs_host[@]}"; do
    inputs_cont+=("$(to_cont_path "$h")")
  done

  # Merge inside the container (so the host only needs Apptainer).
  apptainer exec --cleanenv \
    --bind "$ROOT:/work/repo:ro" \
    --bind "$RUN_DIR:/work/run" \
    --pwd /work \
    "$SIF_IMAGE" \
    python3 /work/repo/scripts/merge_tsvs.py --out "$out_cont" "${inputs_cont[@]}"

  # If any input has data beyond the header, the merged file must too.
  local total_data=0
  local lines
  local p
  for p in "${inputs_cont[@]}"; do
    lines="$(count_lines_in_container "$p")"
    if [[ "$lines" -gt 1 ]]; then
      total_data=$((total_data + lines - 1))
    fi
  done

  lines="$(count_lines_in_container "$out_cont")"
  if [[ "$total_data" -gt 0 && "$lines" -le 1 ]]; then
    echo "ERROR: Merge produced only a header for $name, but inputs had data." >&2
    echo "Hint: check newline conventions and headers in per-batch TSVs." >&2
    exit 1
  fi

  [[ -s "$out_host" ]] || die "Merged file is empty: $out_host"
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
