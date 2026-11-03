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
  KW_CHECK_VERSIONS_FILE     versions file to look up instead of <repo>/versions.yml
                             (kwisatz versions check passes the bundled pins merged
                             with the user's overrides)
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
cp "${KW_CHECK_VERSIONS_FILE:-${REPO_DIR}/versions.yml}" "$WORK/versions.yml"
cp "${REPO_DIR}/renovate.json" "$WORK/"
chmod -R a+rX "$WORK"

info "Looking up versions.yml with ${RENOVATE_IMAGE}" >&2
docker run --rm \
  -v "${WORK}:/usr/src/app:ro" -w /usr/src/app \
  -e LOG_LEVEL=debug -e LOG_FORMAT=json \
  -e RENOVATE_GITHUB_COM_TOKEN="$TOKEN" \
  "$RENOVATE_IMAGE" --platform=local --dry-run=lookup > "${WORK}/renovate.log" 2>&1 \
  || { tail -n 20 "${WORK}/renovate.log" >&2; error "renovate run failed"; }

python3 -I - "${WORK}/renovate.log" "$JSON" <<'PY'
import json, sys

log, as_json = sys.argv[1], sys.argv[2] == "true"
deps, problems = [], []
for line in open(log):
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if rec.get("level", 0) >= 40:
        problems.append(rec.get("msg", ""))
    if rec.get("msg") == "packageFiles with updates":
        for files in rec["config"].values():
            for f in files:
                if f.get("packageFile") == "versions.yml":
                    deps.extend(f["deps"])
for msg in problems:
    print(f"[WARN]  renovate: {msg}", file=sys.stderr)
if not deps:
    sys.exit("[ERROR] renovate reported no dependencies for versions.yml")
if as_json:
    json.dump(deps, sys.stdout, indent=2)
    print()
    sys.exit(0)
width = max(len(d["depName"]) for d in deps)
for d in sorted(deps, key=lambda d: d["depName"]):
    current = d.get("currentValue", "")
    if d.get("currentDigest"):
        current += f"@{d['currentDigest'][:12]}"
    if d.get("skipReason"):
        latest = f"(skipped: {d['skipReason']})"
    else:
        news = []
        for u in d.get("updates", []):
            new = u.get("newValue") or current
            if u.get("updateType") == "digest" or (u.get("newDigest") and new == d.get("currentValue")):
                new += f"@{u['newDigest'][:12]}"
            news.append(f"{new} ({u.get('updateType')})")
        latest = ", ".join(news) if news else "up to date"
    print(f"{d['depName']:<{width}}  {current}  →  {latest}")
PY
