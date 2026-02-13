HTCondor templates.

This directory contains the submit-description templates used by the top-level CLI.

Two patterns are included:

1) **Chromosome-parallel** (simple):
   - one job per chromosome (`ancibd_ch.sub`)
   - one summary job after all chrom jobs (`ancibd_summary.sub`)
   - DAGMan is used by `ancibd-pipeline run-chrom-dag`.

2) **Batchpair jobs** (preferred for scaling):
   - one job per *(batch_i, batch_j)* pair (`ancibd_batchpair.sub`)
   - each job runs all chromosomes in `CH_RANGE` and does its own summary
   - one merge job after all batchpair jobs (`ancibd_merge.sub`)
   - DAGMan is used by `ancibd-pipeline run-batch-dag`.

These templates assume a shared filesystem (repo + data + runs visible on execute node).

## Static DAG examples

The CLI generates per-run DAG directories under `runs/<RUN_ID>/condor/...`, copies the
relevant `.sub` templates there, and writes a DAG file next to them.

The following examples illustrate the intended DAG structure.

### Chromosome-parallel example (chr20 -> summary)

```dag
# Variables provided at submit time:
#   ROOT      : absolute path to repo root on shared FS
#   RUNS_ROOT : absolute runs root (matches config/local.env)
#   RUN_ID    : unique id (created before submission)

JOB CH20 ancibd_ch.sub
VARS CH20 ROOT="$(ROOT)" RUNS_ROOT="$(RUNS_ROOT)" RUN_ID="$(RUN_ID)" CH="20"

JOB SUM ancibd_summary.sub
VARS SUM ROOT="$(ROOT)" RUNS_ROOT="$(RUNS_ROOT)" RUN_ID="$(RUN_ID)" CH_RANGE="20-20"

PARENT CH20 CHILD SUM
```

### Batchpair example (batchpairs -> merge)

```dag
JOB BATCH ancibd_batchpair.sub
VARS BATCH ROOT="$(ROOT)" RUNS_ROOT="$(RUNS_ROOT)" RUN_ID="$(RUN_ID)" CH_RANGE="1-22"

JOB MERGE ancibd_merge.sub
VARS MERGE ROOT="$(ROOT)" RUNS_ROOT="$(RUNS_ROOT)" RUN_ID="$(RUN_ID)"

PARENT BATCH CHILD MERGE
```
