#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

usage() {
  cat <<'EOF'
Usage:
  scripts/check_batch_status.sh [--missing-only] [--write-missing PATH]

Reports progress of the prod pairjob workflow for the current RUN_ID.

Compares:
  - expected jobs:     runs/<RUN_ID>/meta/pairjobs.tsv
  - completed jobs:    runs/<RUN_ID>/out/<JOB_ID>/DONE

By default, prints a short summary and lists missing job rows.

Options:
  --missing-only
      Only print missing job rows as TSV.
  --write-missing PATH
      Write missing job rows as TSV to PATH.
  -h, --help
      Show this help.
EOF
}

MISSING_ONLY=0
WRITE_MISSING=""

while (( $# )); do
  case "$1" in
    --missing-only)
      MISSING_ONLY=1
      shift
      ;;
    --write-missing)
      shift
      [[ -n "${1:-}" ]] || die "--write-missing requires a PATH"
      WRITE_MISSING="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

JOBS_FILE="$RUN_DIR/meta/pairjobs.tsv"
[[ -f "$JOBS_FILE" ]] || die "Missing $JOBS_FILE (run scripts/make_pairjobs.sh first)"

OUT_BASE="$RUN_DIR/out"

expected=0
done_ok=0
done_bad=0
missing=0

missing_lines=()
bad_lines=()
header=""

is_complete_dir() {
  local d="$1"
  [[ -f "$d/DONE" ]] || return 1
  [[ -s "$d/ch_all.tsv" ]] || return 1
  [[ -s "$d/ibd_ind.tsv" ]] || return 1
  return 0
}

while IFS=$'\t' read -r job_id b1 b2 mode plan n_left n_right n_preload n_pairs rest; do
  [[ -n "${job_id:-}" ]] || continue
  if [[ "$job_id" == "job_id" ]]; then
    header="$job_id\t$b1\t$b2\t$mode\t$plan\t$n_left\t$n_right\t$n_preload\t$n_pairs"
    continue
  fi

  expected=$((expected + 1))
  d="$OUT_BASE/$job_id"
  row="$job_id\t$b1\t$b2\t$mode\t$plan\t$n_left\t$n_right\t$n_preload\t$n_pairs"

  if is_complete_dir "$d"; then
    done_ok=$((done_ok + 1))
    continue
  fi

  if [[ -f "$d/DONE" ]]; then
    done_bad=$((done_bad + 1))
    bad_lines+=("$row")
  else
    missing=$((missing + 1))
    missing_lines+=("$row")
  fi
done < "$JOBS_FILE"

if [[ $MISSING_ONLY -eq 1 ]]; then
  if [[ -n "$header" && ${#missing_lines[@]} -gt 0 ]]; then
    printf '%s\n' "$header"
    printf '%s\n' "${missing_lines[@]}"
  fi
  exit 0
fi

percent=0
if [[ $expected -gt 0 ]]; then
  percent=$(( (done_ok * 100) / expected ))
fi

echo "RUN_ID:        $RUN_ID"
echo "Jobs file:     $JOBS_FILE"
echo "Out dir:       $OUT_BASE"
echo
echo "Expected:      $expected"
echo "Complete:      $done_ok (${percent}%)"
if [[ $done_bad -gt 0 ]]; then
  echo "DONE but bad:  $done_bad" >&2
fi
echo "Missing:       $missing"

DEFAULT_MISSING_OUT="$RUN_DIR/meta/pairjobs_missing.tsv"

if [[ $missing -gt 0 ]]; then
  echo
  echo "Missing jobs:"
  [[ -n "$header" ]] && printf '%s\n' "$header"
  printf '%s\n' "${missing_lines[@]}"

  : > "$DEFAULT_MISSING_OUT"
  if [[ -n "$header" ]]; then
    printf '%s\n' "$header" >> "$DEFAULT_MISSING_OUT"
  fi
  printf '%s\n' "${missing_lines[@]}" >> "$DEFAULT_MISSING_OUT"
  echo
  echo "Wrote missing list: $DEFAULT_MISSING_OUT" >&2
fi

if [[ -n "$WRITE_MISSING" ]]; then
  mkdir -p "$(dirname "$WRITE_MISSING")"
  : > "$WRITE_MISSING"
  if [[ -n "$header" ]]; then
    printf '%s\n' "$header" >> "$WRITE_MISSING"
  fi
  if (( ${#missing_lines[@]} )); then
    printf '%s\n' "${missing_lines[@]}" >> "$WRITE_MISSING"
  fi
  echo "Wrote missing list (requested): $WRITE_MISSING" >&2
fi

if [[ $done_bad -gt 0 ]]; then
  echo
  echo "WARNING: The following output folders contain DONE but look incomplete (missing expected TSVs):" >&2
  [[ -n "$header" ]] && printf '%s\n' "$header" >&2
  printf '%s\n' "${bad_lines[@]}" >&2
  echo >&2
  echo "If you need to re-run these, remove the DONE sentinel in the folder(s)." >&2
fi

echo
echo "Note: DONE reflects completion of whatever CH_RANGE was used when the job was run." >&2
echo "If you change CH_RANGE and want to recompute, delete runs/<RUN_ID>/out/*/DONE before re-running." >&2
