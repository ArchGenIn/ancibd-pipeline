#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_config

RUN_ID="${RUN_ID:?set RUN_ID env var}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

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
} > "$RUN_DIR/manifest.txt"
