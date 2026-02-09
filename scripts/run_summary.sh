#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

CH_RANGE="${1:-1-22}"
RUN_ID="${RUN_ID:?set RUN_ID env var}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

[[ -e "$RUN_DIR/DONE" ]] && die "Run is DONE: $RUN_DIR"

mkdir -p "$RUN_DIR"/{work,out,logs}

apptainer exec --cleanenv \
  --bind "$DATA_ROOT:/work/data:ro" \
  --bind "$RUN_DIR:/work/run" \
  --pwd /work \
  "$SIF_IMAGE" \
  ancIBD-summary \
    --tsv "/work/run/work/${PREFIX}.ch" \
    --ch "$CH_RANGE" \
    --out "/work/run/out/" \
  >"$RUN_DIR/logs/summary.out" 2>"$RUN_DIR/logs/summary.err"

date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN_DIR/DONE"
