#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/scripts/lib.sh"

usage() {
  cat <<'USAGE'
Usage:
  downsample_bcfs.sh \
    --in-template '/path/to/chr{chr}.input.bcf' \
    --out-template '/path/to/chr{chr}.output.bcf' \
    --targets-dir '/path/to/filters' \
    [--target-template 'snps_bcftools_ch{chr}.csv'] \
    [--chroms 1-22] \
    [--threads 1] \
    [--dry-run] \
    [--force]

Purpose:
  Downsample chromosome BCFs to per-chromosome bcftools target files using
  the bcftools version bundled in the configured ancibd-pipeline container.

Required placeholders:
  --in-template and --out-template must contain {chr} or {CHR}.
  --target-template must contain {chr} or {CHR}; default is
  snps_bcftools_ch{chr}.csv.

Notes:
  - Target files are passed to `bcftools view -T`; they are normally two-column
    CHROM/POS files with 1-based positions.
  - This utility changes sites only. It does not add additional SNP/FILTER
    constraints such as -m2 -M2 -v snps.
USAGE
}

IN_TEMPLATE=""
OUT_TEMPLATE=""
TARGETS_DIR=""
TARGET_TEMPLATE='snps_bcftools_ch{chr}.csv'
CHROMS='1-22'
THREADS=1
DRY_RUN=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-template)      IN_TEMPLATE="$2"; shift 2 ;;
    --out-template)     OUT_TEMPLATE="$2"; shift 2 ;;
    --targets-dir)      TARGETS_DIR="$2"; shift 2 ;;
    --target-template)  TARGET_TEMPLATE="$2"; shift 2 ;;
    --chroms)           CHROMS="$2"; shift 2 ;;
    --threads)          THREADS="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --force)            FORCE=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$IN_TEMPLATE" ]]  || die "--in-template is required"
[[ -n "$OUT_TEMPLATE" ]] || die "--out-template is required"
[[ -n "$TARGETS_DIR" ]]  || die "--targets-dir is required"
[[ "$IN_TEMPLATE" == *'{chr}'* || "$IN_TEMPLATE" == *'{CHR}'* ]] \
  || die "--in-template must contain {chr} or {CHR}"
[[ "$OUT_TEMPLATE" == *'{chr}'* || "$OUT_TEMPLATE" == *'{CHR}'* ]] \
  || die "--out-template must contain {chr} or {CHR}"
[[ "$TARGET_TEMPLATE" == *'{chr}'* || "$TARGET_TEMPLATE" == *'{CHR}'* ]] \
  || die "--target-template must contain {chr} or {CHR}"
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

# Bind the concrete directories at their host absolute paths so the command
# line is identical inside/outside the container. Output directories are rw;
# input/target directories are ro unless they are also output directories.
declare -A BIND_MODE=()
add_bind_dir() {
  local dir="$1" mode="$2"
  dir="$(cd "$dir" && pwd)"
  if [[ "$mode" == "rw" || -z "${BIND_MODE[$dir]:-}" ]]; then
    BIND_MODE["$dir"]="$mode"
  fi
}

container_bcftools() {
  local -a binds=()
  local dir
  for dir in "${!BIND_MODE[@]}"; do
    binds+=(--bind "$dir:$dir:${BIND_MODE[$dir]}")
  done
  apptainer exec --cleanenv "${binds[@]}" "$SIF_IMAGE" bcftools "$@"
}

declare -a CHR_ARR=() IN_ARR=() OUT_ARR=() TARGET_ARR=()
while IFS= read -r chr; do
  [[ -n "$chr" ]] || continue
  in="$(subst_chr "$IN_TEMPLATE" "$chr")"
  out="$(subst_chr "$OUT_TEMPLATE" "$chr")"
  target="$TARGETS_DIR/$(subst_chr "$TARGET_TEMPLATE" "$chr")"

  [[ -r "$in" ]]     || die "cannot read input BCF for chr${chr}: $in"
  [[ -r "$target" ]] || die "cannot read target file for chr${chr}: $target"
  in="$(abs_path "$in")"
  target="$(abs_path "$target")"

  out_dir="$(dirname "$out")"
  mkdir -p "$out_dir"
  out="$(abs_path "$out")"
  out_dir="$(dirname "$out")"
  [[ -w "$out_dir" ]] || die "output directory is not writable: $out_dir"
  if [[ -e "$out" && "$FORCE" -ne 1 ]]; then
    die "output exists for chr${chr}: $out (use --force or choose a fresh output template)"
  fi

  add_bind_dir "$(dirname "$in")" ro
  add_bind_dir "$(dirname "$target")" ro
  add_bind_dir "$out_dir" rw

  CHR_ARR+=("$chr")
  IN_ARR+=("$in")
  OUT_ARR+=("$out")
  TARGET_ARR+=("$target")
done < <(expand_chroms "$CHROMS")

[[ "${#CHR_ARR[@]}" -gt 0 ]] || die "no chromosomes selected"

printf 'chrom\tinput_bcf\ttargets\toutput_bcf\n'
for i in "${!CHR_ARR[@]}"; do
  printf '%s\t%s\t%s\t%s\n' \
    "${CHR_ARR[$i]}" "${IN_ARR[$i]}" "${TARGET_ARR[$i]}" "${OUT_ARR[$i]}"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "Dry run only. Commands that would be run inside $SIF_IMAGE:"
  for i in "${!CHR_ARR[@]}"; do
    printf 'bcftools view -T %q -Ob --threads %q -o %q %q\n' \
      "${TARGET_ARR[$i]}" "$THREADS" "${OUT_ARR[$i]}" "${IN_ARR[$i]}"
    printf 'bcftools index -f %q\n' "${OUT_ARR[$i]}"
  done
  exit 0
fi

CURRENT_OUT=""
cleanup_partial() {
  if [[ -n "$CURRENT_OUT" ]]; then
    rm -f -- "$CURRENT_OUT" "$CURRENT_OUT.csi" "$CURRENT_OUT.tbi"
  fi
}
trap cleanup_partial INT TERM ERR

for i in "${!CHR_ARR[@]}"; do
  chr="${CHR_ARR[$i]}"; in="${IN_ARR[$i]}"; out="${OUT_ARR[$i]}"; target="${TARGET_ARR[$i]}"
  echo "=== chr${chr} ==="
  if [[ -e "$out" && "$FORCE" -eq 1 ]]; then
    rm -f -- "$out" "$out.csi" "$out.tbi"
  fi
  CURRENT_OUT="$out"
  container_bcftools view -T "$target" -Ob --threads "$THREADS" -o "$out" "$in"
  container_bcftools index -f "$out"
  n_sites="$(container_bcftools index -n "$out")"
  n_samples="$(container_bcftools query -l "$out" | wc -l | tr -d ' ')"
  echo "OK: sites=$n_sites samples=$n_samples"
  CURRENT_OUT=""
done

trap - INT TERM ERR
echo "Done."
