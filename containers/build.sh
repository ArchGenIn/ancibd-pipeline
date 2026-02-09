#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEF="$ROOT/containers/ancibd.def"
OUT="$ROOT/containers/ancibd_0.8_ubuntu22.sif"

mkdir -p "$ROOT/containers/provenance"

echo "Building: $OUT"
if apptainer build --fakeroot "$OUT" "$DEF"; then
  :
else
  echo "fakeroot build failed; retrying with sudo..." >&2
  sudo apptainer build "$OUT" "$DEF"
  sudo chown "$USER":"$USER" "$OUT"
fi

sha256sum "$OUT" | tee "$ROOT/containers/provenance/ancibd_0.8_ubuntu22.sif.sha256"
apptainer inspect "$OUT" > "$ROOT/containers/provenance/ancibd_0.8_inspect.txt"
apptainer exec --cleanenv "$OUT" python3 -m pip freeze > "$ROOT/containers/provenance/ancibd_0.8_pip-freeze.txt"

echo "Done."
