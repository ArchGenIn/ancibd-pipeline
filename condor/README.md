# HTCondor templates

This folder contains the minimal submit templates used by `./ancibd-pipeline`:

- `ancibd_hdf5.sub` – one job builds one chromosome HDF5 (used by `build-hdf5-condor`)
- `ancibd_batchpair.sub` – a submit file that queues all batchpairs from `runs/<RUN_ID>/meta/batchpairs.tsv`
- `ancibd_merge.sub` – merges per-batch outputs into `runs/<RUN_ID>/out/merged/` and writes `runs/<RUN_ID>/DONE`

All templates assume the pipeline is started from a configured repo checkout and that `config/local.env` is valid.
