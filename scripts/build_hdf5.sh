#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

CH="${1:?usage: build_hdf5.sh <CH> [--force] [--with-ref-af|--with-raf] [--ref-af-path|--raf-path TEMPLATE_OR_PATH]}"
shift || true

FORCE=0
WITH_REF_AF=0
REF_AF_PATH_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1; shift
      ;;
    --with-ref-af|--with-raf)
      WITH_REF_AF=1; shift
      ;;
    --ref-af-path|--raf-path)
      [[ -n "${2:-}" ]] || die "$1 requires a value"
      REF_AF_PATH_ARG="$2"; WITH_REF_AF=1; shift 2
      ;;
    *)
      die "Unknown arg for build_hdf5.sh: $1"
      ;;
  esac
done

mkdir -p "$HDF5_ROOT" "$HDF5_ROOT/logs"

VCF_PATH="$(tpl "$VCF_TEMPLATE" "$CH")"
MARKER_PATH="$(tpl "$MARKER_TEMPLATE" "$CH")"
H5_PATH="$(h5_path_for_ch "$CH")"
VCF_1240K_PATH="$(vcf_1240k_path_for_ch "$CH")"

[[ -f "$VCF_PATH" ]] || die "Missing VCF: $VCF_PATH"
[[ -f "$MARKER_PATH" ]] || die "Missing marker list: $MARKER_PATH"
[[ -f "$MAP_PATH" ]] || die "Missing map: $MAP_PATH"

if [[ -f "$H5_PATH" && $FORCE -eq 0 ]]; then
  echo "[build_hdf5] Exists, skipping: $H5_PATH"
  exit 0
fi

REF_AF_ARGS=()
if [[ $WITH_REF_AF -eq 1 ]]; then
  REF_AF_TEMPLATE_EFF="$REF_AF_PATH_ARG"
  if [[ -z "$REF_AF_TEMPLATE_EFF" ]]; then
    REF_AF_TEMPLATE_EFF="${REF_AF_TEMPLATE:-${RAF_TEMPLATE:-}}"
  fi
  [[ -n "$REF_AF_TEMPLATE_EFF" ]] || die "--with-ref-af requires REF_AF_TEMPLATE (or legacy RAF_TEMPLATE) in config/local.env, or pass --ref-af-path"

  REF_AF_PATH="$(tpl "$REF_AF_TEMPLATE_EFF" "$CH")"
  [[ -f "$REF_AF_PATH" ]] || die "Missing reference-AF TSV for ch${CH}: $REF_AF_PATH"
  REF_AF_REL="$(rel_under_data "$REF_AF_PATH")"
  REF_AF_ARGS=( --ref-af "/work/data/$REF_AF_REL" )
fi

TMP_H5="$H5_PATH.tmp"

mkdir -p "$(dirname "$H5_PATH")"
mkdir -p "$(dirname "$VCF_1240K_PATH")"

echo "[build_hdf5] Building HDF5 for ch$CH"
echo "[build_hdf5] Input  : $VCF_PATH"
echo "[build_hdf5] Output : $H5_PATH"
if [[ $WITH_REF_AF -eq 1 ]]; then
  echo "[build_hdf5] Ref AF : $REF_AF_PATH"
fi

DATA_ROOT_NORM="$(data_root_norm)"
HDF5_ROOT_NORM="$(hdf5_root_norm)"

VCF_REL="$(rel_under_data "$VCF_PATH")"
MARKER_REL="$(rel_under_data "$MARKER_PATH")"
MAP_REL="$(rel_under_data "$MAP_PATH")"

H5_REL="$(rel_under_hdf5 "$H5_PATH")"
VCF_1240K_REL="$(rel_under_hdf5 "$VCF_1240K_PATH")"
TMP_H5_REL="$(rel_under_hdf5 "$TMP_H5")"

apptainer exec --cleanenv \
  --bind "$ROOT:/work/repo:ro" \
  --bind "$DATA_ROOT_NORM:/work/data:ro" \
  --bind "$HDF5_ROOT_NORM:/work/hdf5" \
  --pwd /work \
  "$SIF_IMAGE" \
  python3 /work/repo/scripts/create_hdf5_from_vcf.py \
    --in-vcf "/work/data/$VCF_REL" \
    --marker "/work/data/$MARKER_REL" \
    --map "/work/data/$MAP_REL" \
    --out-vcf "/work/hdf5/$VCF_1240K_REL" \
    --out-h5 "/work/hdf5/$H5_REL" \
    --tmp-h5 "/work/hdf5/$TMP_H5_REL" \
    --ch "$CH" \
    --col-sample-af AF_ALL \
    "${REF_AF_ARGS[@]}" \
  >"$HDF5_ROOT/logs/hdf5_ch${CH}.out" 2>"$HDF5_ROOT/logs/hdf5_ch${CH}.err"

if apptainer exec --cleanenv \
    --bind "$ROOT:/work/repo:ro" \
    --bind "$HDF5_ROOT_NORM:/work/hdf5:ro" \
    --pwd /work \
    "$SIF_IMAGE" \
    python3 /work/repo/scripts/validate_hdf5.py "/work/hdf5/$H5_REL" >/dev/null; then
  echo "[build_hdf5] OK: $H5_PATH"
else
  die "[build_hdf5] ERROR: HDF5 build finished but validation failed: $H5_PATH"
fi
