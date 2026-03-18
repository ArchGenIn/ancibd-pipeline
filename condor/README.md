# HTCondor templates

This folder contains the submit templates used by `./ancibd-pipeline`:

- `ancibd_hdf5.sub`: one chromosome per HDF5 build job
- `ancibd_batchpair.sub`: one batchpair node in the `prod` DAG
- `ancibd_merge.sub`: final merge step in the `prod` DAG

`ancibd_batchpair.sub` receives its `request_cpus`, `request_memory`, and `request_disk` values from the config file through DAG `VARS` lines.

Set these explicitly in `config/local.env` for normal runs:

- `BP_REQUEST_CPUS`
- `BP_REQUEST_MEMORY`
- `BP_REQUEST_DISK`

`tune_grid.sh` rewrites the same keys temporarily for tuning sweeps.
