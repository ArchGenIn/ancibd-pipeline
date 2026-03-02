# HTCondor templates

This folder contains the minimal submit templates used by `./ancibd-pipeline`:

- `ancibd_hdf5.sub` – one job builds one chromosome HDF5 (used by `build-hdf5-condor`)
- `ancibd_batchpair.sub` – one batchpair job (DAGMan provides `B1/B2` per node)
- `ancibd_merge.sub` – merges per-batch outputs into `runs/<RUN_ID>/out/merged/` and writes `runs/<RUN_ID>/DONE`

All templates assume the pipeline is started from a configured repo checkout and that `config/local.env` is valid.

## Resource requests

The batchpair template (`ancibd_batchpair.sub`) uses per-node `VARS` from the DAG to set
`request_cpus/request_memory/request_disk`.

Defaults are derived from `BATCH_SIZE` in `config/local.env` (see `scripts/lib.sh`) and can
be overridden explicitly via:

- `BP_REQUEST_CPUS`, `BP_REQUEST_MEMORY`, `BP_REQUEST_DISK`

If jobs remain idle, check:

```bash
condor_q -better-analyze <clusterid>
```

and adjust either your requests or your slot sizing (static/partitionable slots).

## Shared filesystem assumption

The submit files set `should_transfer_files = NO` because this pipeline is designed
for a shared-filesystem cluster (all nodes see the same `RUNS_ROOT/HDF5_ROOT/DATA_ROOT`).
