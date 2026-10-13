#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/scripts/lib.sh"

usage() {
  cat <<'USAGE'
Usage:
  merge_bcfs.sh \
    --first-template  '/path/to/chr{chr}.first.bcf' \
    --second-template '/path/to/chr{chr}.second.bcf' \
    --out-template    '/path/to/chr{chr}.merged.bcf' \
    [--samples-out /path/to/merged.samples.txt] \
    [--chroms 1-22] [--threads 0] [--force] [--dry-run]

Purpose:
  Merge corresponding chromosome BCFs using the lab workflow's established
  `bcftools merge --force-samples` semantics, with bcftools from the configured
  ancibd-pipeline container.

Important:
  - Input order matters. Duplicated sample names in the SECOND input are
    prefixed by bcftools because --force-samples is used.
  - Every merged chromosome is checked for an identical sample list/order.
  - A single canonical sample sidecar is written after all chromosomes pass
    (default: OUTDIR/merged.samples.txt).
  - Sample consistency checks use BCF headers only; they do not scan genotypes.
USAGE
}

FIRST_TEMPLATE=""
SECOND_TEMPLATE=""
OUT_TEMPLATE=""
SAMPLES_OUT=""
CHROMS="1-22"
THREADS=0
FORCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --first-template)  FIRST_TEMPLATE="$2"; shift 2 ;;
    --second-template) SECOND_TEMPLATE="$2"; shift 2 ;;
    --out-template)    OUT_TEMPLATE="$2"; shift 2 ;;
    --samples-out)     SAMPLES_OUT="$2"; shift 2 ;;
    --chroms)          CHROMS="$2"; shift 2 ;;
    --threads)         THREADS="$2"; shift 2 ;;
    --force)           FORCE=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$FIRST_TEMPLATE" ]]  || die "--first-template is required"
[[ -n "$SECOND_TEMPLATE" ]] || die "--second-template is required"
[[ -n "$OUT_TEMPLATE" ]]    || die "--out-template is required"
for t in "$FIRST_TEMPLATE" "$SECOND_TEMPLATE" "$OUT_TEMPLATE"; do
  [[ "$t" == *'{chr}'* || "$t" == *'{CHR}'* ]] || die "all BCF templates must contain {chr} or {CHR}: $t"
done
[[ "$THREADS" =~ ^[0-9]+$ ]] || die "--threads must be a non-negative integer"

load_config
require_cmd apptainer

expand_chroms() {
  local spec="$1" part a b i
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
      (( b >= a )) || die "invalid chromosome range: $part"
      for ((i=a; i<=b; i++)); do printf '%s\n' "$i"; done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$part"
    else
      die "invalid chromosome specification: $part"
    fi
  done
}

subst_chr() {
  local s="$1" chr="$2"
  s="${s//\{chr\}/$chr}"
  s="${s//\{CHR\}/$chr}"
  printf '%s\n' "$s"
}

declare -A BIND_MODE=()
add_bind_dir() {
  local dir="$1" mode="$2"
  dir="$(cd "$dir" && pwd)"
  if [[ "$mode" == "rw" || -z "${BIND_MODE[$dir]:-}" ]]; then BIND_MODE["$dir"]="$mode"; fi
}
container_bcftools() {
  local -a binds=()
  local dir
  for dir in "${!BIND_MODE[@]}"; do binds+=(--bind "$dir:$dir:${BIND_MODE[$dir]}"); done
  apptainer exec --cleanenv "${binds[@]}" "$SIF_IMAGE" bcftools "$@"
}

first_out="$(subst_chr "$OUT_TEMPLATE" "1")"
mkdir -p "$(dirname "$first_out")"
OUT_DIR="$(cd "$(dirname "$first_out")" && pwd)"
if [[ -z "$SAMPLES_OUT" ]]; then SAMPLES_OUT="$OUT_DIR/merged.samples.txt"; fi
mkdir -p "$(dirname "$SAMPLES_OUT")"
SAMPLES_OUT="$(abs_path "$SAMPLES_OUT")"
SUMMARY="$OUT_DIR/merge_summary.tsv"
if [[ "$FORCE" -ne 1 ]]; then
  [[ ! -e "$SAMPLES_OUT" ]] || die "sample sidecar exists; use --force: $SAMPLES_OUT"
  [[ ! -e "$SUMMARY" ]] || die "summary exists; use --force: $SUMMARY"
fi

declare -a CHR_ARR=() FIRST_ARR=() SECOND_ARR=() OUT_ARR=()
while IFS= read -r chr; do
  [[ -n "$chr" ]] || continue
  first="$(subst_chr "$FIRST_TEMPLATE" "$chr")"
  second="$(subst_chr "$SECOND_TEMPLATE" "$chr")"
  out="$(subst_chr "$OUT_TEMPLATE" "$chr")"
  [[ -r "$first" ]] || die "first input BCF not readable for chr${chr}: $first"
  [[ -r "$second" ]] || die "second input BCF not readable for chr${chr}: $second"
  first="$(abs_path "$first")"
  second="$(abs_path "$second")"
  out_dir="$(dirname "$out")"; mkdir -p "$out_dir"
  out="$(abs_path "$out")"
  out_dir="$(dirname "$out")"
  [[ -w "$out_dir" ]] || die "output directory is not writable: $out_dir"
  if [[ -e "$out" && "$FORCE" -ne 1 ]]; then die "output exists: $out (use --force)"; fi

  # Inputs are rw because this convenience utility creates a missing CSI index,
  # matching the previous lab script's behaviour.
  add_bind_dir "$(dirname "$first")" rw
  add_bind_dir "$(dirname "$second")" rw
  add_bind_dir "$out_dir" rw
  CHR_ARR+=("$chr"); FIRST_ARR+=("$first"); SECOND_ARR+=("$second"); OUT_ARR+=("$out")
done < <(expand_chroms "$CHROMS")
[[ "${#CHR_ARR[@]}" -gt 0 ]] || die "no chromosomes selected"
add_bind_dir "$(dirname "$SAMPLES_OUT")" rw

ensure_index() {
  local f="$1"
  if [[ -e "${f}.csi" || -e "${f}.tbi" ]]; then return 0; fi
  echo "Index missing for $f; creating CSI index..."
  container_bcftools index -f "$f"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'Would write summary: %s\nWould write sample sidecar: %s\n' "$SUMMARY" "$SAMPLES_OUT"
  for i in "${!CHR_ARR[@]}"; do
    printf 'bcftools merge --force-samples -Ob%s -o %q %q %q\n' \
      "$([[ "$THREADS" -gt 0 ]] && printf ' --threads %q' "$THREADS")" \
      "${OUT_ARR[$i]}" "${FIRST_ARR[$i]}" "${SECOND_ARR[$i]}"
    printf 'bcftools index -f %q\n' "${OUT_ARR[$i]}"
  done
  exit 0
fi

if [[ "$FORCE" -eq 1 ]]; then rm -f "$SUMMARY" "$SAMPLES_OUT"; fi
printf 'chromosome\tfirst_bcf\tsecond_bcf\toutput_bcf\tn_first_samples\tn_second_samples\tn_output_samples\tn_output_sites\tsample_order_same_as_chr1\n' > "$SUMMARY"
TMP_REFERENCE="$(mktemp)"
cleanup_tmp() { rm -f "$TMP_REFERENCE"; }
trap cleanup_tmp EXIT

CURRENT_OUT=""
cleanup_partial() {
  if [[ -n "$CURRENT_OUT" ]]; then rm -f -- "$CURRENT_OUT" "$CURRENT_OUT.csi" "$CURRENT_OUT.tbi"; fi
}
trap cleanup_partial INT TERM ERR

for i in "${!CHR_ARR[@]}"; do
  chr="${CHR_ARR[$i]}"; first="${FIRST_ARR[$i]}"; second="${SECOND_ARR[$i]}"; out="${OUT_ARR[$i]}"
  ensure_index "$first"; ensure_index "$second"
  if [[ -e "$out" && "$FORCE" -eq 1 ]]; then rm -f -- "$out" "$out.csi" "$out.tbi"; fi
  n_first="$(container_bcftools query -l "$first" | wc -l | tr -d ' ')"
  n_second="$(container_bcftools query -l "$second" | wc -l | tr -d ' ')"

  CURRENT_OUT="$out"
  merge_args=(merge --force-samples -Ob)
  if [[ "$THREADS" -gt 0 ]]; then merge_args+=(--threads "$THREADS"); fi
  merge_args+=(-o "$out" "$first" "$second")
  container_bcftools "${merge_args[@]}"
  container_bcftools index -f "$out"

  current_samples="$(mktemp)"
  container_bcftools query -l "$out" > "$current_samples"
  n_output="$(wc -l < "$current_samples" | tr -d ' ')"
  n_sites="$(container_bcftools index -n "$out")"
  same="yes"
  if [[ -s "$TMP_REFERENCE" ]]; then
    if ! cmp -s "$TMP_REFERENCE" "$current_samples"; then same="no"; fi
  else
    cp "$current_samples" "$TMP_REFERENCE"
  fi
  rm -f "$current_samples"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$chr" "$first" "$second" "$out" "$n_first" "$n_second" "$n_output" "$n_sites" "$same" >> "$SUMMARY"
  [[ "$same" == "yes" ]] || die "merged sample list differs on chr${chr}; see $SUMMARY"
  CURRENT_OUT=""
done

cp "$TMP_REFERENCE" "$SAMPLES_OUT"
trap - INT TERM ERR
echo "Done."
echo "Summary: $SUMMARY"
echo "Samples: $SAMPLES_OUT"
