HTCondor templates.

Recommended pattern:
- one job per chromosome (ancibd_ch.sub)
- one summary job after all chrom jobs (ancibd_summary.sub)
- DAGMan (ancibd.dag) wires the dependency.

These templates assume a shared filesystem (repo + data + runs visible on execute node).
