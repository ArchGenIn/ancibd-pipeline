# HTCondor templates

This folder contains the minimal submit templates used by `./ancibd-pipeline`:

- `ancibd_hdf5.sub` – one job builds one chromosome HDF5 (used by `build-hdf5-condor`)
- `ancibd_batchpair.sub` – a submit file that queues all batchpairs from `runs/<RUN_ID>/meta/batchpairs.tsv`
- `ancibd_merge.sub` – merges per-batch outputs into `runs/<RUN_ID>/out/merged/` and writes `runs/<RUN_ID>/DONE`

All templates assume the pipeline is started from a configured repo checkout and that `config/local.env` is valid.

## Resource requests

The `request_cpus/memory/disk` values are tuned for the **local cloud emulator** defaults
documented in `docs/local_cloud_emulation.md` (2 vCPU / 8 GB execute VMs with StaticSlots).

If your jobs remain idle in the emulator, check:

```bash
condor_q -better-analyze <clusterid>
```

and adjust the requests in the `.sub` files (or your slot sizing).

## Shared filesystem assumption

The submit files set `should_transfer_files = NO` because this pipeline is designed
for a shared-filesystem cluster (all nodes see the same `RUNS_ROOT/HDF5_ROOT/DATA_ROOT`).
