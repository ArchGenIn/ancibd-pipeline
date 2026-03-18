#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

usage() {
  cat <<'USAGE'
Usage:
  merge_batch_outputs.sh [--with-ch-all|--skip-ch-all]

Options:
  --with-ch-all  also merge per-job ch_all.tsv files
  --skip-ch-all  skip the merged ch_all.tsv artifact

If neither flag is given, MERGE_CH_ALL from config/local.env is used.
USAGE
}

MERGE_CH_ALL_RUN="$MERGE_CH_ALL"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-ch-all)
      MERGE_CH_ALL_RUN=1; shift ;;
    --skip-ch-all)
      MERGE_CH_ALL_RUN=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown arg for merge_batch_outputs.sh: $1" ;;
  esac
done

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run <tag>)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"
[[ -e "$RUN_DIR/DONE" ]] && die "Run is DONE: $RUN_DIR"

OUT_BASE="$RUN_DIR/out"
JOBS_FILE="$RUN_DIR/meta/pairjobs.tsv"
[[ -s "$JOBS_FILE" ]] || die "Missing or empty jobs file: $JOBS_FILE"

job_ids=()
missing=0
bad=0
while IFS=$'\t' read -r job_id _rest; do
  [[ -n "${job_id:-}" ]] || continue
  [[ "$job_id" == "job_id" ]] && continue
  job_ids+=("$job_id")
  d="$OUT_BASE/$job_id"
  if [[ ! -f "$d/DONE" ]]; then
    missing=$((missing + 1))
    continue
  fi
  if [[ ! -s "$d/ibd_ind.tsv" ]]; then
    bad=$((bad + 1))
    continue
  fi
  if [[ "$MERGE_CH_ALL_RUN" == "1" && ! -s "$d/ch_all.tsv" ]]; then
    bad=$((bad + 1))
  fi
done < "$JOBS_FILE"

if [[ ${#job_ids[@]} -eq 0 ]]; then
  die "No jobs listed in: $JOBS_FILE"
fi

if [[ $missing -ne 0 || $bad -ne 0 ]]; then
  echo "Refusing to merge: expected jobs are incomplete." >&2
  echo "  missing DONE: $missing" >&2
  echo "  DONE but missing required TSVs: $bad" >&2
  echo "Use: ./ancibd-pipeline check-batch (and re-run missing jobs)" >&2
  exit 1
fi

job_dirs=()
for job_id in "${job_ids[@]}"; do
  job_dirs+=("$OUT_BASE/$job_id")
done

mkdir -p "$OUT_BASE/merged"

to_cont_path() {
  local host_path="$1"
  local rel="${host_path#"$RUN_DIR"/}"
  echo "/work/run/$rel"
}

merge_one() {
  local name="$1"
  local out_host="$2"

  local inputs_host=()
  local d f
  for d in "${job_dirs[@]}"; do
    f="$d/$name"
    [[ -f "$f" ]] || continue
    inputs_host+=("$f")
  done

  [[ ${#inputs_host[@]} -gt 0 ]] || die "No input files found for $name under: $OUT_BASE"

  local out_cont
  out_cont="$(to_cont_path "$out_host")"

  local inputs_cont=()
  local h
  for h in "${inputs_host[@]}"; do
    inputs_cont+=("$(to_cont_path "$h")")
  done

  apptainer exec --cleanenv \
    --bind "$ROOT:/work/repo:ro" \
    --bind "$RUN_DIR:/work/run" \
    --pwd /work \
    "$SIF_IMAGE" \
    python3 /work/repo/scripts/merge_tsvs.py --out "$out_cont" "${inputs_cont[@]}"

  [[ -s "$out_host" ]] || die "Merged file is empty: $out_host"
}

merge_one "ibd_ind.tsv" "$OUT_BASE/merged/ibd_ind.tsv"

if [[ "$MERGE_CH_ALL_RUN" == "1" ]]; then
  merge_one "ch_all.tsv" "$OUT_BASE/merged/ch_all.tsv"
else
  rm -f "$OUT_BASE/merged/ch_all.tsv"
fi

manifest="$OUT_BASE/merged/manifest.txt"
{
  echo "RUN_ID=$RUN_ID"
  echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "JOB_DIRS=${#job_dirs[@]}"
  echo "MERGE_CH_ALL=$MERGE_CH_ALL_RUN"
  echo
  for f in "$OUT_BASE/merged/ibd_ind.tsv" "$OUT_BASE/merged/ch_all.tsv"; do
    [[ -f "$f" ]] || continue
    echo "[$(basename "$f")]"
    head -n 1 "$f"
    wc -l "$f"
    sha256sum "$f"
    echo
  done
} > "$manifest"

echo "Merged outputs in: $OUT_BASE/merged"

date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN_DIR/DONE"
