#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

# Wrapper for HTCondor batchpair jobs.
#
# Responsibilities:
#   - write per-job GNU time(1) metrics to runs/<RUN_ID>/logs/timev/
#   - invoke the real batchpair runner
#
# Args:
#   <B1> <B2> <CH_RANGE> <CLUSTER> <PROCESS>

B1="${1:?missing B1}"
B2="${2:?missing B2}"
CH_RANGE="${3:?missing CH_RANGE}"
CLUSTER="${4:-unknown}"
PROCESS="${5:-unknown}"

: "${RUN_ID:?RUN_ID is required}"
: "${RUNS_ROOT:?RUNS_ROOT is required}"

out_dir="$RUNS_ROOT/$RUN_ID/logs/timev"
mkdir -p "$out_dir"

timev_path="$out_dir/batchpair.${CLUSTER}.${PROCESS}.timev.txt"

exec /usr/bin/time -v -o "$timev_path" \
  "$ROOT/scripts/run_batchpair.sh" "$B1" "$B2" "$CH_RANGE"
