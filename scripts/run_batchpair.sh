#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

JOB_ID="${1:?usage: run_batchpair.sh <JOB_ID> [CH_RANGE]}"
CH_RANGE_RUN="${2:-${CH_RANGE:-1-22}}"

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run <tag>)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"
[[ -e "$RUN_DIR/DONE" ]] && die "Run is DONE: $RUN_DIR"

mkdir -p "$RUN_DIR"/{meta,work,out,logs}
"$ROOT/scripts/write_manifest.sh"

OPTIONS_FILE="$RUN_DIR/meta/options.env"
if [[ -f "$OPTIONS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$OPTIONS_FILE"
fi
PCOL="${PCOL:-AF_ALL}"
PCOL="${PCOL^^}"

IID_FILE_HOST="$RUN_DIR/work/plans/${JOB_ID}.iids"
PAIR_FILE_HOST="$RUN_DIR/work/plans/${JOB_ID}.pairs"
[[ -s "$IID_FILE_HOST" ]] || die "Missing IID file: $IID_FILE_HOST"
[[ -s "$PAIR_FILE_HOST" ]] || die "Missing pair file: $PAIR_FILE_HOST"

WORK_DIR="$RUN_DIR/work/$JOB_ID"
OUT_DIR="$RUN_DIR/out/$JOB_ID"
LOG_DIR="$RUN_DIR/logs/$JOB_ID"
mkdir -p "$WORK_DIR" "$OUT_DIR" "$LOG_DIR"

if [[ -f "$OUT_DIR/DONE" ]]; then
  echo "Job already DONE: $JOB_ID"
  exit 0
fi

HDF5_ROOT_NORM="$(hdf5_root_norm)"
read -r CH_START CH_END < <(parse_ch_range "$CH_RANGE_RUN")

for ((ch=CH_START; ch<=CH_END; ch++)); do
  H5_PATH="$(h5_path_for_ch "$ch")"
  [[ -f "$H5_PATH" ]] || die "Missing HDF5 for ch${ch}: $H5_PATH (build it first: ./ancibd-pipeline build-hdf5 ${CH_RANGE_RUN})"
  H5_REL="$(rel_under_hdf5 "$H5_PATH")"

  apptainer exec --cleanenv     --bind "$ROOT:/work/repo:ro"     --bind "$HDF5_ROOT_NORM:/work/hdf5:ro"     --bind "$RUN_DIR:/work/run"     --pwd /work     "$SIF_IMAGE"     python3 /work/repo/scripts/call_ibd_chrom.py       --h5 "/work/hdf5/$H5_REL"       --ch "$ch"       --out-dir "/work/run/work/$JOB_ID"       --prefix "$PREFIX"       --pcol "$PCOL"       --iids-file "/work/run/work/plans/${JOB_ID}.iids"       --pairs-file "/work/run/work/plans/${JOB_ID}.pairs"     >"$LOG_DIR/ch${ch}.out" 2>"$LOG_DIR/ch${ch}.err"
done

apptainer exec --cleanenv   --bind "$RUN_DIR:/work/run"   --pwd /work   "$SIF_IMAGE"   ancIBD-summary     --tsv "/work/run/work/$JOB_ID/${PREFIX}.ch"     --ch "$CH_RANGE_RUN"     --out "/work/run/out/$JOB_ID"   >"$LOG_DIR/summary.out" 2>"$LOG_DIR/summary.err"

if [[ ! -f "$OUT_DIR/ch_all.tsv" || ! -f "$OUT_DIR/ibd_ind.tsv" ]]; then
  echo "ERROR: ancIBD-summary did not produce expected outputs in: $OUT_DIR" >&2
  echo "  Expected: ch_all.tsv and ibd_ind.tsv" >&2
  echo "  See: $LOG_DIR/summary.err" >&2
  exit 1
fi

touch "$OUT_DIR/DONE"
echo "DONE: $JOB_ID"
