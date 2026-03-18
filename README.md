# ancibd-pipeline

Wrapper pipeline around **ancIBD** with **Apptainer** isolation and **HTCondor** concurrency.

The main entry points are:

- `baseline`: run ancIBD chromosome by chromosome, then run `ancIBD-summary`
- `prod`: submit all-vs-all pairjobs plus one merge job through DAGMan
- `prod-incremental`: submit only pairjobs with at least one IID from a target set

Baseline writes both merged outputs:

- `runs/<RUN_ID>/out/merged/ch_all.tsv`
- `runs/<RUN_ID>/out/merged/ibd_ind.tsv`

Prod and prod-incremental always write:

- `runs/<RUN_ID>/out/merged/ibd_ind.tsv`

They write `runs/<RUN_ID>/out/merged/ch_all.tsv` only when `MERGE_CH_ALL="1"` in `config/local.env`.

## Setup

```bash
cp config/example.env config/local.env
# edit config/local.env
./containers/build.sh
```

## HDF5 naming

If `HDF5_TEMPLATE` is set, it is used directly.
Otherwise HDF5 paths are assembled as:

```text
${HDF5_ROOT}/${HDF5_PREFIX}${HDF5_CH_LABEL}{CH}${HDF5_SUFFIX}${HDF5_EXT}
```

The filtered VCF path uses the same prefix/label/suffix pieces together with `VCF_1240K_SUFFIX`, unless `VCF_1240K_TEMPLATE` is set.

## Allele-frequency fields

The pipeline can keep up to three AF datasets in the HDF5:

- `variants/AF_ALL`: sample AFs computed during HDF5 build
- `variants/RAF`: RAF imported from the filtered VCF/BCF, if present
- `variants/AF_REF`: standalone reference-AF TSVs baked into the HDF5

`--pcol` selects which field ancIBD reads at runtime:

- `--pcol AF_ALL`
- `--pcol RAF`
- `--pcol AF_REF`

`--pcol RAF` uses the `variants/RAF` dataset already present in the HDF5. It does not read `REF_AF_TEMPLATE`.

## Build HDF5 inputs

```bash
./ancibd-pipeline build-hdf5 20-20
./ancibd-pipeline build-hdf5 1-22 --with-ref-af
./ancibd-pipeline build-hdf5 1-22 --with-ref-af --ref-af-path "/path/to/v51.1_1240k_AF_ch{CH}.tsv"
```

The build always writes sample AFs to `variants/AF_ALL`. If the filtered VCF/BCF has a `RAF` field, it is imported into `variants/RAF`. `--with-ref-af` adds the standalone TSV-based AFs as `variants/AF_REF`.

Submit one Condor job per chromosome instead:

```bash
./ancibd-pipeline build-hdf5-condor 1-22
./ancibd-pipeline build-hdf5-condor 1-22 --with-ref-af
```

Validate the expected HDF5s:

```bash
./ancibd-pipeline validate-hdf5 1-22
```

## Run baseline

```bash
RUN_ID="$(./ancibd-pipeline new-run baseline)"; export RUN_ID
./ancibd-pipeline baseline 20-20
./ancibd-pipeline baseline 20-20 --pcol RAF
./ancibd-pipeline baseline 20-20 --pcol AF_REF
```

## Run prod

Set explicit pairjob resource requests in `config/local.env`:

- `BP_REQUEST_CPUS`
- `BP_REQUEST_MEMORY`
- `BP_REQUEST_DISK`

Then run:

```bash
RUN_ID="$(./ancibd-pipeline new-run prod)"; export RUN_ID
./ancibd-pipeline prod 20-20
./ancibd-pipeline prod 20-20 --pcol RAF
./ancibd-pipeline prod 20-20 --pcol AF_REF
```

The planner writes:

- `runs/<RUN_ID>/meta/pairjobs.tsv`
- `runs/<RUN_ID>/work/plans/<JOB_ID>.iids`
- `runs/<RUN_ID>/work/plans/<JOB_ID>.pairs`

For the default all-vs-all workflow, job IDs are the coarse batch rectangles:

- `b000_b000`
- `b000_b001`
- ...

## Run prod-incremental

`prod-incremental` analyses only pairs with at least one IID from a target set.

The target set comes from a one-column IID file and `--delta-kind`:

- `--delta-kind new`: listed IIDs are the target set
- `--delta-kind analyzed`: listed IIDs have already been analysed, so the target set is the complement within the current HDF5 sample list

This mode includes:

- target × target
- target × non-target

and excludes:

- non-target × non-target

Examples:

```bash
RUN_ID="$(./ancibd-pipeline new-run prod-incremental)"; export RUN_ID
./ancibd-pipeline prod-incremental 1-22 \
  --delta-iids data/new_samples.txt \
  --delta-kind new

RUN_ID="$(./ancibd-pipeline new-run prod-incremental)"; export RUN_ID
./ancibd-pipeline prod-incremental 1-22 \
  --delta-iids data/already_analysed.txt \
  --delta-kind analyzed \
  --pcol RAF
```

The planner still uses `BATCH_SIZE` to define coarse sample batches, but it emits only the exact pairjobs required by the target set. Job IDs are suffixed by the job shape:

- `_newleft`
- `_newright`
- `_newnew`
- `_newold`

The resolved target IID set is written to `runs/<RUN_ID>/meta/target_iids.txt`.

## Monitor prod runs

```bash
condor_q
./ancibd-pipeline check-batch
```

`BP_MAXJOBS=0` means no explicit DAGMan cap.

## tune_grid helper

`scripts/tune_grid.sh` sweeps a grid of `BATCH_SIZE` and `BP_MAXJOBS` settings for a fixed time budget per point. It also rewrites `BP_REQUEST_CPUS`, `BP_REQUEST_MEMORY`, and `BP_REQUEST_DISK` for each point based on the current Condor pool.

Examples:

```bash
./scripts/tune_grid.sh
CH_RANGE=2-2 PCOL=AF_REF DURATION_SEC=600 ./scripts/tune_grid.sh
./scripts/tune_grid.sh --help
```

More detail: `docs/tune_grid.md`

## Compare baseline vs prod

```bash
./scripts/compare_outputs.sh \
  <RUN_BASE>/out/merged \
  <RUN_PROD>/out/merged
```

The comparison ignores header and row order.
