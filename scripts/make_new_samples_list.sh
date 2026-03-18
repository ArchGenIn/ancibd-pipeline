#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer
require_cmd python3

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

mkdir -p "$OUTDIR"
OUT_PATH="${OUTDIR%/}/${RUN_ID}_new_samples.txt"
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

python3 - "$ANALYZED_IIDS" "$TMP_DIR/hdf5_iids.txt" "$OUT_PATH" <<'PY'
from pathlib import Path
import sys

def read_iids(path: Path) -> list[str]:
    items: list[str] = []
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        iid = s.split()[0]
        if iid in seen:
            continue
        items.append(iid)
        seen.add(iid)
    return items

analyzed_path = Path(sys.argv[1])
hdf5_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])

analyzed = read_iids(analyzed_path)
hdf5_iids = read_iids(hdf5_path)
hdf5_set = set(hdf5_iids)
analyzed_set = set(analyzed)
unknown = [iid for iid in analyzed if iid not in hdf5_set]
new_samples = [iid for iid in hdf5_iids if iid not in analyzed_set]

out_path.write_text("".join(f"{iid}\n" for iid in new_samples), encoding="utf-8")

if unknown:
    preview = ", ".join(unknown[:10])
    extra = "" if len(unknown) <= 10 else ", ..."
    print(
        f"WARNING: analyzed IID file contains {len(unknown)} IID(s) not present in the HDF5 sample list: {preview}{extra}",
        file=sys.stderr,
    )
elif len(analyzed_set) == len(hdf5_set):
    print(
        "WARNING: analyzed IID file equals the HDF5 sample list; the output new-sample list is empty.",
        file=sys.stderr,
    )

print(f"Wrote {out_path} (n={len(new_samples)})")
PY

echo "Source HDF5: $H5_PATH"
