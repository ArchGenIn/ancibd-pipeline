# ancibd-pipeline

Reproducible ancIBD pipeline using Apptainer + HTCondor:
- safe run directories (no overwrites by construction)
- wrapper scripts for per-chromosome runs + summary
- scalable batch-pair mode via `--iid/--pair` (local driver + HTCondor submit)
- merge step to assemble per-batch outputs into `out/merged/`
- result-comparison helper for regression checks (baseline vs batch runs)
- container recipe + provenance capture
- HTCondor submit files + DAGMan skeleton

## Core safety rules
1) Never write into `data/`. Treat it as immutable.
2) Every execution uses a unique `RUN_ID` under `runs/`.
3) A run is immutable once `runs/<RUN_ID>/DONE` exists.
4) Container binds `data/` read-only.

## Prep

1) Copy config:
```bash
cp config/example.env config/local.env
# edit config/local.env
```

`config/local.env` is intentionally untracked (machine-specific paths); `config/example.env` is the committed template.

2) Build image (once per machine):
```bash
./containers/build.sh
```

## Top-level CLI (recommended)

Assumes you completed **Prep**.

All workflows are available via a single wrapper command at repo root:

```bash
./ancibd-pipeline --help
```

The CLI currently exposes these modes:

```bash
# Stand-alone, one run per chromosome in CH_RANGE
RUN_ID="$(./scripts/new_run.sh demo)"; export RUN_ID
./ancibd-pipeline run-chrom 20-20

# After per-chromosome runs finished, generate summary
./ancibd-pipeline run-chrom 20-20 --summarize

# HTCondor, one job per chromosome in CH_RANGE (submits condor/ancibd_ch.sub)
RUN_ID="$(./scripts/new_run.sh demo_condor)"; export RUN_ID
./ancibd-pipeline run-chrom-condor 20-20

# After per-chromosome jobs finished, submit summary (submits condor/ancibd_summary.sub)
./ancibd-pipeline run-chrom-condor 20-20 --summarize

# HTCondor DAGMan, one job per chromosome in CH_RANGE, then summary
RUN_ID="$(./scripts/new_run.sh demo_dag)"; export RUN_ID
./ancibd-pipeline run-chrom-dag 20-20

# Stand-alone, batchpairs + merge
RUN_ID="$(./scripts/new_run.sh demo_batches)"; export RUN_ID
./ancibd-pipeline run-batch 20-20

# HTCondor, batchpairs (submits condor/ancibd_batchpair.sub)
RUN_ID="$(./scripts/new_run.sh demo_batch_condor)"; export RUN_ID
./ancibd-pipeline run-batch-condor 20-20

# After batchpair jobs finished, submit merge job (submits condor/ancibd_merge.sub)
./ancibd-pipeline run-batch-condor 20-20 --merge

# HTCondor DAGMan, batchpair jobs for CH_RANGE, then merge
RUN_ID="$(./scripts/new_run.sh demo_batch_dag)"; export RUN_ID
./ancibd-pipeline run-batch-dag 20-20

# Check batchpair progress / list missing pairs (useful for reruns)
./ancibd-pipeline check-batch
```

## Quickstart (local)

Assumes you completed **Prep**.

1) Create a new run directory and export the run id:
```bash
RUN_ID="$(./scripts/new_run.sh demo)"
export RUN_ID
```

2) Run one chromosome (e.g. **chr20**):
```bash
./scripts/run_chrom.sh 20
```

3) Summary (for **chr20** only):
```bash
./scripts/run_summary.sh 20-20
```

Expected outputs:
- `runs/<RUN_ID>/out/ibd_ind.tsv`
- `runs/<RUN_ID>/out/ch_all.tsv`

## HTCondor quickstart (local)

### Run one chromosome job and the summary job via `condor_submit`

Assumes you completed **Prep**.

1) Sanity: Condor is alive and you have local slots:
```bash
condor_status | head
```

2) Create a new run directory and export the run id:
```bash
RUN_ID="$(./scripts/new_run.sh demo_condor)"
export RUN_ID
```

3) Submit **chr20**:
```bash
ROOT="$(pwd)"
# If your config/local.env uses $(pwd), source it from repo root:
source config/local.env

condor_submit \
  -append "ROOT=$ROOT" \
  -append "RUNS_ROOT=$RUNS_ROOT" \
  -append "RUN_ID=$RUN_ID" \
  -append "CH=20" \
  condor/ancibd_ch.sub
```

4) Watch it:
```bash
condor_q
tail -f "$RUNS_ROOT/$RUN_ID/logs/condor_ch20.err"
```

`tail -f` follows the file indefinitely; press **Ctrl+C** to stop following. Alternative:
```bash
less +F "$RUNS_ROOT/$RUN_ID/logs/condor_ch20.err"   # Ctrl+C stops follow; q quits
```

5) Inspect results/logs:
```bash
ls -lah "$RUNS_ROOT/$RUN_ID/work" "$RUNS_ROOT/$RUN_ID/logs"
```

6) Once **chr20** finished and produced the `...ch20.tsv`:
```bash
condor_submit \
  -append "ROOT=$ROOT" \
  -append "RUNS_ROOT=$RUNS_ROOT" \
  -append "RUN_ID=$RUN_ID" \
  -append "CH_RANGE=20-20" \
  condor/ancibd_summary.sub
```

7) Then check:
```bash
tail -f "$RUNS_ROOT/$RUN_ID/logs/condor_summary.err"
ls -lah "$RUNS_ROOT/$RUN_ID/out"
```

Note: HTCondor `arguments = ...` is not bash parsing. Prefer the “new syntax” (outer double quotes, inner single quotes), otherwise any double quotes inside `arguments` must be escaped.

### Try the DAG (chrom job(s) → summary)

Assumes you completed **Prep**.

DAGMan writes a few extra files (`*.dagman.log`, `*.nodes.log`, etc.). To keep them out of your repo root, run the DAG from a per-run folder.

1) Create a per-run DAG directory and make a run-specific DAG file:
```bash
RUN_ID="$(./scripts/new_run.sh demo_dag)"
export RUN_ID

ROOT="$(pwd)"
source config/local.env

DAG_DIR="$RUNS_ROOT/$RUN_ID/condor"
mkdir -p "$DAG_DIR"
cp condor/ancibd_ch.sub condor/ancibd_summary.sub "$DAG_DIR/"

cat > "$DAG_DIR/run.dag" << EOF
JOB CH20 $DAG_DIR/ancibd_ch.sub
VARS CH20 ROOT="$ROOT" RUNS_ROOT="$RUNS_ROOT" RUN_ID="$RUN_ID" CH="20"

JOB SUM $DAG_DIR/ancibd_summary.sub
VARS SUM ROOT="$ROOT" RUNS_ROOT="$RUNS_ROOT" RUN_ID="$RUN_ID" CH_RANGE="20-20"

PARENT CH20 CHILD SUM
EOF
```

2) Submit the DAG (from that directory so the DAGMan logs land there):
```bash
cd "$DAG_DIR"
condor_submit_dag run.dag
```

3) Monitor:
```bash
condor_q
tail -f run.dag.dagman.out
```

You should see `CH20` run first, and then `SUM`.

## Scaling idea: batches via --iid/--pair

For large cohorts, memory scales roughly linearly with the number of individuals
loaded into ancIBD at once. ancIBD exposes two useful knobs:

- `--iid`: limits which individuals get loaded into memory
- `--pair`: limits which pairs are actually evaluated

The approach implemented here is:

1) Split the global IID list into batches of size `BATCH_SIZE`.
2) For each batch pair `(b1, b2)` with `b1 <= b2`, run ancIBD on:
   - `--iid` = union of the two batches (preload set)
   - `--pair` = all pairs between the two batches (or within-batch combinations when `b1==b2`)
3) Concatenate all per-batch summaries to get the full-cohort summary.

This avoids loading *all* individuals in one job, while still covering all pairs.

Each batch-pair writes to its own output folder; a single merge step concatenates results (no concurrent appends, no per-pair file explosion).

### Batch quickstart (local)

Assumes you completed **Prep**.

```bash
RUN_ID="$(./scripts/new_run.sh demo_batches)"
export RUN_ID

# Optional: extract global IID list once
./scripts/make_iid_list.sh

# Run all batch pairs (for the tutorial dataset, this will typically be a single batch)
./scripts/run_all_batches_local.sh 20-20

# Merged outputs will be written to:
#   runs/<RUN_ID>/out/merged/{ch_all.tsv,ibd_ind.tsv}
```

### HTCondor batch quickstart (local)

Assumes you completed **Prep**.

```bash
RUN_ID="$(./scripts/new_run.sh demo_batch_condor)"
export RUN_ID

ROOT="$(pwd)"
source config/local.env

# Optional
./scripts/make_iid_list.sh

./scripts/make_batchpairs.sh

condor_submit \
  -append "ROOT=$ROOT" \
  -append "RUNS_ROOT=$RUNS_ROOT" \
  -append "RUN_ID=$RUN_ID" \
  -append "CH_RANGE=${CH_RANGE:-20-20}" \
  condor/ancibd_batchpair.sub

# After all batchpair jobs finished, merge per-batch outputs into out/merged/:
condor_submit \
  -append "ROOT=$ROOT" \
  -append "RUNS_ROOT=$RUNS_ROOT" \
  -append "RUN_ID=$RUN_ID" \
  condor/ancibd_merge.sub

# Merged outputs will be written to:
#   runs/<RUN_ID>/out/merged/{ch_all.tsv,ibd_ind.tsv}
```

## Result comparison

To compare two ancIBD summary output folders (order-insensitive):

```bash
./scripts/compare_outputs.sh \
  "$RUNS_ROOT/<RUN_ID_A>/out" \
  "$RUNS_ROOT/<RUN_ID_B>/out/merged"
```

### Determinism note (AF_ALL vs RAF)

ancIBD can store allele frequencies inside the HDF5. If you rely on a frequency column computed from the *samples contained in the HDF5* (often `variants/AF_ALL`), you can accidentally introduce sample-dependent behaviour when comparing runs.

If your HDF5 contains a reference allele frequency column (e.g. `variants/RAF`), prefer using that consistently for production runs: set `RAF_COL=variants/RAF` in `config/local.env` (see `RAF_COL` in `config/example.env`) so runs use a stable `--p_col`.
