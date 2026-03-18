# `scripts/tune_grid.sh`

`tune_grid.sh` is a short benchmarking helper for `prod`.

For each grid point it:

1. updates `config/local.env` with one `BATCH_SIZE` / `BP_MAXJOBS` pair
2. derives `BP_REQUEST_CPUS`, `BP_REQUEST_MEMORY`, and `BP_REQUEST_DISK` from the current Condor pool
3. creates a fresh `RUN_ID`
4. submits `./ancibd-pipeline prod ...`
5. waits `DURATION_SEC`
6. removes the DAG and child jobs
7. records progress in `runs/tuning/grid_<timestamp>.tsv`

The original `config/local.env` is restored on exit.

## Usage

```bash
./scripts/tune_grid.sh
CH_RANGE=2-2 PCOL=AF_REF DURATION_SEC=600 ./scripts/tune_grid.sh
./scripts/tune_grid.sh --help
```

## Defaults

- `CH_RANGE=2-2`
- `PCOL=AF_ALL`
- `DURATION_SEC=120`
- `SLEEP_AFTER_RM_SEC=10`
- `BATCH_SIZES=(100 300 500)`
- `MAXJOBS_LIST=(1 16 32)`

Edit `BATCH_SIZES` and `MAXJOBS_LIST` in the script to change the grid.

## Output columns

- `ts_utc`
- `batch_size`
- `bp_maxjobs`
- `jobs_per_node`
- `req_cpus`
- `req_mem_mb`
- `req_disk_mb`
- `run_id`
- `dag_cluster`
- `expected`
- `complete`
- `percent`
- `ch_range`
- `duration_sec`
