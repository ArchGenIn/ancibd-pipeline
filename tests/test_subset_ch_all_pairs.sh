#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf 'iid1\tiid2\tn_IBD>8\n' > "$TMP/ibd_ind.tsv"
printf 'iid1\tiid2\tch\tStartM\tEndM\nA\tB\t1\t0.1\t0.2\n' > "$TMP/ch_all.tsv"

"$ROOT/scripts/postprocess/subset_ch_all_pairs.sh" \
  --ibd-ind "$TMP/ibd_ind.tsv" \
  --ch-all "$TMP/ch_all.tsv" \
  --out "$TMP/out.tsv" >/dev/null 2>/dev/null

[[ "$(wc -l < "$TMP/out.tsv")" -eq 1 ]]
[[ "$(head -n 1 "$TMP/out.tsv")" == $'iid1\tiid2\tch\tStartM\tEndM' ]]
[[ ! -s "$TMP/out.tsv.exact_pairs_to_keep.tsv" ]]
[[ ! -s "$TMP/out.tsv.missing_pairs.tsv" ]]
