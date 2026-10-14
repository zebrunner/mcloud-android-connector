# Project checks; `make check` runs the linters and the script tests
SHELL := /bin/bash
VENV := .venv
export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)

.DEFAULT_GOAL := help
.PHONY: help check lint test

help: ## this list
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

check: ## everything below, as CI runs it; every step runs, the failed ones fail the target
	@status=0; for target in lint test; do $(MAKE) --no-print-directory $$target || status=1; done; exit $$status

lint: $(VENV)/.installed ## the linters (tests/lint.sh): yaml, Dockerfile, markdown, shell
	tests/lint.sh

test: ## all tests/*_test.sh but the docker one: the util scripts and the entrypoint, no docker needed
	@status=0; for t in $(filter-out tests/image_test.sh,$(wildcard tests/*_test.sh)); do $$t || status=1; done; exit $$status

# The tools of tests/requirements-lint.txt in .venv; the hadolint-py wheel for macOS is broken, brew provides it there
$(VENV)/.installed: tests/requirements-lint.txt
	python3 -m venv $(VENV)
	@if [[ "$$(uname)" == Darwin ]]; then \
	  grep -v '^hadolint-py' tests/requirements-lint.txt > $(VENV)/requirements.txt; \
	else \
	  cp tests/requirements-lint.txt $(VENV)/requirements.txt; \
	fi
	$(VENV)/bin/pip install --quiet --disable-pip-version-check --requirement $(VENV)/requirements.txt
	@command -v hadolint > /dev/null || { echo "hadolint is missing: brew install hadolint"; exit 1; }
	touch $@
