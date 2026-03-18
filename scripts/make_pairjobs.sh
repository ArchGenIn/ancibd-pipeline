#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd python3

usage() {
  cat <<'USAGE'
Usage:
  make_pairjobs.sh --mode all
  make_pairjobs.sh --mode incremental --delta-iids PATH --delta-kind new|analyzed
USAGE
}

MODE=""
DELTA_IIDS=""
DELTA_KIND=""

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
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

[[ -n "$MODE" ]] || die "--mode is required"
[[ "$MODE" == "all" || "$MODE" == "incremental" ]] || die "--mode must be all or incremental"
if [[ "$MODE" == "incremental" ]]; then
  [[ -f "$DELTA_IIDS" ]] || die "Missing --delta-iids file: $DELTA_IIDS"
  [[ "$DELTA_KIND" == "new" || "$DELTA_KIND" == "analyzed" ]] || die "--delta-kind must be new or analyzed"
fi

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

if [[ ! -s "$RUN_DIR/meta/iids.txt" ]]; then
  "$ROOT/scripts/make_iid_list.sh" >/dev/null
fi

PLANS_DIR="$RUN_DIR/work/plans"
OUT="$RUN_DIR/meta/pairjobs.tsv"
mkdir -p "$RUN_DIR/meta" "$PLANS_DIR"
find "$PLANS_DIR" -maxdepth 1 \( -name '*.iids' -o -name '*.pairs' \) -delete
rm -f "$OUT" "$RUN_DIR/meta/target_iids.txt" "$RUN_DIR/meta/incremental.env" "$RUN_DIR/meta/incremental_source_iids.txt"

ARGS=(
  --iids "$RUN_DIR/meta/iids.txt"
  --batch-size "$BATCH_SIZE"
  --mode "$MODE"
  --plans-dir "$PLANS_DIR"
  --out-jobs "$OUT"
)

if [[ "$MODE" == "incremental" ]]; then
  cp "$DELTA_IIDS" "$RUN_DIR/meta/incremental_source_iids.txt"
  printf 'DELTA_KIND=%s\n' "$DELTA_KIND" > "$RUN_DIR/meta/incremental.env"
  ARGS+=(
    --delta-iids "$DELTA_IIDS"
    --delta-kind "$DELTA_KIND"
    --out-target-iids "$RUN_DIR/meta/target_iids.txt"
  )
fi

python3 "$ROOT/scripts/make_pairjobs.py" "${ARGS[@]}"

echo "Wrote $OUT"
