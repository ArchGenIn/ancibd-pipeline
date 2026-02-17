#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

CH="${1:?usage: build_hdf5.sh <CH> [--force] [--with-raf] [--raf-path TEMPLATE_OR_PATH]}"
shift || true

FORCE=0
WITH_RAF=0
RAF_PATH_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1; shift
      ;;
    --with-raf)
      WITH_RAF=1; shift
      ;;
    --raf-path)
      [[ -n "${2:-}" ]] || die "--raf-path requires a value"
      RAF_PATH_ARG="$2"; WITH_RAF=1; shift 2
      ;;
    *)
      die "Unknown arg for build_hdf5.sh: $1"
      ;;
  esac
done

mkdir -p "$HDF5_ROOT" "$HDF5_ROOT/logs"

VCF_PATH="$(tpl "$VCF_TEMPLATE" "$CH")"
MARKER_PATH="$(tpl "$MARKER_TEMPLATE" "$CH")"
H5_PATH="$(tpl "$HDF5_TEMPLATE" "$CH")"
VCF_1240K_PATH="$(tpl "$VCF_1240K_TEMPLATE" "$CH")"

[[ -f "$VCF_PATH" ]] || die "Missing VCF: $VCF_PATH"
[[ -f "$MARKER_PATH" ]] || die "Missing marker list: $MARKER_PATH"
[[ -f "$MAP_PATH" ]] || die "Missing map: $MAP_PATH"

if [[ -f "$H5_PATH" && $FORCE -eq 0 ]]; then
  echo "[build_hdf5] Exists, skipping: $H5_PATH"
  exit 0
fi

# Optional: reference allele-frequency TSV -> variants/RAF
RAF_ARGS=()
if [[ $WITH_RAF -eq 1 ]]; then
  # Prefer explicit --raf-path, else config provides AF_TEMPLATE.
  RAF_TEMPLATE_EFF="$RAF_PATH_ARG"
  if [[ -z "$RAF_TEMPLATE_EFF" ]]; then
    RAF_TEMPLATE_EFF="${RAF_TEMPLATE:-${AF_TEMPLATE:-}}"
  fi
  [[ -n "$RAF_TEMPLATE_EFF" ]] || die "--with-raf requires RAF_TEMPLATE (or AF_TEMPLATE) in config/local.env or --raf-path"

  RAF_PATH="$(tpl "$RAF_TEMPLATE_EFF" "$CH")"
  [[ -f "$RAF_PATH" ]] || die "Missing RAF TSV for ch${CH}: $RAF_PATH"
  RAF_REL="$(rel_under_data "$RAF_PATH")"
  RAF_ARGS=( --raf "/work/data/$RAF_REL" )
fi

TMP_H5="$H5_PATH.tmp"

# For reproducibility: log where we read from and write to.
echo "[build_hdf5] Building HDF5 for ch$CH"
echo "[build_hdf5] Input  : $VCF_PATH"
echo "[build_hdf5] Output : $H5_PATH"

DATA_ROOT_NORM="$(data_root_norm)"
HDF5_ROOT_NORM="$(hdf5_root_norm)"

VCF_REL="$(rel_under_data "$VCF_PATH")"
MARKER_REL="$(rel_under_data "$MARKER_PATH")"
MAP_REL="$(rel_under_data "$MAP_PATH")"

# Bind roots into the container.
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
    --out-vcf "/work/hdf5/$(basename "$VCF_1240K_PATH")" \
    --out-h5 "/work/hdf5/$(basename "$H5_PATH")" \
    --tmp-h5 "/work/hdf5/$(basename "$TMP_H5")" \
    --ch "$CH" \
    --col-sample-af AF_ALL \
    "${RAF_ARGS[@]}" \
  >"$HDF5_ROOT/logs/hdf5_ch${CH}.out" 2>"$HDF5_ROOT/logs/hdf5_ch${CH}.err"

# Validate via a lightweight host-side check inside the container.
H5_REL="$(rel_under_hdf5 "$H5_PATH")"
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
