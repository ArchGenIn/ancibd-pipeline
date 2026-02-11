SHELL := /bin/bash

.PHONY: build runid ch20 summary20 batches20 merge

build:
	./containers/build.sh

runid:
	./scripts/new_run.sh demo

# Example local demo targets (assumes RUN_ID is exported)
ch20:
	./scripts/run_chrom.sh 20

summary20:
	./scripts/run_summary.sh 20-20

# Batch demo (assumes RUN_ID is exported)
batches20:
	./scripts/run_all_batches_local.sh 20-20

merge:
	./scripts/merge_batch_outputs.sh
