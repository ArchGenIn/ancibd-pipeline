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

`prod-incremental` has two planning modes.

### Pair-aware history mode (recommended)

Supply one or more complete previous run directories with repeated `--previous-run` arguments. The planner reconstructs which pairs were already covered by those runs and emits exactly the pairs that are still missing among the current HDF5 IID set. Supply every earlier round whose coverage you want reused; omitting an older round cannot make the new result incomplete, but it can cause pairs known only from that omitted round to be recomputed.

This remains correct when filtering is non-monotonic across rounds: an IID may disappear from one round and later be deliberately reintroduced without causing already-covered pairs to be rerun or previously-unseen pairs to be missed.

```bash
RUN_ID="$(./ancibd-pipeline new-run prod-incremental)"; export RUN_ID
./ancibd-pipeline prod-incremental 1-22 \
  --previous-run runs/<ROUND1_RUN_ID> \
  --previous-run runs/<ROUND2_RUN_ID> \
  --previous-run runs/<ROUND3_RUN_ID>
```

Each supplied previous run must have complete per-job `DONE` coverage according to its `meta/pairjobs.tsv`. Full `prod` runs are interpreted as covering every pair among their `meta/iids.txt`; legacy incremental runs are interpreted using their `meta/iids.txt` and `meta/target_iids.txt`. This lets pair-aware planning reuse already-finished runs created by older pipeline versions without enumerating a global historical pair set.

The explicit previous-run paths are recorded in `runs/<RUN_ID>/meta/previous_runs.txt`, and `meta/incremental.env` records `INCREMENTAL_MODE=pair-history`.

### IID-delta mode (legacy/backward-compatible)

The original interface is unchanged. It analyses only pairs with at least one IID from a target set. The target set comes from a one-column IID file and `--delta-kind`:

- `--delta-kind new`: listed IIDs are the target set
- `--delta-kind analyzed`: listed IIDs have already been analysed, so the target set is the complement within the current HDF5 sample list

This mode includes target × target and target × non-target pairs, and excludes non-target × non-target pairs.

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

The planner still uses `BATCH_SIZE` to define coarse sample batches, but it emits only the exact pairjobs required by the selected mode. Legacy IID-delta job IDs use the existing `_newleft`, `_newright`, `_newnew`, and `_newold` suffixes. Pair-aware history jobs use `_missing` and can contain sparse exact pair lists within a coarse batch rectangle.

The resolved IID-delta target set is written to `runs/<RUN_ID>/meta/target_iids.txt`. Input IID lists are deduplicated automatically while preserving first-seen order. Duplicate entries are reported on stderr and then ignored.

The convenience helper remains available for the legacy IID-delta workflow:

```bash
RUN_ID=20260318T120000Z_prod-incremental
./scripts/make_new_samples_list.sh \
  --analyzed-iids runs/<OLD_RUN_ID>/meta/iids.txt
```

It writes `./${RUN_ID}_new_samples.txt` by subtracting the listed analysed IIDs from the current HDF5 sample list. This IID-level helper is safe when the analysed sample set evolves monotonically, but it cannot by itself detect missing old-old pairs created by non-monotonic filtering. Use pair-aware history mode for that case.

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

## Convenience preprocessing and post-processing utilities

Optional, documented helpers live under `scripts/preprocess/` and
`scripts/postprocess/`. They are deliberately kept outside the top-level
`ancibd-pipeline` CLI because they prepare inputs or transform outputs rather
than constitute mandatory ancIBD execution stages.

BCF utilities use the `bcftools` bundled in the configured Apptainer image.
Available helpers include:

- `scripts/preprocess/downsample_bcfs.sh` — restrict chromosome BCFs to target sites
- `scripts/preprocess/merge_bcfs.sh` — merge chromosome BCF sets and validate cross-chromosome sample consistency
- `scripts/preprocess/subset_bcfs.sh` — subset chromosome BCFs to a requested IID list and validate the result
- `scripts/postprocess/subset_ch_all_pairs.sh` — stream-filter `ch_all.tsv` to the exact IID pairs represented in a filtered `ibd_ind.tsv`

See [`docs/convenience_utilities.md`](docs/convenience_utilities.md) for usage and behaviour.
