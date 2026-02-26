#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

B1="${1:?usage: run_batchpair.sh <B1> <B2> [CH_RANGE]}"
B2="${2:?usage: run_batchpair.sh <B1> <B2> [CH_RANGE]}"
CH_RANGE_RUN="${3:-${CH_RANGE:-1-22}}"

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run <tag>)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"
[[ -e "$RUN_DIR/DONE" ]] && die "Run is DONE: $RUN_DIR"

mkdir -p "$RUN_DIR"/{meta,work,out,logs}
"$ROOT/scripts/write_manifest.sh"

# Run-level overrides written by ./ancibd-pipeline prod.
OPTIONS_FILE="$RUN_DIR/meta/options.env"
if [[ -f "$OPTIONS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$OPTIONS_FILE"
fi
PCOL="${PCOL:-AF_ALL}"
PCOL="${PCOL^^}"

# Ensure we have the global IID list.
if [[ ! -s "$RUN_DIR/meta/iids.txt" ]]; then
  "$ROOT/scripts/make_iid_list.sh" >/dev/null
fi

# Stable batch tag for paths.
B1_PAD="$(printf '%03d' "$B1")"
B2_PAD="$(printf '%03d' "$B2")"
BATCH_TAG="b${B1_PAD}_b${B2_PAD}"

PLAN_DIR="$RUN_DIR/work/plans"
WORK_DIR="$RUN_DIR/work/$BATCH_TAG"
OUT_DIR="$RUN_DIR/out/$BATCH_TAG"
LOG_DIR="$RUN_DIR/logs/$BATCH_TAG"

mkdir -p "$PLAN_DIR" "$WORK_DIR" "$OUT_DIR" "$LOG_DIR"

# Idempotence: allow safe resume.
if [[ -f "$OUT_DIR/DONE" ]]; then
  echo "Batch already DONE: $BATCH_TAG"
  exit 0
fi

IID_FILE_HOST="$PLAN_DIR/${BATCH_TAG}.iids"
PAIR_FILE_HOST="$PLAN_DIR/${BATCH_TAG}.pairs"
IID_FILE_CONT="/work/run/work/plans/${BATCH_TAG}.iids"
PAIR_FILE_CONT="/work/run/work/plans/${BATCH_TAG}.pairs"

# Build the IID preload list and the pair list inside the container
# (so the host only needs Apptainer).
apptainer exec --cleanenv \
  --bind "$ROOT:/work/repo:ro" \
  --bind "$RUN_DIR:/work/run" \
  --pwd /work \
  "$SIF_IMAGE" \
  python3 /work/repo/scripts/make_batch_plan.py \
    --iids "/work/run/meta/iids.txt" \
    --batch-size "${BATCH_SIZE:-500}" \
    --b1 "$B1" --b2 "$B2" \
    --out-iids "$IID_FILE_CONT" \
    --out-pairs "$PAIR_FILE_CONT" \
  >"$LOG_DIR/plan.out" 2>"$LOG_DIR/plan.err"

[[ -s "$IID_FILE_HOST" ]] || die "Missing IID file: $IID_FILE_HOST"
[[ -s "$PAIR_FILE_HOST" ]] || die "Missing pair file: $PAIR_FILE_HOST"

HDF5_ROOT_NORM="$(hdf5_root_norm)"

# Iterate chromosomes (usually 1-22; demo is 20-20)
read -r CH_START CH_END < <(parse_ch_range "$CH_RANGE_RUN")

for ((ch=CH_START; ch<=CH_END; ch++)); do
  H5_PATH="$(h5_path_for_ch "$ch")"
  [[ -f "$H5_PATH" ]] || die "Missing HDF5 for ch${ch}: $H5_PATH (build it first: ./ancibd-pipeline build-hdf5 ${CH_RANGE_RUN})"

  H5_REL="$(rel_under_hdf5 "$H5_PATH")"

  apptainer exec --cleanenv \
    --bind "$ROOT:/work/repo:ro" \
    --bind "$HDF5_ROOT_NORM:/work/hdf5:ro" \
    --bind "$RUN_DIR:/work/run" \
    --pwd /work \
    "$SIF_IMAGE" \
    python3 /work/repo/scripts/call_ibd_chrom.py \
      --h5 "/work/hdf5/$H5_REL" \
      --ch "$ch" \
      --out-dir "/work/run/work/$BATCH_TAG" \
      --prefix "$PREFIX" \
      --pcol "$PCOL" \
      --iids-file "/work/run/work/plans/${BATCH_TAG}.iids" \
      --pairs-file "/work/run/work/plans/${BATCH_TAG}.pairs" \
    >"$LOG_DIR/ch${ch}.out" 2>"$LOG_DIR/ch${ch}.err"

done

# Summarise this batch-pair across chromosomes.
apptainer exec --cleanenv \
  --bind "$RUN_DIR:/work/run" \
  --pwd /work \
  "$SIF_IMAGE" \
  ancIBD-summary \
    --tsv "/work/run/work/$BATCH_TAG/${PREFIX}.ch" \
    --ch "$CH_RANGE_RUN" \
    --out "/work/run/out/$BATCH_TAG" \
  >"$LOG_DIR/summary.out" 2>"$LOG_DIR/summary.err"

# Sanity: ancIBD-summary should have produced the two standard outputs.
if [[ ! -f "$OUT_DIR/ch_all.tsv" || ! -f "$OUT_DIR/ibd_ind.tsv" ]]; then
  echo "ERROR: ancIBD-summary did not produce expected outputs in: $OUT_DIR" >&2
  echo "  Expected: ch_all.tsv and ibd_ind.tsv" >&2
  echo "  See: $LOG_DIR/summary.err" >&2
  exit 1
fi

touch "$OUT_DIR/DONE"
echo "DONE: $BATCH_TAG"
