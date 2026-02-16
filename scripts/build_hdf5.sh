#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

CH="${1:?usage: build_hdf5.sh <CH> [--force]}"
FORCE=0
if [[ "${2:-}" == "--force" ]]; then
  FORCE=1
fi

# Inputs
VCF_PATH="$(tpl "$VCF_TEMPLATE" "$CH")"
MARKER_PATH="$(tpl "$MARKER_TEMPLATE" "$CH")"
AF_PATH="$(tpl "$AF_TEMPLATE" "$CH")"

[[ -f "$VCF_PATH" ]] || die "Missing VCF/BCF input: $VCF_PATH"
[[ -f "$MARKER_PATH" ]] || die "Missing markers: $MARKER_PATH"
[[ -f "$AF_PATH" ]] || die "Missing AF: $AF_PATH"
[[ -f "$MAP_PATH" ]] || die "Missing map: $MAP_PATH"

# Outputs
H5_PATH="$(tpl "$HDF5_TEMPLATE" "$CH")"
VCF_1240K_PATH="$(tpl "$VCF_1240K_TEMPLATE" "$CH")"

mkdir -p "$(dirname "$H5_PATH")" "$(dirname "$VCF_1240K_PATH")"

DATA_ROOT_NORM="$(data_root_norm)"
HDF5_ROOT_NORM="$(hdf5_root_norm)"

VCF_REL="$(rel_under_data "$VCF_PATH")"
MARKER_REL="$(rel_under_data "$MARKER_PATH")"
MAP_REL="$(rel_under_data "$MAP_PATH")"
AF_REL="$(rel_under_data "$AF_PATH")"

H5_REL="$(rel_under_hdf5 "$H5_PATH")"
VCF_1240K_REL="$(rel_under_hdf5 "$VCF_1240K_PATH")"

validate_h5() {
  apptainer exec --cleanenv \
    --bind "$ROOT:/work/repo:ro" \
    --bind "$HDF5_ROOT_NORM:/work/hdf5:ro" \
    --pwd /work \
    "$SIF_IMAGE" \
    python3 /work/repo/scripts/validate_hdf5.py "/work/hdf5/$H5_REL" >/dev/null 2>&1
}

if [[ -f "$H5_PATH" ]]; then
  if [[ $FORCE -eq 1 ]]; then
    echo "[build_hdf5] --force: removing existing $H5_PATH" >&2
    rm -f "$H5_PATH" "$VCF_1240K_PATH"
  else
    if validate_h5; then
      echo "[build_hdf5] OK (already built): $H5_PATH" >&2
      exit 0
    else
      echo "[build_hdf5] WARNING: existing HDF5 looks broken; rebuilding: $H5_PATH" >&2
      rm -f "$H5_PATH" "$VCF_1240K_PATH"
    fi
  fi
fi

echo "[build_hdf5] Building HDF5 for ch$CH" >&2

echo "[build_hdf5] Input  : $VCF_PATH" >&2
echo "[build_hdf5] Output : $H5_PATH" >&2

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
    --af "/work/data/$AF_REL" \
    --ch "$CH" \
    --out-vcf "/work/hdf5/$VCF_1240K_REL" \
    --out-h5 "/work/hdf5/$H5_REL"

# Post-check (and mark broken output for easy rebuild).
if ! validate_h5; then
  echo "[build_hdf5] ERROR: HDF5 build finished but validation failed: $H5_PATH" >&2
  exit 1
fi

echo "[build_hdf5] DONE: $H5_PATH" >&2
