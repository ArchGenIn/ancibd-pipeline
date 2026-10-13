#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  subset_ch_all_pairs.sh \
    --ibd-ind /path/to/filtered_ibd_ind.tsv \
    --ch-all  /path/to/ch_all.tsv \
    --out     /path/to/ch_all_minimal.tsv \
    [--pair-list /path/to/exact_pairs_to_keep.tsv] \
    [--missing-pairs /path/to/missing_pairs.tsv] \
    [--progress] [--force] [--dry-run]

Purpose:
  Streaming counterpart of the exact-pair R subsetter:

    1. Read iid1/iid2 from the filtered ibd_ind table.
    2. Canonicalise each pair as min(iid1, iid2), max(iid1, iid2).
    3. Stream through huge ch_all.tsv.
    4. Keep only rows whose canonicalised iid1/iid2 pair is present in ibd_ind.
    5. Preserve the original ch_all.tsv columns/lines; no helper iidSTD column is written.

Options:
  --ibd-ind FILE       Filtered ibd_ind-style TSV containing iid1 and iid2 columns.
  --ch-all FILE        Huge ch_all.tsv-style TSV containing iid1 and iid2 columns.
  --out FILE           Output TSV.
  --pair-list FILE     Optional canonical two-column pair list to create/reuse.
                       Default: OUT.exact_pairs_to_keep.tsv
  --missing-pairs FILE Optional report of ibd_ind pairs not observed in ch_all subset.
                       Default: OUT.missing_pairs.tsv
  --progress           Pipe ch_all through pv, if pv is available.
  --force              Allow overwriting OUT and report files.
  --dry-run            Check paths and print planned outputs, but do not stream ch_all.

Notes:
  - This is intended for very large ch_all.tsv files. It keeps only the exact pair
    set in memory, not the full ch_all table.
  - Pair canonicalisation is undirected and internally consistent for both inputs.
USAGE
}

IBD=""
CH=""
OUT=""
PAIR_LIST=""
MISSING_PAIRS=""
PROGRESS=0
FORCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ibd-ind)       IBD="$2"; shift 2 ;;
    --ch-all)        CH="$2"; shift 2 ;;
    --out)           OUT="$2"; shift 2 ;;
    --pair-list)     PAIR_LIST="$2"; shift 2 ;;
    --missing-pairs) MISSING_PAIRS="$2"; shift 2 ;;
    --progress)      PROGRESS=1; shift ;;
    --force)         FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$IBD" || -z "$CH" || -z "$OUT" ]]; then
  echo "ERROR: --ibd-ind, --ch-all, and --out are required" >&2
  usage
  exit 2
fi

if [[ ! -r "$IBD" ]]; then
  echo "ERROR: cannot read --ibd-ind: $IBD" >&2
  exit 2
fi

if [[ ! -r "$CH" ]]; then
  echo "ERROR: cannot read --ch-all: $CH" >&2
  exit 2
fi

if [[ -z "$PAIR_LIST" ]]; then
  PAIR_LIST="${OUT}.exact_pairs_to_keep.tsv"
fi

if [[ -z "$MISSING_PAIRS" ]]; then
  MISSING_PAIRS="${OUT}.missing_pairs.tsv"
fi

if [[ "$FORCE" -ne 1 ]]; then
  for f in "$OUT" "$PAIR_LIST" "$MISSING_PAIRS"; do
    if [[ -e "$f" ]]; then
      echo "ERROR: output/report file exists; use --force to overwrite: $f" >&2
      exit 2
    fi
  done
fi

mkdir -p "$(dirname "$OUT")" "$(dirname "$PAIR_LIST")" "$(dirname "$MISSING_PAIRS")"

cat >&2 <<EOF2
Input ibd_ind:     $IBD
Input ch_all:      $CH
Output ch_all:     $OUT
Pair list:         $PAIR_LIST
Missing-pair list: $MISSING_PAIRS
Progress via pv:   $PROGRESS
Dry run:           $DRY_RUN
EOF2

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo >&2
  echo "[dry-run] Would extract exact canonical pairs from ibd_ind." >&2
  echo "[dry-run] Would stream-filter ch_all by those pairs." >&2
  exit 0
fi

TMP_PAIR="${PAIR_LIST}.tmp.$$"
TMP_OUT="${OUT}.tmp.$$"
TMP_MISSING="${MISSING_PAIRS}.tmp.$$"
trap 'rm -f "$TMP_PAIR" "$TMP_OUT" "$TMP_MISSING"' EXIT

# Step 1: Create the canonical exact-pair list from the filtered ibd_ind table.
# The helper key is represented as two columns rather than pasted with "_", so
# underscores inside sample names cannot create collisions.
echo >&2
echo "Creating canonical exact-pair list..." >&2
awk -F'\t' -v OFS='\t' '
  FNR == 1 {
    for (i = 1; i <= NF; i++) {
      if ($i == "iid1") c1 = i
      if ($i == "iid2") c2 = i
    }
    if (!c1 || !c2) {
      print "ERROR: iid1/iid2 columns not found in ibd_ind file" > "/dev/stderr"
      exit 2
    }
    next
  }
  {
    a = $c1
    b = $c2
    if (a > b) { t = a; a = b; b = t }
    print a, b
  }
' "$IBD" | LC_ALL=C sort -u > "$TMP_PAIR"

mv "$TMP_PAIR" "$PAIR_LIST"
N_PAIRS=$(wc -l < "$PAIR_LIST" | tr -d ' ')
echo "Canonical exact pairs to keep: $N_PAIRS" >&2

# Step 2: Stream-filter ch_all.
echo >&2
echo "Streaming ch_all filter..." >&2

# Important: create an empty missing-pairs temp file in advance.
# If no requested pair is absent, awk never redirects any line to missing_file,
# so without this the later mv would fail.
: > "$TMP_MISSING"

AWK_FILTER='
  NR == FNR {
    keep[$1 SUBSEP $2] = 1
    n_keep++
    next
  }

  FNR == 1 {
    for (i = 1; i <= NF; i++) {
      if ($i == "iid1") d1 = i
      if ($i == "iid2") d2 = i
    }
    if (!d1 || !d2) {
      print "ERROR: iid1/iid2 columns not found in ch_all file" > "/dev/stderr"
      exit 2
    }
    print
    next
  }

  {
    a = $d1
    b = $d2
    if (a > b) { t = a; a = b; b = t }
    k = a SUBSEP b
    if (k in keep) {
      print
      seen[k] = 1
      kept_rows++
    }
  }

  END {
    missing_n = 0
    for (k in keep) {
      if (!(k in seen)) {
        split(k, parts, SUBSEP)
        print parts[1], parts[2] > missing_file
        missing_n++
      }
    }
    close(missing_file)
    print "Kept ch_all data rows: " kept_rows > "/dev/stderr"
    print "Exact pairs requested: " n_keep > "/dev/stderr"
    print "Requested pairs absent from kept ch_all rows: " missing_n > "/dev/stderr"
  }
'

if [[ "$PROGRESS" -eq 1 ]]; then
  if command -v pv >/dev/null 2>&1; then
    pv "$CH" | awk -F'\t' -v OFS='\t' -v missing_file="$TMP_MISSING" "$AWK_FILTER" "$PAIR_LIST" - > "$TMP_OUT"
  else
    echo "WARNING: --progress requested, but pv is not installed; continuing without progress." >&2
    awk -F'\t' -v OFS='\t' -v missing_file="$TMP_MISSING" "$AWK_FILTER" "$PAIR_LIST" "$CH" > "$TMP_OUT"
  fi
else
  awk -F'\t' -v OFS='\t' -v missing_file="$TMP_MISSING" "$AWK_FILTER" "$PAIR_LIST" "$CH" > "$TMP_OUT"
fi

mv "$TMP_OUT" "$OUT"
mv "$TMP_MISSING" "$MISSING_PAIRS"
trap - EXIT

echo >&2
echo "Done." >&2
echo "Output:             $OUT" >&2
echo "Pair list:          $PAIR_LIST" >&2
echo "Missing-pair list:  $MISSING_PAIRS" >&2
echo >&2
echo "To verify the output, you can run:" >&2
echo "  wc -l '$OUT'" >&2
echo "  wc -l '$PAIR_LIST' '$MISSING_PAIRS'" >&2
