# ancibd-pipeline

Reproducible ancIBD workflow harness using Apptainer + HTCondor:
- safe run directories (no overwrites by construction)
- wrapper scripts for per-chromosome runs + summary
- container recipe + provenance capture
- HTCondor submit files + DAGMan skeleton

## Core safety rules
1) Never write into `data/`. Treat it as immutable.
2) Every execution uses a unique `RUN_ID` under `runs/`.
3) A run is immutable once `runs/<RUN_ID>/DONE` exists.
4) Container binds `data/` read-only.

## Quickstart (local)
1) Copy config:
```bash
   cp config/example.env config/local.env
   # edit config/local.env
```

2) Build container:
```bash
   ./containers/build.sh
```

3) Create a new run id:
```bash
   ./scripts/new_run.sh demo
```

4) Run one chromosome:
```bash
   RUN_ID=... ./scripts/run_chrom.sh 20
```

5) Summary (for chr20 only):
```bash
   RUN_ID=... ./scripts/run_summary.sh 20-20
```
