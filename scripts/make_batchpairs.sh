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

batch_size() {
  # Size of batch i (0-indexed) given N_IIDS and BS.
  local i="$1"
  local start=$(( i * BS ))
  local end=$(( (i + 1) * BS ))
  if (( end > N_IIDS )); then
    end="$N_IIDS"
  fi
  echo $(( end - start ))
}

OUT="$RUN_DIR/meta/batchpairs.tsv"
tmp="$OUT.tmp"
{
  for ((i=0; i<NBATCH; i++)); do
    sz_i="$(batch_size "$i")"
    for ((j=i; j<NBATCH; j++)); do
      sz_j="$(batch_size "$j")"

      # Skip within-batch jobs that cannot contain any pairs.
      # (e.g. batch_size=1, or last batch smaller than 2)
      if (( i == j )) && (( sz_i < 2 )); then
        continue
      fi

      # Cross-batch jobs always have at least 1 pair because batches are non-empty.
      echo -e "${i}\t${j}"
    done
  done
} > "$tmp"
mv "$tmp" "$OUT"

echo "Wrote $OUT (n_iids=$N_IIDS, batch_size=$BS, n_batches=$NBATCH)."
