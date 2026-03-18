# ancibd-pipeline

A tight, reproducible pipeline around **ancIBD**, using **Apptainer** for isolation and **HTCondor** for concurrency.

The goal is to make it easy to run ancIBD in two ways:

1. **baseline** – dumb, slow, obviously-correct reference (per-chromosome → summary)
2. **prod** – concurrent production workflow (batchpairs via `--iid/--pair` → merge)

Both modes produce comparable outputs under:

- `runs/<RUN_ID>/out/merged/ch_all.tsv`
- `runs/<RUN_ID>/out/merged/ibd_ind.tsv`

## Safety rules

- Treat `DATA_ROOT` as immutable (read-only binds in the container).
- Derived HDF5s are written under `HDF5_ROOT`.
- Every execution uses a unique `RUN_ID` under `RUNS_ROOT`.
- A run is immutable once `runs/<RUN_ID>/DONE` exists.

## Setup

1) Copy and edit config:

```bash
cp config/example.env config/local.env
# edit config/local.env (paths, prefix, templates)
```

2) Build the container image (once per machine):

```bash
./containers/build.sh
```

## IID list generation

ancIBD requires a consistent list of sample IDs (IIDs) to define batches.
This pipeline writes the IID list to:

- `runs/<RUN_ID>/meta/iids.txt`

The IID list is extracted from the **HDF5** input (dataset: `samples`).
This supports workflows where you start from prebuilt HDF5s and do not have
the original VCF/BCF inputs available.

If you change the HDF5 inputs, regenerate the IID list by deleting
`runs/<RUN_ID>/meta/iids.txt` and re-running a command (`baseline` or `prod`)
that needs it.

## HDF5 naming

By default, the scripts locate per-chromosome HDF5s under `HDF5_ROOT` using
the naming components in `config/local.env`:

`$HDF5_ROOT/${HDF5_PREFIX}${HDF5_CH_LABEL}<CH>${HDF5_SUFFIX}${HDF5_EXT}`

This lets you work with names like `chr2.merged.1240k.20250825.h5` without
renaming files.

If you prefer, you can instead set `HDF5_TEMPLATE` (and optionally
`VCF_1240K_TEMPLATE`) explicitly with a `{CH}` placeholder.

## Local cloud emulation (HTCondor + shared filesystem)

If you want to emulate a shared-filesystem HTCondor cloud locally (for example
via Multipass) before running on a real cluster, see:

- `docs/local_cloud_emulation.md`

## Allele-frequency fields in the HDF5

The pipeline can keep up to three allele-frequency datasets side by side:

- `variants/AF_ALL` – sample allele frequencies computed from the input data
- `variants/RAF` – RAF imported from the filtered VCF/BCF when the input file provides it
- `variants/AF_REF` – standalone reference-AF TSVs merged into the HDF5 by the pipeline

`--pcol` selects which field ancIBD uses at runtime:

- `--pcol AF_ALL` → `variants/AF_ALL`
- `--pcol RAF` → `variants/RAF`
- `--pcol AF_REF` → `variants/AF_REF`

`--pcol RAF` does not use `REF_AF_TEMPLATE` or `RAF_TEMPLATE`. It reads the
VCF-derived `variants/RAF` field already present in the HDF5, if that field
exists.

## Build HDF5 inputs

Build HDF5s for a chromosome range (example: chr20 only):

```bash
./ancibd-pipeline build-hdf5 20-20
```

This always computes **sample allele frequencies** and stores them in
`variants/AF_ALL`.

If your filtered VCF/BCF carries a `RAF` field, that field is imported into the
HDF5 as `variants/RAF` automatically during HDF5 creation.

To also bake standalone per-chromosome reference-AF TSVs into the HDF5, use:

```bash
./ancibd-pipeline build-hdf5 1-22 --with-ref-af
```

This writes the TSV-based AFs to `variants/AF_REF`. The template comes from
`REF_AF_TEMPLATE` in `config/local.env`. `RAF_TEMPLATE` is still accepted as a
backward-compatible alias.

Override the template on the command line:

```bash
./ancibd-pipeline build-hdf5 1-22 --with-ref-af --ref-af-path "/path/to/v51.1_1240k_AF_ch{CH}.tsv"
```

Backward-compatible aliases are also accepted:

```bash
./ancibd-pipeline build-hdf5 1-22 --with-raf
./ancibd-pipeline build-hdf5 1-22 --with-raf --raf-path "/path/to/v51.1_1240k_AF_ch{CH}.tsv"
```

Submit HDF5 builds as one Condor job per chromosome:

```bash
./ancibd-pipeline build-hdf5-condor 1-22
./ancibd-pipeline build-hdf5-condor 1-22 --with-ref-af
```

Validate the expected HDF5s:

```bash
./ancibd-pipeline validate-hdf5 1-22
```

## Run baseline (reference)

```bash
RUN_ID="$(./ancibd-pipeline new-run baseline)"; export RUN_ID
./ancibd-pipeline baseline 20-20
```

Use a different AF field at runtime with `--pcol`:

```bash
./ancibd-pipeline baseline 20-20 --pcol RAF
./ancibd-pipeline baseline 20-20 --pcol AF_REF
```

`--pcol AF_REF` requires building the HDF5s with `--with-ref-af` (or the
backward-compatible alias `--with-raf`).

This runs ancIBD per chromosome and then runs `ancIBD-summary`.

## Run prod (concurrent)

`prod` submits a DAGMan workflow:

- one **batchpair** job per `(batch_i,batch_j)` node
- then a single **merge** job

```bash
RUN_ID="$(./ancibd-pipeline new-run prod)"; export RUN_ID
./ancibd-pipeline prod 20-20
```

The same allele-frequency selector works in `prod`:

```bash
./ancibd-pipeline prod 20-20 --pcol RAF
./ancibd-pipeline prod 20-20 --pcol AF_REF
```

Monitor with:

```bash
condor_q
./ancibd-pipeline check-batch
```

When the DAG finishes, `runs/<RUN_ID>/DONE` is written and merged outputs are
in `out/merged/`.

## Tuning helper for HTCondor grid sweeps

`scripts/tune_grid.sh` runs a small grid of `BATCH_SIZE` and `BP_MAXJOBS`
settings for a fixed time budget per point. It is useful for comparing
throughput across candidate settings without waiting for full runs.

Key properties:

- edits `config/local.env` temporarily and restores it on exit
- derives request sizes from the current Condor pool baseline
- writes a summary TSV under `runs/tuning/`
- removes each DAG after the time budget expires

Examples:

```bash
./scripts/tune_grid.sh
CH_RANGE=2-2 PCOL=AF_REF DURATION_SEC=600 ./scripts/tune_grid.sh
./scripts/tune_grid.sh --help
```

More detail is in:

- `docs/tune_grid.md`

## Compare baseline vs prod

```bash
./scripts/compare_outputs.sh \
  <RUN_BASE>/out/merged \
  <RUN_PROD>/out/merged

# You can also pass absolute paths or repo-root-relative paths (for example runs/<RUN_ID>/...).
```

The comparison is order-insensitive (ignores header and row order).
