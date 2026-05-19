#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

usage() {
  cat <<'USAGE'
Usage:
  RUN_ID=<incremental-run-id> ./scripts/make_new_samples_list.sh --analyzed-iids PATH [--outdir DIR]

Required:
  --analyzed-iids PATH   One-column IID file of already analysed samples

Optional:
  --outdir DIR           Output directory (default: .)

Output:
  <OUTDIR>/<RUN_ID>_new_samples.txt
USAGE
}

ANALYZED_IIDS=""
OUTDIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --analyzed-iids)
      [[ -n "${2:-}" ]] || die "--analyzed-iids requires a value"
      ANALYZED_IIDS="$2"
      shift 2
      ;;
    --outdir)
      [[ -n "${2:-}" ]] || die "--outdir requires a value"
      OUTDIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$ANALYZED_IIDS" ]] || die "--analyzed-iids is required"
[[ -f "$ANALYZED_IIDS" ]] || die "Missing analyzed IID file: $ANALYZED_IIDS"
RUN_ID="${RUN_ID:?set RUN_ID env var (use ./ancibd-pipeline new-run prod-incremental)}"

H5_PATH="$(find_h5_for_iids)"
HDF5_ROOT_NORM="$(hdf5_root_norm)"
H5_REL="$(rel_under_hdf5 "$H5_PATH")"
ANALYZED_IIDS_ABS="$(abs_path "$ANALYZED_IIDS")"
ANALYZED_IIDS_PARENT="$(dirname "$ANALYZED_IIDS_ABS")"
ANALYZED_IIDS_BASE="$(basename "$ANALYZED_IIDS_ABS")"

mkdir -p "$OUTDIR"
OUTDIR_ABS="$(abs_path "$OUTDIR")"
OUT_PATH="${OUTDIR_ABS%/}/${RUN_ID}_new_samples.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

apptainer exec --cleanenv \
  --bind "$ROOT:/work/repo:ro" \
  --bind "$HDF5_ROOT_NORM:/work/hdf5:ro" \
  --bind "$TMP_DIR:/work/tmp" \
  --pwd /work \
  "$SIF_IMAGE" \
  python3 /work/repo/scripts/extract_iids_from_h5.py \
    "/work/hdf5/$H5_REL" \
    --out "/work/tmp/hdf5_iids.txt"

apptainer exec --cleanenv \
  --bind "$ROOT:/work/repo:ro" \
  --bind "$ANALYZED_IIDS_PARENT:/work/analyzed:ro" \
  --bind "$TMP_DIR:/work/tmp:ro" \
  --bind "$OUTDIR_ABS:/work/out" \
  --pwd /work \
  "$SIF_IMAGE" \
  python3 /work/repo/scripts/compare_iid_lists.py \
    --analyzed-iids "/work/analyzed/$ANALYZED_IIDS_BASE" \
    --hdf5-iids "/work/tmp/hdf5_iids.txt" \
    --out "/work/out/${RUN_ID}_new_samples.txt"

[[ -s "$OUT_PATH" ]] || die "New-sample list was not created or is empty: $OUT_PATH"

echo "Source HDF5: $H5_PATH"
