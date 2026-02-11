#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

TAG="${1:-run}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="${TS}_${TAG}"

RUN_DIR="$RUNS_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"/{work,out,logs,meta,logs/condor}

echo "$RUN_ID"
