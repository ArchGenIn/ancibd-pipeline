#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer
require_cmd python3

B1="${1:?usage: run_batchpair.sh <B1> <B2> [CH_RANGE]}"
B2="${2:?usage: run_batchpair.sh <B1> <B2> [CH_RANGE]}"
CH_RANGE_RUN="${3:-${CH_RANGE:-1-22}}"

RUN_ID="${RUN_ID:?set RUN_ID env var (use scripts/new_run.sh)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"
[[ -e "$RUN_DIR/DONE" ]] && die "Run is DONE: $RUN_DIR"

mkdir -p "$RUN_DIR"/{meta,work,out,logs}
"$ROOT/scripts/write_manifest.sh"

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

IID_FILE="$PLAN_DIR/${BATCH_TAG}.iids"
PAIR_FILE="$PLAN_DIR/${BATCH_TAG}.pairs"

python3 "$ROOT/scripts/make_batch_plan.py" \
  --iids "$RUN_DIR/meta/iids.txt" \
  --batch-size "${BATCH_SIZE:-500}" \
  --b1 "$B1" --b2 "$B2" \
  --out-iids "$IID_FILE" \
  --out-pairs "$PAIR_FILE" \
  >"$LOG_DIR/plan.out" 2>"$LOG_DIR/plan.err"

[[ -s "$IID_FILE" ]] || die "Missing IID file: $IID_FILE"
[[ -s "$PAIR_FILE" ]] || die "Missing pair file: $PAIR_FILE"

# Prepare static per-ch inputs
DATA_ROOT_NORM="$(data_root_norm)"
MAP_REL="$(rel_under_data "$MAP_PATH")"

# Iterate chromosomes (usually 1-22; demo is 20-20)
read -r CH_START CH_END < <(parse_ch_range "$CH_RANGE_RUN")

for ((ch=CH_START; ch<=CH_END; ch++)); do
  VCF_PATH="$(tpl "$VCF_TEMPLATE" "$ch")"
  MARKER_PATH="$(tpl "$MARKER_TEMPLATE" "$ch")"
  AF_PATH="$(tpl "$AF_TEMPLATE" "$ch")"

  [[ -f "$VCF_PATH" ]] || die "Missing VCF: $VCF_PATH"
  [[ -f "$MARKER_PATH" ]] || die "Missing markers: $MARKER_PATH"
  [[ -f "$AF_PATH" ]] || die "Missing AF: $AF_PATH"

  VCF_REL="$(rel_under_data "$VCF_PATH")"
  MARKER_REL="$(rel_under_data "$MARKER_PATH")"
  AF_REL="$(rel_under_data "$AF_PATH")"

  apptainer exec --cleanenv \
    --bind "$DATA_ROOT_NORM:/work/data:ro" \
    --bind "$RUN_DIR:/work/run" \
    --pwd /work \
    "$SIF_IMAGE" \
    ancIBD-run \
      --vcf "/work/data/$VCF_REL" \
      --ch "$ch" \
      --out "/work/run/work/$BATCH_TAG" \
      --marker_path "/work/data/$MARKER_REL" \
      --map_path "/work/data/$MAP_REL" \
      --af_path "/work/data/$AF_REL" \
      --prefix "$PREFIX" \
      --iid "/work/run/work/plans/${BATCH_TAG}.iids" \
      --pair "/work/run/work/plans/${BATCH_TAG}.pairs" \
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

touch "$OUT_DIR/DONE"
echo "DONE: $BATCH_TAG"
