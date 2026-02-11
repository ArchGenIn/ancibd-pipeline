HTCondor templates.

Two patterns are included:

1) **Chromosome-parallel demo** (simple):
   - one job per chromosome (`ancibd_ch.sub`)
   - one summary job after all chrom jobs (`ancibd_summary.sub`)
   - DAGMan (`ancibd.dag`) wires the dependency.

2) **Batchpair jobs** (preferred for scaling):
   - one job per *(batch_i, batch_j)* pair (`ancibd_batchpair.sub`)
   - each job runs all chromosomes in `CH_RANGE` and does its own summary
   - results go to `runs/<RUN_ID>/out/b000_b001/` etc.

These templates assume a shared filesystem (repo + data + runs visible on execute node).
