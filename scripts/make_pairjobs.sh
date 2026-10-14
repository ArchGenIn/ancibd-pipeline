#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

usage() {
  cat <<'USAGE'
Usage:
  make_pairjobs.sh --mode all
  make_pairjobs.sh --mode incremental --delta-iids PATH --delta-kind new|analyzed
  make_pairjobs.sh --mode pair-history --previous-run PATH [--previous-run PATH ...]
USAGE
}

MODE=""
DELTA_IIDS=""
DELTA_KIND=""
PREVIOUS_RUNS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ -n "${2:-}" ]] || die "--mode requires a value"
      MODE="$2"; shift 2 ;;
    --delta-iids)
      [[ -n "${2:-}" ]] || die "--delta-iids requires a value"
      DELTA_IIDS="$2"; shift 2 ;;
    --delta-kind)
      [[ -n "${2:-}" ]] || die "--delta-kind requires a value"
      DELTA_KIND="$2"; shift 2 ;;
    --previous-run)
      [[ -n "${2:-}" ]] || die "--previous-run requires a value"
      PREVIOUS_RUNS+=("$2"); shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

[[ -n "$MODE" ]] || die "--mode is required"
[[ "$MODE" == "all" || "$MODE" == "incremental" || "$MODE" == "pair-history" ]] || \
  die "--mode must be all, incremental, or pair-history"

case "$MODE" in
  all)
    [[ -z "$DELTA_IIDS" && -z "$DELTA_KIND" && ${#PREVIOUS_RUNS[@]} -eq 0 ]] || \
      die "--mode all does not accept incremental-history arguments"
    ;;
  incremental)
    [[ -f "$DELTA_IIDS" ]] || die "Missing --delta-iids file: $DELTA_IIDS"
    [[ "$DELTA_KIND" == "new" || "$DELTA_KIND" == "analyzed" ]] || die "--delta-kind must be new or analyzed"
    [[ ${#PREVIOUS_RUNS[@]} -eq 0 ]] || die "--previous-run cannot be combined with legacy incremental mode"
    ;;
  pair-history)
    [[ -z "$DELTA_IIDS" && -z "$DELTA_KIND" ]] || \
      die "--mode pair-history is mutually exclusive with --delta-iids/--delta-kind"
    [[ ${#PREVIOUS_RUNS[@]} -gt 0 ]] || die "--mode pair-history requires at least one --previous-run PATH"
    ;;
esac

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

# Never erase a saved historical plan (or alter a completed run). Existing
# iids.txt is allowed: prod/prod-incremental generate it immediately beforehand.
assert_run_unpopulated_for_metadata "$RUN_DIR"
for metadata in target_iids.txt incremental.env incremental_source_iids.txt previous_runs.txt; do
  [[ ! -e "$RUN_DIR/meta/$metadata" ]] || die "Existing planning metadata: $RUN_DIR/meta/$metadata"
done
if [[ ! -s "$RUN_DIR/meta/iids.txt" ]]; then
  "$ROOT/scripts/make_iid_list.sh" >/dev/null
fi

PLANS_DIR="$RUN_DIR/work/plans"
OUT="$RUN_DIR/meta/pairjobs.tsv"
mkdir -p "$RUN_DIR/meta" "$PLANS_DIR"

APPTAINER_BIND_ARGS=(
  --bind "$ROOT:/work/repo:ro"
  --bind "$RUN_DIR:/work/run"
)

ARGS=(
  --iids "/work/run/meta/iids.txt"
  --batch-size "$BATCH_SIZE"
  --mode "$MODE"
  --plans-dir "/work/run/work/plans"
  --out-jobs "/work/run/meta/pairjobs.tsv"
)

if [[ "$MODE" == "incremental" ]]; then
  DELTA_IIDS_ABS="$(abs_path "$DELTA_IIDS")"
  DELTA_IIDS_PARENT="$(dirname "$DELTA_IIDS_ABS")"
  DELTA_IIDS_BASE="$(basename "$DELTA_IIDS_ABS")"

  cp "$DELTA_IIDS_ABS" "$RUN_DIR/meta/incremental_source_iids.txt"
  printf 'INCREMENTAL_MODE=iid-delta\nDELTA_KIND=%s\n' "$DELTA_KIND" > "$RUN_DIR/meta/incremental.env"

  APPTAINER_BIND_ARGS+=(
    --bind "$DELTA_IIDS_PARENT:/work/delta-src:ro"
  )
  ARGS+=(
    --delta-iids "/work/delta-src/$DELTA_IIDS_BASE"
    --delta-kind "$DELTA_KIND"
    --out-target-iids "/work/run/meta/target_iids.txt"
  )
elif [[ "$MODE" == "pair-history" ]]; then
  printf 'INCREMENTAL_MODE=pair-history\n' > "$RUN_DIR/meta/incremental.env"
  : > "$RUN_DIR/meta/previous_runs.txt"

  for idx in "${!PREVIOUS_RUNS[@]}"; do
    PREV_ABS="$(abs_path "${PREVIOUS_RUNS[$idx]}")"
    [[ -d "$PREV_ABS" ]] || die "Previous run directory does not exist: $PREV_ABS"
    PREV_CONT="/work/history/run${idx}"
    printf '%s\n' "$PREV_ABS" >> "$RUN_DIR/meta/previous_runs.txt"
    APPTAINER_BIND_ARGS+=(
      --bind "$PREV_ABS:$PREV_CONT:ro"
    )
    ARGS+=(
      --previous-run "$PREV_CONT"
    )
  done
fi

apptainer exec --cleanenv \
  "${APPTAINER_BIND_ARGS[@]}" \
  --pwd /work \
  "$SIF_IMAGE" \
  python3 /work/repo/scripts/make_pairjobs.py "${ARGS[@]}"

echo "Wrote $OUT"
