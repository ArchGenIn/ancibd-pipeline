#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/scripts/lib.sh"

usage() {
  cat <<'USAGE'
Usage:
  subset_bcfs.sh \
    --in-template  '/path/to/chr{chr}.in.bcf' \
    --out-template '/path/to/chr{chr}.subset.bcf' \
    --samples      /path/to/iids.txt \
    [--samples-out /path/to/subset.samples.txt] \
    [--chroms 1-22] [--threads 0] [--force] [--dry-run]

Purpose:
  Subset every selected chromosome BCF to the same requested IID list and
  verify that every output contains exactly the same samples in the requested
  order. bcftools is run from the configured ancibd-pipeline container.

Outputs:
  - one BCF plus index per chromosome
  - subset_summary.tsv in the output directory
  - one canonical sample sidecar for the entire output set
    (default: OUTDIR/subset.samples.txt)

The sidecar is written only after all selected chromosomes pass validation.
USAGE
}

IN_TEMPLATE=""
OUT_TEMPLATE=""
SAMPLES=""
SAMPLES_OUT=""
CHROMS="1-22"
THREADS=0
FORCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-template)  IN_TEMPLATE="$2"; shift 2 ;;
    --out-template) OUT_TEMPLATE="$2"; shift 2 ;;
    --samples)      SAMPLES="$2"; shift 2 ;;
    --samples-out)  SAMPLES_OUT="$2"; shift 2 ;;
    --chroms)       CHROMS="$2"; shift 2 ;;
    --threads)      THREADS="$2"; shift 2 ;;
    --force)        FORCE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$IN_TEMPLATE" ]]  || die "--in-template is required"
[[ -n "$OUT_TEMPLATE" ]] || die "--out-template is required"
[[ -n "$SAMPLES" ]]      || die "--samples is required"
[[ -r "$SAMPLES" ]]      || die "sample list is not readable: $SAMPLES"
[[ "$IN_TEMPLATE" == *'{chr}'* || "$IN_TEMPLATE" == *'{CHR}'* ]] \
  || die "--in-template must contain {chr} or {CHR}"
[[ "$OUT_TEMPLATE" == *'{chr}'* || "$OUT_TEMPLATE" == *'{CHR}'* ]] \
  || die "--out-template must contain {chr} or {CHR}"
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

# Canonicalise the requested list: ignore blank lines, preserve order, reject
# duplicates. This is the exact list passed to bcftools and later validated.
TMP_REQUESTED="$(mktemp)"
TMP_REFERENCE="$(mktemp)"
cleanup_tmp() { rm -f "$TMP_REQUESTED" "$TMP_REFERENCE"; }
trap cleanup_tmp EXIT
awk 'NF { if (seen[$0]++) { print "ERROR: duplicate IID in sample list: " $0 > "/dev/stderr"; bad=1 } else print } END { exit bad ? 2 : 0 }' \
  "$SAMPLES" > "$TMP_REQUESTED" || die "invalid sample list: $SAMPLES"
[[ -s "$TMP_REQUESTED" ]] || die "sample list contains no IIDs: $SAMPLES"

first_out="$(subst_chr "$OUT_TEMPLATE" "1")"
mkdir -p "$(dirname "$first_out")"
OUT_DIR="$(cd "$(dirname "$first_out")" && pwd)"
if [[ -z "$SAMPLES_OUT" ]]; then SAMPLES_OUT="$OUT_DIR/subset.samples.txt"; fi
mkdir -p "$(dirname "$SAMPLES_OUT")"
SAMPLES_OUT="$(abs_path "$SAMPLES_OUT")"
SUMMARY="$OUT_DIR/subset_summary.tsv"

if [[ "$FORCE" -ne 1 ]]; then
  [[ ! -e "$SAMPLES_OUT" ]] || die "sample sidecar exists; use --force: $SAMPLES_OUT"
  [[ ! -e "$SUMMARY" ]] || die "summary exists; use --force: $SUMMARY"
fi

declare -a CHR_ARR=() IN_ARR=() OUT_ARR=()
while IFS= read -r chr; do
  [[ -n "$chr" ]] || continue
  in="$(subst_chr "$IN_TEMPLATE" "$chr")"
  out="$(subst_chr "$OUT_TEMPLATE" "$chr")"
  [[ -r "$in" ]] || die "input BCF not readable for chr${chr}: $in"
  in="$(abs_path "$in")"
  out_dir="$(dirname "$out")"; mkdir -p "$out_dir"
  out="$(abs_path "$out")"
  out_dir="$(dirname "$out")"
  [[ -w "$out_dir" ]] || die "output directory is not writable: $out_dir"
  if [[ -e "$out" && "$FORCE" -ne 1 ]]; then die "output exists: $out (use --force)"; fi
  add_bind_dir "$(dirname "$in")" ro
  add_bind_dir "$out_dir" rw
  CHR_ARR+=("$chr"); IN_ARR+=("$in"); OUT_ARR+=("$out")
done < <(expand_chroms "$CHROMS")
[[ "${#CHR_ARR[@]}" -gt 0 ]] || die "no chromosomes selected"

# The temporary requested file is outside the normal inputs, so expose its
# containing directory read-only at the same absolute path.
add_bind_dir "$(dirname "$TMP_REQUESTED")" ro
add_bind_dir "$(dirname "$SAMPLES_OUT")" rw

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'Would write summary: %s\nWould write sample sidecar: %s\n' "$SUMMARY" "$SAMPLES_OUT"
  for i in "${!CHR_ARR[@]}"; do
    printf 'bcftools view -S %q -Ob --threads %q -o %q %q\n' \
      "$TMP_REQUESTED" "$THREADS" "${OUT_ARR[$i]}" "${IN_ARR[$i]}"
    printf 'bcftools index -f %q\n' "${OUT_ARR[$i]}"
  done
  exit 0
fi

if [[ "$FORCE" -eq 1 ]]; then rm -f "$SUMMARY" "$SAMPLES_OUT"; fi
printf 'chromosome\tinput_bcf\toutput_bcf\tn_input_samples\tn_requested_samples\tn_output_samples\tsample_order_exact\tstatus\n' > "$SUMMARY"
n_requested="$(wc -l < "$TMP_REQUESTED" | tr -d ' ')"

CURRENT_OUT=""
cleanup_partial() {
  if [[ -n "$CURRENT_OUT" ]]; then rm -f -- "$CURRENT_OUT" "$CURRENT_OUT.csi" "$CURRENT_OUT.tbi"; fi
}
trap cleanup_partial INT TERM ERR

for i in "${!CHR_ARR[@]}"; do
  chr="${CHR_ARR[$i]}"; in="${IN_ARR[$i]}"; out="${OUT_ARR[$i]}"
  if [[ -e "$out" && "$FORCE" -eq 1 ]]; then rm -f -- "$out" "$out.csi" "$out.tbi"; fi
  n_in="$(container_bcftools query -l "$in" | wc -l | tr -d ' ')"
  CURRENT_OUT="$out"
  container_bcftools view -S "$TMP_REQUESTED" -Ob --threads "$THREADS" -o "$out" "$in"
  container_bcftools index -f "$out"
  current_samples="$(mktemp)"
  container_bcftools query -l "$out" > "$current_samples"
  n_out="$(wc -l < "$current_samples" | tr -d ' ')"

  status="ok"; exact="yes"
  if ! cmp -s "$TMP_REQUESTED" "$current_samples"; then
    status="sample_order_or_set_mismatch"; exact="no"
  elif [[ -s "$TMP_REFERENCE" ]] && ! cmp -s "$TMP_REFERENCE" "$current_samples"; then
    status="cross_chromosome_sample_mismatch"; exact="no"
  fi
  if [[ ! -s "$TMP_REFERENCE" ]]; then cp "$current_samples" "$TMP_REFERENCE"; fi
  rm -f "$current_samples"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$chr" "$in" "$out" "$n_in" "$n_requested" "$n_out" "$exact" "$status" >> "$SUMMARY"
  [[ "$status" == "ok" ]] || die "sample validation failed for chr${chr}; see $SUMMARY"
  CURRENT_OUT=""
done

cp "$TMP_REFERENCE" "$SAMPLES_OUT"
trap - INT TERM ERR
echo "Done."
echo "Summary: $SUMMARY"
echo "Samples: $SAMPLES_OUT"
