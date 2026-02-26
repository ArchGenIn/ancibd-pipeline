#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

CH_RANGE="${1:-${CH_RANGE:-1-22}}"
read -r CH_START CH_END < <(parse_ch_range "$CH_RANGE")

HDF5_ROOT_NORM="$(hdf5_root_norm)"

fail=0
for ((ch=CH_START; ch<=CH_END; ch++)); do
  h5_path="$(h5_path_for_ch "$ch")"
  if [[ ! -f "$h5_path" ]]; then
    echo "MISSING: ch${ch} -> $h5_path" >&2
    fail=1
    continue
  fi

  h5_rel="$(rel_under_hdf5 "$h5_path")"
  if apptainer exec --cleanenv \
      --bind "$ROOT:/work/repo:ro" \
      --bind "$HDF5_ROOT_NORM:/work/hdf5:ro" \
      --pwd /work \
      "$SIF_IMAGE" \
      python3 /work/repo/scripts/validate_hdf5.py "/work/hdf5/$h5_rel" >/dev/null; then
    echo "OK: ch${ch}"
  else
    echo "BROKEN: ch${ch} -> $h5_path" >&2
    fail=1
  fi
done

exit $fail
