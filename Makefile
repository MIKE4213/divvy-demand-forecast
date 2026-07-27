VENV   := .venv
PY     := $(VENV)/bin/python
PIP    := $(VENV)/bin/pip
DBT    := $(VENV)/bin/dbt
PYTHON ?= python3.12
MONTHS ?= 6

DBT_FLAGS := --profiles-dir . --project-dir .

.DEFAULT_GOAL := help

.PHONY: help setup ingest run test build docs preview clean reset

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

setup: ## create the venv and install pinned dependencies
	$(PYTHON) -m venv $(VENV)
	$(PIP) install --quiet --upgrade pip
	$(PIP) install --quiet -r requirements.txt
	@echo "ready. next: make all"

ingest: ## download recent Divvy months into raw.trips (MONTHS=6)
	$(PY) ingest/ingest.py --months $(MONTHS)

run: ## build the dbt models
	$(DBT) run $(DBT_FLAGS)

test: ## run schema tests and singular assertions
	$(DBT) test $(DBT_FLAGS)

build: run test ## run then test

all: ingest build preview ## the whole pipeline, end to end

docs: ## generate and serve the dbt lineage docs
	$(DBT) docs generate $(DBT_FLAGS)
	$(DBT) docs serve $(DBT_FLAGS)

preview: ## print the next 7 days of forecast peak hours
	@$(PY) scripts/preview.py

clean: ## drop dbt artifacts
	$(DBT) clean $(DBT_FLAGS) || true
	rm -rf target dbt_packages logs

reset: clean ## also drop the database
	rm -f divvy.duckdb
