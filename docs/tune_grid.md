# `scripts/tune_grid.sh`

`./scripts/tune_grid.sh` is a small benchmarking helper for the `prod` workflow.
It submits short-lived runs over a grid of `BATCH_SIZE` and `BP_MAXJOBS`
settings, samples progress after a fixed time budget, and writes one summary TSV
covering the whole sweep.

## What it does

For each grid point, the script:

1. updates `config/local.env` with the chosen `BATCH_SIZE` and `BP_MAXJOBS`
2. writes explicit `BP_REQUEST_CPUS`, `BP_REQUEST_MEMORY`, and
   `BP_REQUEST_DISK` values for that point
3. creates a fresh `RUN_ID`
4. submits `./ancibd-pipeline prod ...`
5. waits `DURATION_SEC`
6. removes the DAG and its child jobs
7. records progress in `runs/tuning/grid_<timestamp>.tsv`

The original `config/local.env` is restored automatically when the script exits.

## Why resource requests are rewritten

`BP_MAXJOBS` is only useful if the jobs can actually fit on the available
execute nodes. The script therefore inspects the current Condor pool with
`condor_status`, takes the minimum CPU, memory, and disk values across the
nodes it finds, applies configurable safety factors, and writes explicit job
requests for each grid point.

That keeps the comparison focused on throughput differences between the tested
settings instead of mixing them with incompatible request sizes.

## Usage

Run with the defaults encoded in the script:

```bash
./scripts/tune_grid.sh
```

Override the chromosome range, AF field, and time budget through environment
variables:

```bash
CH_RANGE=2-2 PCOL=AF_REF DURATION_SEC=600 ./scripts/tune_grid.sh
```

Show the built-in help:

```bash
./scripts/tune_grid.sh --help
```

## Default inputs

The script defaults to:

- `CH_RANGE=2-2`
- `PCOL=AF_ALL`
- `DURATION_SEC=120`
- `SLEEP_AFTER_RM_SEC=10`
- `BATCH_SIZES=(100 300 500)`
- `MAXJOBS_LIST=(1 16 32)`

Edit `BATCH_SIZES` and `MAXJOBS_LIST` in the script to change the grid.

## Output

The summary file is written under:

- `runs/tuning/grid_<timestamp>.tsv`

Columns:

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

`expected`, `complete`, and `percent` come from `scripts/check_batch_status.sh`
after the DAG has been stopped.

## Requirements

The helper expects:

- a configured `config/local.env`
- a working HTCondor installation
- `condor_status`, `condor_submit_dag`, `condor_q`, and `condor_rm`
- the same shared-filesystem assumptions as the normal `prod` workflow

## Notes

- The script is intended for comparative tuning runs, not full production runs.
- Each grid point writes into its own run directory, so the outputs remain
  inspectable after the sweep.
- The summary does not infer a “best” setting automatically; it records the raw
  observed progress so you can compare settings yourself.
