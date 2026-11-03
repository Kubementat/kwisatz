#!/usr/bin/env bash
# =============================================================================
# utilities/check-versions.sh — what in versions.yml is outdated?
# =============================================================================
# Runs the Renovate image pinned in versions.yml with --platform=local
# --dry-run=lookup against versions.yml + renovate.json of this working tree
# and prints one line per entry: `key  current → latest`. Opens nothing,
# pushes nothing; needs only docker.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/helpers.sh"

usage() {
  cat <<EOF
Usage: $0 [--json] [-h|--help]

Looks up every entry of versions.yml with the pinned Renovate image
($(kw_image renovate)) and prints the current and the newest version.

Options:
  --json        Print Renovate's per-dependency result as JSON instead of the table
  -h, --help    Show this help and exit

Environment:
  RENOVATE_IMAGE             Renovate image (default: from versions.yml)
  RENOVATE_GITHUB_COM_TOKEN  GitHub token for github-releases/-tags lookups and the
                             API rate limit (default: GITHUB_TOKEN, then
                             'gh auth token' if gh is logged in; without one the
                             GitHub entries show 'github-token-required')
EOF
}

JSON=false
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=true ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v docker > /dev/null || error "docker is required"
RENOVATE_IMAGE="${RENOVATE_IMAGE:-$(kw_image renovate)}"
TOKEN="${RENOVATE_GITHUB_COM_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$TOKEN" ]] && command -v gh > /dev/null; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi

# Renovate's local platform reads the files of its working directory; a copy keeps
# the run independent of git worktrees (whose .git points outside any mount).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "${REPO_DIR}/versions.yml" "${REPO_DIR}/renovate.json" "$WORK/"
chmod -R a+rX "$WORK"

# stderr: stdout carries only the report (or the --json document)
info "Looking up versions.yml with ${RENOVATE_IMAGE}" >&2
docker run --rm \
  -v "${WORK}:/usr/src/app:ro" -w /usr/src/app \
  -e LOG_LEVEL=debug -e LOG_FORMAT=json \
  -e RENOVATE_GITHUB_COM_TOKEN="$TOKEN" \
  "$RENOVATE_IMAGE" --platform=local --dry-run=lookup > "${WORK}/renovate.log" 2>&1 \
  || { tail -n 20 "${WORK}/renovate.log" >&2; error "renovate run failed"; }

report_args=("${WORK}/renovate.log")
[[ "$JSON" == true ]] && report_args+=(--json)
python3 -I "${SCRIPT_DIR}/renovate-report.py" "${report_args[@]}"
