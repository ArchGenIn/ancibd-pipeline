#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config
require_cmd apptainer

RUN_ID="${RUN_ID:?set RUN_ID env var}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

# In concurrent workflows (batchpair jobs), many jobs may try to write the
# manifest simultaneously. The manifest is intended to be run-level metadata,
# so treat it as write-once.
if [[ -s "$RUN_DIR/manifest.txt" ]]; then
  exit 0
fi

tmp="$(mktemp "$RUN_DIR/manifest.txt.tmp.XXXXXX")"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

{
  echo "RUN_ID=$RUN_ID"
  echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "SIF_IMAGE=$SIF_IMAGE"
  if [[ -f "$SIF_IMAGE" ]]; then
    sha256sum "$SIF_IMAGE" || true
  fi
  echo
  echo "[container versions]"
  apptainer exec --cleanenv "$SIF_IMAGE" python3 -c "import ancIBD; print('ancIBD', getattr(ancIBD,'__version__','unknown'))" || true
  apptainer exec --cleanenv "$SIF_IMAGE" bcftools --version | head -n 1 || true
} > "$tmp"

# Avoid clobbering if another concurrent job already wrote the manifest.
if [[ ! -s "$RUN_DIR/manifest.txt" ]]; then
  mv "$tmp" "$RUN_DIR/manifest.txt"
fi

cleanup
trap - EXIT
