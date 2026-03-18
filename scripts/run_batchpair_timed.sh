#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

# Wrapper for HTCondor pairjob runs.
#
# Responsibilities:
#   - write per-job GNU time(1) metrics to runs/<RUN_ID>/logs/timev/
#   - invoke the real pairjob runner
#
# Args:
#   <JOB_ID> <CH_RANGE> <CLUSTER> <PROCESS>

JOB_ID="${1:?missing JOB_ID}"
CH_RANGE="${2:?missing CH_RANGE}"
CLUSTER="${3:-unknown}"
PROCESS="${4:-unknown}"

: "${RUN_ID:?RUN_ID is required}"
: "${RUNS_ROOT:?RUNS_ROOT is required}"

out_dir="$RUNS_ROOT/$RUN_ID/logs/timev"
mkdir -p "$out_dir"

timev_path="$out_dir/pairjob.${CLUSTER}.${PROCESS}.timev.txt"

exec /usr/bin/time -v -o "$timev_path"   "$ROOT/scripts/run_batchpair.sh" "$JOB_ID" "$CH_RANGE"
