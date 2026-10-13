# Convenience utilities

These helpers cover repeatable preparation and post-processing operations around
`ancibd-pipeline`. They are intentionally **not** top-level `ancibd-pipeline`
subcommands: they are optional workflow utilities rather than required stages of
an IBD run.

The BCF preprocessing utilities use `bcftools` from the same Apptainer image
configured by `SIF_IMAGE` in `config/local.env`. They do not use a host
`bcftools`. The streaming `ch_all` subsetter uses only shell/coreutils/awk and
optionally host `pv` for a progress display.

## Preprocessing BCFs

### Downsample sites

`scripts/preprocess/downsample_bcfs.sh` applies per-chromosome `bcftools view
-T` target lists and indexes each output.

```bash
./scripts/preprocess/downsample_bcfs.sh \
  --in-template '/path/to/chr{chr}.input.bcf' \
  --out-template '/path/to/chr{chr}.1240k.bcf' \
  --targets-dir data/filters \
  --chroms 1-22
```

Use `--dry-run` to inspect the resolved inputs/outputs and commands before
writing anything.

### Merge BCF sets

`scripts/preprocess/merge_bcfs.sh` merges corresponding chromosomes with
`bcftools merge --force-samples`. Input order is significant when duplicate
sample names occur: names duplicated from the second input are prefixed by
bcftools.

```bash
./scripts/preprocess/merge_bcfs.sh \
  --first-template '/path/to/chr{chr}.older.bcf' \
  --second-template '/path/to/chr{chr}.newer.bcf' \
  --out-template '/path/to/merged/chr{chr}.merged.bcf' \
  --chroms 1-22
```

The utility checks the merged sample list/order on every chromosome by reading
BCF headers. This is cheap relative to the merge itself: genotype data are not
rescanned for the check. If all chromosomes agree, it writes one canonical
`merged.samples.txt` sidecar (override with `--samples-out`) and
`merge_summary.tsv`. If an input index is missing, the utility creates it, as
the earlier lab helper did.

### Subset samples

`scripts/preprocess/subset_bcfs.sh` subsets all selected chromosomes to one IID
list and validates that every output contains exactly that sample set in the
requested order.

```bash
./scripts/preprocess/subset_bcfs.sh \
  --in-template '/path/to/chr{chr}.in.bcf' \
  --out-template '/path/to/subset/chr{chr}.subset.bcf' \
  --samples /path/to/iids.txt \
  --chroms 1-22
```

On success, the utility writes one canonical `subset.samples.txt` sidecar
(override with `--samples-out`) plus `subset_summary.tsv`; it does not leave one
sample-list sidecar per chromosome. Blank lines in the requested IID list are
ignored, and duplicate IIDs are rejected.

## Post-processing merged ancIBD output

`scripts/postprocess/subset_ch_all_pairs.sh` keeps from a large `ch_all.tsv`
only rows whose undirected IID pair is present in a filtered `ibd_ind.tsv`. It
streams `ch_all.tsv`, so only the requested pair set is held in memory.

```bash
./scripts/postprocess/subset_ch_all_pairs.sh \
  --ibd-ind /path/to/filtered_ibd_ind.tsv \
  --ch-all /path/to/ch_all.tsv \
  --out /path/to/ch_all.filtered.tsv \
  --progress
```

The utility also writes the canonical pair list it used and a report of
requested pairs that were absent from `ch_all.tsv`.
