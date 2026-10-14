# Project checks
SHELL := /bin/bash

.DEFAULT_GOAL := help
.PHONY: help test

help: ## this list
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

test: ## all tests/*_test.sh but the docker one: the util scripts and the entrypoint, no docker needed
	@status=0; for t in $(filter-out tests/image_test.sh,$(wildcard tests/*_test.sh)); do $$t || status=1; done; exit $$status
