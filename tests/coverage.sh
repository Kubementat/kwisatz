#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tests/coverage.sh — make the CLI's own coverage visible
# =============================================================================
#
# Why this exists: every CLI test spawns a subprocess, so a plain `pytest --cov`
# reports `cli.py 0 %` — the parent process never executes it. That number is
# worse than no number, because it reads like a hole in the suite while the real
# hole is invisible: nobody can say whether "100 % of plan.py / config.py /
# jsonio.py / exec.py public functions" (R-TEST-001) is true or false.
#
# How it works: `uv run --with coverage` layers coverage over the project venv,
# so nothing is added to pyproject/uv.lock, and
# `tests/coverage/sitecustomize.py` starts it inside every child python.
# `run_cli()` forwards COVERAGE_PROCESS_START for exactly that; a normal
# `uv run pytest` sets nothing and its minimal environment is untouched.
#
# Usage:
#   bash tests/coverage.sh                     # unit suite + per-module report
#   bash tests/coverage.sh --fail-under 95     # and fail the run below that bar
#   bash tests/coverage.sh tests/unit/test_plan.py
#
# What the report is good for: seeing which module the suite cannot reach. What
# it is not good for: proving the CLI is correct — the subprocess tests assert
# exit codes and documents, which no line count can substitute for. The verdict
# and the measured numbers are in docs/research/2026-10-23-kwisatz-cli-coverage.md.
# =============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$PWD"

fail_under=""
pytest_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fail-under)
      fail_under="${2:-}"
      if [[ -z "$fail_under" ]]; then
        echo "FAIL: --fail-under needs a number" >&2
        exit 2
      fi
      shift 2
      ;;
    --fail-under=*)
      fail_under="${1#*=}"
      shift
      ;;
    -h | --help)
      cat <<'USAGE'
usage: bash tests/coverage.sh [pytest args…] [--fail-under N]

Runs the unit suite with coverage measured inside every child process, combines the
part files, and prints the per-module report. `coverage` is fetched by uv into an
overlay for the length of the run, so nothing is added to pyproject.toml or
uv.lock. See the header of this script for why the plain `pytest --cov` number lies
and what the report is and is not good for.
USAGE
      exit 0
      ;;
    *)
      pytest_args+=("$1")
      shift
      ;;
  esac
done

data="$root/.coverage"
rm -f "$data" "$data".*

export COVERAGE_PROCESS_START="$root/tests/coverage/py.coveragerc"
export COVERAGE_FILE="$data"
export KWISATZ_COVERAGE_SITE="$root/tests/coverage"
export PYTHONPATH="$root/src:$root/tests/coverage${PYTHONPATH:+:$PYTHONPATH}"

# the parent process is measured too (its own sitecustomize starts it), so `combine`
# sees both halves of the suite: the in-process unit tests and the subprocess runs.
echo "── running the unit suite with subprocess coverage ──"
uv run --with coverage --no-sync python -m pytest tests/unit "${pytest_args[@]}"

echo
echo "── combining the part files ──"
uv run --with coverage --no-sync python -m coverage combine
if [[ -n "$fail_under" ]]; then
  uv run --with coverage --no-sync python -m coverage report --fail-under="$fail_under"
else
  uv run --with coverage --no-sync python -m coverage report
fi
