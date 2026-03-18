#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

# Compare two ancIBD-summary output folders (order-insensitive).
#
# Usage:
#   compare_outputs.sh <DIR_A> <DIR_B>
#
# DIR_A / DIR_B can be:
#   - absolute paths
#   - paths relative to the repo root
#   - paths relative to RUNS_ROOT (from config/local.env)

DIR_A="${1:?usage: compare_outputs.sh <DIR_A> <DIR_B>}"
DIR_B="${2:?usage: compare_outputs.sh <DIR_A> <DIR_B>}"

resolve_dir() {
  local d="$1"

  # Absolute path: use as-is.
  if [[ "$d" = /* ]]; then
    echo "$d"
    return 0
  fi

  # Repo-root relative.
  if [[ -d "$ROOT/$d" ]]; then
    echo "$ROOT/$d"
    return 0
  fi

  # RUNS_ROOT-relative (fallback).
  echo "$RUNS_ROOT/$d"
}

DIR_A_IN="$(resolve_dir "$DIR_A")"
DIR_B_IN="$(resolve_dir "$DIR_B")"

hash_sorted() {
  local f="$1"
  [[ -f "$f" ]] || { echo "MISSING"; return 0; }
  # Ignore header and row order.
  tail -n +2 "$f" | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

checked=0
for name in ch_all.tsv ibd_ind.tsv; do
  A="$DIR_A_IN/$name"
  B="$DIR_B_IN/$name"
  HA="$(hash_sorted "$A")"
  HB="$(hash_sorted "$B")"
  if [[ "$HA" == "MISSING" && "$HB" == "MISSING" ]]; then
    echo "$name: skipped (missing in both)"
    continue
  fi
  if [[ "$HA" == "MISSING" || "$HB" == "MISSING" ]]; then
    echo "$name: missing file(s) (A=$A, B=$B)"
    exit 2
  fi
  if [[ "$HA" != "$HB" ]]; then
    echo "$name: DIFFER"
    echo "  A: $HA"
    echo "  B: $HB"
    exit 1
  else
    echo "$name: OK"
  fi
  checked=$((checked + 1))
done

[[ "$checked" -gt 0 ]] || { echo "No comparable output files found"; exit 2; }

echo "All OK"
