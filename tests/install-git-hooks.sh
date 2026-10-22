#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tests/install-git-hooks.sh — install the versioned git hooks in tests/git-hooks
# =============================================================================
#
# Points git at this checkout's hooks directory with `core.hooksPath` instead of
# copying files into .git/hooks. One install therefore covers every `git worktree`
# of the repository (core.hooksPath lives in the shared config and a relative
# path resolves per work tree), and the hook logic stays reviewable because it is
# versioned in the repo.
#
# Currently installed:
#   pre-commit — lints the staged files (shellcheck / yamllint / jq / node --check
#                / ruff / hadolint) plus the repo guards tests/lint.sh, and blocks
#                the commit on failure. Escape hatch: KWISATZ_PRECOMMIT_SKIP=1.
#
# USAGE:
#   tests/install-git-hooks.sh             Install (idempotent)
#   tests/install-git-hooks.sh --status    Show what git currently uses
#   tests/install-git-hooks.sh --uninstall Clear core.hooksPath
#   tests/install-git-hooks.sh --help      This help
#
# EXIT CODES:
#   0 ok · 1 not a git repo / install failed · 2 usage error
# =============================================================================

set -euo pipefail

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

mode="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --status) mode="status" ;;
    --uninstall) mode="uninstall" ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${root}" ]]; then
  echo "error: run this inside a kwisatz git work tree" >&2
  exit 1
fi
cd "${root}"

current="$(git config --get core.hooksPath || true)"

case "${mode}" in
  status)
    if [[ "${current}" == "tests/git-hooks" ]]; then
      echo "core.hooksPath = ${current}  (kwisatz hooks installed)"
    elif [[ -n "${current}" ]]; then
      echo "core.hooksPath = ${current}  (NOT the kwisatz hooks — run tests/install-git-hooks.sh)"
    else
      echo "core.hooksPath is unset — git uses $(git rev-parse --git-common-dir)/hooks (kwisatz hooks NOT active)"
    fi
    exit 0
    ;;
  uninstall)
    if [[ "${current}" == "tests/git-hooks" ]]; then
      git config --unset core.hooksPath
      echo "removed core.hooksPath — git is back to $(git rev-parse --git-common-dir)/hooks"
    else
      echo "core.hooksPath = ${current:-<unset>} — nothing to remove"
    fi
    exit 0
    ;;
esac

if [[ ! -d tests/git-hooks ]]; then
  echo "error: tests/git-hooks not found in ${root}" >&2
  exit 1
fi

chmod +x tests/git-hooks/*

git config core.hooksPath tests/git-hooks

echo "installed: core.hooksPath = tests/git-hooks (shared by every work tree of this repo)"
for h in tests/git-hooks/*; do
  echo "  hook: ${h##*/}"
done
echo
echo "verify:  git config core.hooksPath"
echo "remove:  tests/install-git-hooks.sh --uninstall"
