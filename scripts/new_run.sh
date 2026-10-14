#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

TAG="${1:-run}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="${TS}_${TAG}"

# Exclusive creation prevents two calls in the same second from sharing a run.
# Keep the familiar timestamp-only ID unless a collision actually occurs.
mkdir -p "$RUNS_ROOT"
BASE_RUN_ID="$RUN_ID"
suffix=0
while true; do
  RUN_DIR="$RUNS_ROOT/$RUN_ID"
  if mkdir -- "$RUN_DIR" 2>/dev/null; then break; fi
  [[ ! -e "$RUN_DIR" ]] || {
    suffix=$((suffix + 1))
    RUN_ID="${BASE_RUN_ID}_$suffix"
    continue
  }
  die "Cannot create run directory: $RUN_DIR"
done
mkdir -p "$RUN_DIR"/{work,out,logs,meta,logs/condor}

echo "$RUN_ID"
