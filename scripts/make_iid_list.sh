#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

mkdir -p "$RUN_DIR/meta" "$RUN_DIR/logs"

OUT_HOST="$RUN_DIR/meta/iids.txt"

# Pick a chromosome just to read sample IDs from the HDF5.
# The sample set should be identical across chromosomes for a given dataset.
CH="${1:-}"
if [[ -z "$CH" ]]; then
  local_range="${CH_RANGE:-20-20}"
  read -r CH_START CH_END < <(parse_ch_range "$local_range")
  # Prefer the first chromosome that has an HDF5 present.
  for ((c=CH_START; c<=CH_END; c++)); do
    if [[ -f "$(h5_path_for_ch "$c")" ]]; then
      CH="$c"
      break
    fi
  done
  # If none in CH_RANGE exist, try any HDF5 under HDF5_ROOT.
  if [[ -z "$CH" ]]; then
    any_h5="$(find "$(hdf5_root_norm)" -maxdepth 2 -type f -name '*.h5' | head -n 1 || true)"
    [[ -n "$any_h5" ]] || die "No HDF5 files found under HDF5_ROOT ($(hdf5_root_norm))."
    # We don't know its chromosome number; use it directly below.
  fi
fi

# If CH is set, use the configured naming to locate the per-chromosome HDF5.
H5_PATH=""
if [[ -n "$CH" ]]; then
  H5_PATH="$(h5_path_for_ch "$CH")"
fi
if [[ -z "$H5_PATH" || ! -f "$H5_PATH" ]]; then
  # Fallback: any HDF5 under HDF5_ROOT.
  H5_PATH="$(find "$(hdf5_root_norm)" -maxdepth 2 -type f -name '*.h5' | head -n 1 || true)"
fi
[[ -f "$H5_PATH" ]] || die "Missing HDF5 for IID extraction: $H5_PATH"

HDF5_ROOT_NORM="$(hdf5_root_norm)"
H5_REL="$(rel_under_hdf5 "$H5_PATH")"

# Extract sample IDs inside the container (so the host only needs Apptainer).
apptainer exec --cleanenv \
  --bind "$ROOT:/work/repo:ro" \
  --bind "$HDF5_ROOT_NORM:/work/hdf5:ro" \
  --bind "$RUN_DIR:/work/run" \
  --pwd /work \
  "$SIF_IMAGE" \
  python3 /work/repo/scripts/extract_iids_from_h5.py \
    "/work/hdf5/$H5_REL" \
    --out "/work/run/meta/iids.txt" \
  >"$RUN_DIR/logs/iids.out" 2>"$RUN_DIR/logs/iids.err"

# Small sanity check on the host side
[[ -s "$OUT_HOST" ]] || die "IID list was not created or is empty: $OUT_HOST"

echo "Wrote IID list: $OUT_HOST (n=$(wc -l < "$OUT_HOST"))"
