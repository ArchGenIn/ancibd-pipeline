#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

CH="${1:?usage: run_chrom.sh <CH>}"

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"
[[ -e "$RUN_DIR/DONE" ]] && die "Run is DONE: $RUN_DIR"

mkdir -p "$RUN_DIR"/{meta,work,out,logs}
"$ROOT/scripts/write_manifest.sh"

# Run-level overrides written by ./ancibd-pipeline baseline/prod.
OPTIONS_FILE="$RUN_DIR/meta/options.env"
if [[ -f "$OPTIONS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$OPTIONS_FILE"
fi
PCOL="${PCOL:-AF_ALL}"
PCOL="${PCOL^^}"

# Ensure IID list exists.
if [[ ! -s "$RUN_DIR/meta/iids.txt" ]]; then
  "$ROOT/scripts/make_iid_list.sh" >/dev/null
fi

H5_PATH="$(tpl "$HDF5_TEMPLATE" "$CH")"
[[ -f "$H5_PATH" ]] || die "Missing HDF5 for ch${CH}: $H5_PATH (build it first: ./ancibd-pipeline build-hdf5 ${CH_RANGE:-1-22})"

HDF5_ROOT_NORM="$(hdf5_root_norm)"

H5_REL="$(rel_under_hdf5 "$H5_PATH")"

apptainer exec --cleanenv \
  --bind "$ROOT:/work/repo:ro" \
  --bind "$HDF5_ROOT_NORM:/work/hdf5:ro" \
  --bind "$RUN_DIR:/work/run" \
  --pwd /work \
  "$SIF_IMAGE" \
  python3 /work/repo/scripts/call_ibd_chrom.py \
    --h5 "/work/hdf5/$H5_REL" \
    --ch "$CH" \
    --out-dir "/work/run/work" \
    --prefix "$PREFIX" \
    --pcol "$PCOL" \
    --iids-file "/work/run/meta/iids.txt" \
  >"$RUN_DIR/logs/ch${CH}.out" 2>"$RUN_DIR/logs/ch${CH}.err"
