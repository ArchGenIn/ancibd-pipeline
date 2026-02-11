#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

RUN_ID="${RUN_ID:?set RUN_ID env var (use scripts/new_run.sh)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

CH_RANGE_RUN="${1:-${CH_RANGE:-1-22}}"

# Ensure IID list exists.
if [[ ! -s "$RUN_DIR/meta/iids.txt" ]]; then
  "$ROOT/scripts/make_iid_list.sh" >/dev/null
fi

N_IIDS="$(wc -l < "$RUN_DIR/meta/iids.txt")"
BS="${BATCH_SIZE:-500}"
NBATCH=$(( (N_IIDS + BS - 1) / BS ))

echo "Batch run: n_iids=$N_IIDS batch_size=$BS n_batches=$NBATCH ch_range=$CH_RANGE_RUN"

for ((i=0; i<NBATCH; i++)); do
  for ((j=i; j<NBATCH; j++)); do
    "$ROOT/scripts/run_batchpair.sh" "$i" "$j" "$CH_RANGE_RUN"
  done
done

"$ROOT/scripts/merge_batch_outputs.sh"
