#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

CH="${1:?usage: run_chrom.sh <CH>}"

RUN_ID="${RUN_ID:?set RUN_ID env var (use scripts/new_run.sh)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

[[ -e "$RUN_DIR/DONE" ]] && die "Run is DONE: $RUN_DIR"

mkdir -p "$RUN_DIR"/{work,out,logs}
"$ROOT/scripts/write_manifest.sh"

# Inputs
H5_PATH="$(tpl "$HDF5_TEMPLATE" "$CH")"
MARKER_PATH="$(tpl "$MARKER_TEMPLATE" "$CH")"
AF_PATH="$(tpl "$AF_TEMPLATE" "$CH")"

[[ -f "$H5_PATH" ]] || die "Missing HDF5 for ch${CH}: $H5_PATH (build it first: ancibd-pipeline build-hdf5 ${CH}-${CH})"
[[ -f "$MARKER_PATH" ]] || die "Missing markers: $MARKER_PATH"
[[ -f "$AF_PATH" ]] || die "Missing AF: $AF_PATH"
[[ -f "$MAP_PATH" ]] || die "Missing map: $MAP_PATH"

DATA_ROOT_NORM="$(data_root_norm)"
HDF5_ROOT_NORM="$(hdf5_root_norm)"

H5_REL="$(rel_under_hdf5 "$H5_PATH")"
MARKER_REL="$(rel_under_data "$MARKER_PATH")"
MAP_REL="$(rel_under_data "$MAP_PATH")"
AF_REL="$(rel_under_data "$AF_PATH")"

# Bind DATA + HDF5 read-only; bind run dir writable
apptainer exec --cleanenv \
  --bind "$DATA_ROOT_NORM:/work/data:ro" \
  --bind "$HDF5_ROOT_NORM:/work/hdf5:ro" \
  --bind "$RUN_DIR:/work/run" \
  --pwd /work \
  "$SIF_IMAGE" \
  ancIBD-run \
    --h5 "/work/hdf5/$H5_REL" \
    --ch "$CH" \
    --out "/work/run/work" \
    --marker_path "/work/data/$MARKER_REL" \
    --map_path "/work/data/$MAP_REL" \
    --af_path "/work/data/$AF_REL" \
    --prefix "$PREFIX" \
  >"$RUN_DIR/logs/ch${CH}.out" 2>"$RUN_DIR/logs/ch${CH}.err"
