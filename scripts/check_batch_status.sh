#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

usage() {
  cat <<'EOF'
Usage:
  scripts/check_batch_status.sh [--missing-only] [--write-missing PATH]

Reports progress of the batchpair workflow for the current RUN_ID.

Compares:
  - expected pairs:   $RUNS_ROOT/$RUN_ID/meta/batchpairs.tsv
  - completed pairs:  $RUNS_ROOT/$RUN_ID/out/bNNN_bMMM/DONE

By default, prints a short summary and lists missing pairs.

Options:
  --missing-only
      Only print missing pairs as TSV (B1<TAB>B2).
  --write-missing PATH
      Write missing pairs as TSV to PATH.
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

RUN_ID="${RUN_ID:?set RUN_ID env var (use scripts/new_run.sh)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

PAIRS_FILE="$RUN_DIR/meta/batchpairs.tsv"
[[ -f "$PAIRS_FILE" ]] || die "Missing $PAIRS_FILE (run scripts/make_batchpairs.sh first)"

OUT_BASE="$RUN_DIR/out"

expected=0
done_ok=0
done_bad=0
missing=0

missing_lines=()
bad_lines=()

pair_to_tag() {
  local b1="$1" b2="$2"
  printf 'b%03d_b%03d' "$b1" "$b2"
}

is_complete_dir() {
  # A batchpair output dir is considered complete if DONE exists and the
  # expected summary outputs exist.
  local d="$1"
  [[ -f "$d/DONE" ]] || return 1
  [[ -s "$d/ch_all.tsv" ]] || return 1
  [[ -s "$d/ibd_ind.tsv" ]] || return 1
  return 0
}

while IFS=$'\t' read -r b1 b2 rest; do
  # Skip empty lines.
  [[ -n "${b1:-}" ]] || continue

  # Basic validation: batch indices are integers.
  [[ "$b1" =~ ^[0-9]+$ ]] || die "Invalid B1 in $PAIRS_FILE: '$b1'"
  [[ "$b2" =~ ^[0-9]+$ ]] || die "Invalid B2 in $PAIRS_FILE: '$b2'"

  expected=$((expected + 1))
  tag="$(pair_to_tag "$b1" "$b2")"
  d="$OUT_BASE/$tag"

  if is_complete_dir "$d"; then
    done_ok=$((done_ok + 1))
    continue
  fi

  if [[ -f "$d/DONE" ]]; then
    # DONE exists but outputs are missing/empty.
    done_bad=$((done_bad + 1))
    bad_lines+=("${b1}\t${b2}\t${tag}")
  else
    missing=$((missing + 1))
    missing_lines+=("${b1}\t${b2}")
  fi
done < "$PAIRS_FILE"

if [[ $MISSING_ONLY -eq 1 ]]; then
  if (( ${#missing_lines[@]} )); then
    printf '%s\n' "${missing_lines[@]}"
  fi
  exit 0
fi

percent=0
if [[ $expected -gt 0 ]]; then
  percent=$(( (done_ok * 100) / expected ))
fi

echo "RUN_ID:        $RUN_ID"
echo "Pairs file:    $PAIRS_FILE"
echo "Out dir:       $OUT_BASE"
echo
echo "Expected:      $expected"
echo "Complete:      $done_ok (${percent}%)"
if [[ $done_bad -gt 0 ]]; then
  echo "DONE but bad:  $done_bad" >&2
fi
echo "Missing:       $missing"

DEFAULT_MISSING_OUT="$RUN_DIR/meta/batchpairs_missing.tsv"

if [[ $missing -gt 0 ]]; then
  echo
  echo "Missing pairs (B1<TAB>B2):"
  printf '%s\n' "${missing_lines[@]}"

  # Write missing list by default to help reruns.
  : > "$DEFAULT_MISSING_OUT"
  printf '%s\n' "${missing_lines[@]}" >> "$DEFAULT_MISSING_OUT"
  echo
  echo "Wrote missing list: $DEFAULT_MISSING_OUT" >&2
fi

if [[ -n "$WRITE_MISSING" ]]; then
  mkdir -p "$(dirname "$WRITE_MISSING")"
  : > "$WRITE_MISSING"
  if (( ${#missing_lines[@]} )); then
    printf '%s\n' "${missing_lines[@]}" >> "$WRITE_MISSING"
  fi
  echo "Wrote missing list (requested): $WRITE_MISSING" >&2
fi

if [[ $done_bad -gt 0 ]]; then
  echo
  echo "WARNING: The following output folders contain DONE but look incomplete (missing expected TSVs):" >&2
  echo "(B1<TAB>B2<TAB>tag)" >&2
  printf '%s\n' "${bad_lines[@]}" >&2
  echo >&2
  echo "If you need to re-run these, remove the DONE sentinel in the folder(s)." >&2
fi

echo
echo "Note: DONE reflects completion of whatever CH_RANGE was used when the batchpair job was run." >&2
echo "If you change CH_RANGE and want to recompute, delete runs/<RUN_ID>/out/b*_b*/DONE before re-running." >&2
