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

## Build HDF5 inputs

Build HDF5s for a chromosome range (example: chr20 only):

```bash
./ancibd-pipeline build-hdf5 20-20
```

Or submit as one Condor job per chromosome:

```bash
./ancibd-pipeline build-hdf5-condor 1-22
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

This runs ancIBD per chromosome and then runs `ancIBD-summary`.

## Run prod (concurrent)

`prod` submits a DAGMan workflow:

- one **batchpair** submit node (queues all `(batch_i,batch_j)` jobs)
- then a **merge** job

```bash
RUN_ID="$(./ancibd-pipeline new-run prod)"; export RUN_ID
./ancibd-pipeline prod 20-20
```

Monitor with:

```bash
condor_q
./ancibd-pipeline check-batch
```

When the DAG finishes, `runs/<RUN_ID>/DONE` is written and merged outputs are in `out/merged/`.

## Compare baseline vs prod

```bash
./scripts/compare_outputs.sh \
  runs/<RUN_BASE>/out/merged \
  runs/<RUN_PROD>/out/merged
```

The comparison is order-insensitive (ignores header and row order).
