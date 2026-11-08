#!/usr/bin/env bash
# Runs from the fixture directory after `uv sync` and before the checks.
set -euo pipefail

psql -v ON_ERROR_STOP=1 -c 'CREATE SCHEMA IF NOT EXISTS app'
