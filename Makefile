SHELL := /bin/bash

.PHONY: build runid ch20 summary20

build:
	./containers/build.sh

runid:
	./scripts/new_run.sh demo

# Example local demo targets (assumes RUN_ID is exported)
ch20:
	./scripts/run_chrom.sh 20

summary20:
	./scripts/run_summary.sh 20-20
