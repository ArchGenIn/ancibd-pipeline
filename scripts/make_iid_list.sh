#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

RUN_ID="${RUN_ID:?set RUN_ID env var (use scripts/new_run.sh)}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"

mkdir -p "$RUN_DIR/meta" "$RUN_DIR/logs"

# Pick a chromosome just to read sample IDs from the VCF header.
# The sample set should be identical across chromosomes for a given dataset.
CH="${1:-}"
if [[ -z "$CH" ]]; then
  # Prefer CH_RANGE from config; fall back to 20 for the tutorial dataset.
  local_range="${CH_RANGE:-20-20}"
  # We only need the start chromosome to locate a representative VCF.
  read -r CH_START _ < <(parse_ch_range "$local_range")
  CH="$CH_START"
fi

VCF_PATH="$(tpl "$VCF_TEMPLATE" "$CH")"
[[ -f "$VCF_PATH" ]] || die "Missing VCF for IID extraction: $VCF_PATH"

DATA_ROOT_NORM="$(data_root_norm)"
VCF_REL="$(rel_under_data "$VCF_PATH")"

OUT_HOST="$RUN_DIR/meta/iids.txt"

# Query sample IDs inside the container (so the host only needs Apptainer).
apptainer exec --cleanenv \
  --bind "$DATA_ROOT_NORM:/work/data:ro" \
  --bind "$RUN_DIR:/work/run" \
  --pwd /work \
  "$SIF_IMAGE" \
  bash -lc "set -euo pipefail; bcftools query -l '/work/data/$VCF_REL' > '/work/run/meta/iids.txt.tmp'; mv '/work/run/meta/iids.txt.tmp' '/work/run/meta/iids.txt'" \
  >"$RUN_DIR/logs/iids_ch${CH}.out" 2>"$RUN_DIR/logs/iids_ch${CH}.err"

# Small sanity check on the host side
[[ -s "$OUT_HOST" ]] || die "IID list was not created or is empty: $OUT_HOST"

echo "Wrote IID list: $OUT_HOST (n=$(wc -l < "$OUT_HOST"))"
