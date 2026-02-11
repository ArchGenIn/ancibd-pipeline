#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

RUN_ID="${RUN_ID:?set RUN_ID env var (use scripts/new_run.sh)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

# Ensure IID list exists.
if [[ ! -s "$RUN_DIR/meta/iids.txt" ]]; then
  "$ROOT/scripts/make_iid_list.sh" >/dev/null
fi

N_IIDS=$(wc -l < "$RUN_DIR/meta/iids.txt" | tr -d ' ')
BS="${BATCH_SIZE:-500}"

if [[ "$BS" -le 0 ]]; then
  die "BATCH_SIZE must be > 0; got: $BS"
fi

NBATCH=$(( (N_IIDS + BS - 1) / BS ))

OUT="$RUN_DIR/meta/batchpairs.tsv"
tmp="$OUT.tmp"
{
  for ((i=0; i<NBATCH; i++)); do
    for ((j=i; j<NBATCH; j++)); do
      echo -e "${i}\t${j}"
    done
  done
} > "$tmp"
mv "$tmp" "$OUT"

echo "Wrote $OUT (n_iids=$N_IIDS, batch_size=$BS, n_batches=$NBATCH)."
