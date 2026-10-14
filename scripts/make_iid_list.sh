#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

assert_run_unpopulated_for_metadata "$RUN_DIR"
[[ ! -e "$RUN_DIR/meta/iids.txt" ]] || die "IID list already exists: $RUN_DIR/meta/iids.txt"
mkdir -p "$RUN_DIR/meta" "$RUN_DIR/logs"

OUT_HOST="$RUN_DIR/meta/iids.txt"

CH="${1:-}"
if [[ -n "$CH" ]]; then
  H5_PATH="$(h5_path_for_ch "$CH")"
  [[ -f "$H5_PATH" ]] || die "Missing HDF5 for chromosome $CH: $H5_PATH"
else
  H5_PATH="$(find_h5_for_iids)"
fi

HDF5_ROOT_NORM="$(hdf5_root_norm)"
H5_REL="$(rel_under_hdf5 "$H5_PATH")"

# Extract into a temporary file, so a failed extraction cannot leave behind
# a partial authoritative IID list (which the metadata guard would then lock).
TMP_IIDS_HOST="$(mktemp "$RUN_DIR/meta/.iids.txt.tmp.XXXXXXXX")"
trap 'rm -f "$TMP_IIDS_HOST"' EXIT
TMP_IIDS_REL="meta/$(basename "$TMP_IIDS_HOST")"

# Extract sample IDs inside the container (so the host only needs Apptainer).
apptainer exec --cleanenv \
  --bind "$ROOT:/work/repo:ro" \
  --bind "$HDF5_ROOT_NORM:/work/hdf5:ro" \
  --bind "$RUN_DIR:/work/run" \
  --pwd /work \
  "$SIF_IMAGE" \
  python3 /work/repo/scripts/extract_iids_from_h5.py \
    "/work/hdf5/$H5_REL" \
    --out "/work/run/$TMP_IIDS_REL" \
  >"$RUN_DIR/logs/iids.out" 2>"$RUN_DIR/logs/iids.err"

# Small sanity check on the host side
[[ -s "$TMP_IIDS_HOST" ]] || die "IID list was not created or is empty: $TMP_IIDS_HOST"
mv -- "$TMP_IIDS_HOST" "$OUT_HOST"

echo "Wrote IID list: $OUT_HOST (n=$(wc -l < "$OUT_HOST"))"
