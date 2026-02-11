#!/usr/bin/env bash
set -euo pipefail

# Compare two ancIBD-summary output folders (order-insensitive).
# Usage: compare_outputs.sh <DIR_A> <DIR_B>

DIR_A="${1:?usage: compare_outputs.sh <DIR_A> <DIR_B>}"
DIR_B="${2:?usage: compare_outputs.sh <DIR_A> <DIR_B>}"

hash_sorted() {
  local f="$1"
  [[ -f "$f" ]] || { echo "MISSING"; return 0; }
  # Ignore header and row order.
  tail -n +2 "$f" | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

for name in ch_all.tsv ibd_ind.tsv; do
  A="$DIR_A/$name"
  B="$DIR_B/$name"
  HA="$(hash_sorted "$A")"
  HB="$(hash_sorted "$B")"
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
done

echo "All OK"
