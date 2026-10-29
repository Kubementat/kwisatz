#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-renovate.sh — Self-hosted Renovate against Forgejo (versions.yml bumps)
# =============================================================================
#
# Description:
#   Runs the Renovate image pinned in versions.yml on a systemd timer against
#   Forgejo repositories (default: denkfabrik/kwisatz). Renovate reads each
#   repository's renovate.json, keeps a Dependency Dashboard issue current and
#   opens bump PRs. Nothing is merged automatically.
#
#   Layout:
#     /srv/renovate/.env        RENOVATE_TOKEN, RENOVATE_GITHUB_COM_TOKEN (mode 600)
#     /srv/renovate/config.js   platform, endpoint, repositories (no secrets)
#     /srv/renovate/cache       Renovate's cache between runs
#     /etc/systemd/system/renovate.{service,timer}
#
# Environment Variables (optional):
#   RENOVATE_ENDPOINT          - Forgejo API URL, e.g. https://git.example.com/api/v1
#                                (required on the first run; read back from config.js)
#   RENOVATE_TOKEN             - PAT of the Forgejo bot account (required on the first
#                                run; read back from .env, never rotated)
#   RENOVATE_GITHUB_COM_TOKEN  - read-only GitHub token: changelogs, github-releases/-tags
#                                lookups, API rate limits (read back from .env)
#   RENOVATE_REPOSITORIES      - space-separated owner/repo list (default: denkfabrik/kwisatz;
#                                read back from config.js)
#   RENOVATE_SCHEDULE          - systemd OnCalendar expression (default: daily)
#   RENOVATE_IMAGE             - Renovate image (default: versions.yml key renovate)
#   RENOVATE_LOG_LEVEL         - Renovate log level (default: info)
#   RENOVATE_DIR               - Data directory (default: /srv/renovate)
#
# Usage:
#   RENOVATE_ENDPOINT=https://git.example.com/api/v1 RENOVATE_TOKEN=<pat> ./setup-renovate.sh
#   ./setup-renovate.sh             # re-run: converge with the stored settings
#   ./setup-renovate.sh --no-run    # install/converge without the verification run
#   ./setup-renovate.sh --help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/renovate")"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# =============================================================================
# Configuration
# =============================================================================

RENOVATE_DIR="${RENOVATE_DIR:-/srv/renovate}"
RENOVATE_SCHEDULE="${RENOVATE_SCHEDULE:-daily}"
RENOVATE_IMAGE="${RENOVATE_IMAGE:-$(kw_image renovate)}"
RENOVATE_LOG_LEVEL="${RENOVATE_LOG_LEVEL:-info}"
RENOVATE_ENDPOINT="${RENOVATE_ENDPOINT:-}"
RENOVATE_REPOSITORIES="${RENOVATE_REPOSITORIES:-}"
RENOVATE_TOKEN="${RENOVATE_TOKEN:-}"
RENOVATE_GITHUB_COM_TOKEN="${RENOVATE_GITHUB_COM_TOKEN:-}"

ENV_FILE="${RENOVATE_DIR}/.env"
CONFIG_FILE="${RENOVATE_DIR}/config.js"
CACHE_DIR="${RENOVATE_DIR}/cache"
# uid of the `ubuntu` user the renovate/renovate image runs as
RENOVATE_UID=12021
RUN_NOW=true

# =============================================================================
# Usage / help
# =============================================================================

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs a self-hosted Renovate that runs on a systemd timer against Forgejo:
it keeps the Dependency Dashboard issue current and opens bump PRs for the
pins in versions.yml (rules: the repository's renovate.json). Ends with one
run as verification and fails when that run fails.

${BOLD}Options:${RESET}
  --no-run       Install/converge only — skip the verification run
  -h, --help     Show this help and exit

${BOLD}Environment variables${RESET}:
  RENOVATE_ENDPOINT          Forgejo API URL, e.g. https://git.example.com/api/v1
                             (required on the first run; re-runs read it back
                             from ${CONFIG_FILE})
  RENOVATE_TOKEN             PAT of the Forgejo bot account — repository read/write,
                             issue read/write, user read (required on the first
                             run; stored in ${ENV_FILE}, mode 600, never rotated)
  RENOVATE_GITHUB_COM_TOKEN  Read-only GitHub token for changelogs, GitHub
                             lookups and rate limits (optional, stored in .env)
  RENOVATE_REPOSITORIES      Space-separated owner/repo list
                             (default: denkfabrik/kwisatz, or the stored list)
  RENOVATE_SCHEDULE          systemd OnCalendar expression (default: daily)
  RENOVATE_IMAGE             Renovate image (default: $(kw_image renovate))
  RENOVATE_LOG_LEVEL         Renovate log level (default: info)
  RENOVATE_DIR               Data directory (default: /srv/renovate)

${BOLD}After setup:${RESET}
  sudo systemctl start renovate.service   # run now
  journalctl -u renovate.service -f       # follow a run
  systemctl list-timers renovate.timer    # next scheduled run
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-run)  RUN_NOW=false ;;
    *) error "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

# =============================================================================
# Pre-flight
# =============================================================================

step "Running pre-flight checks"
command -v docker &>/dev/null || error "Docker is not installed. Run setup-docker.sh first."
command -v systemctl &>/dev/null || error "systemd is required (renovate.timer)."
command -v envsubst &>/dev/null || error "envsubst is missing — sudo apt-get install -y gettext-base"
DOCKER_BIN="$(command -v docker)"
success "docker, systemd and envsubst available"

# =============================================================================
# Settings: explicit env wins, else the stored value, else the default
# =============================================================================

step "Resolving settings"
sudo mkdir -p "${RENOVATE_DIR}"
sudo chown "$(id -un):$(id -gn)" "${RENOVATE_DIR}"
sudo mkdir -p "${CACHE_DIR}"
sudo chown "${RENOVATE_UID}:0" "${CACHE_DIR}"

if [[ -f "${CONFIG_FILE}" ]]; then
  [[ -n "${RENOVATE_ENDPOINT}" ]] \
    || RENOVATE_ENDPOINT="$(sed -n "s/^  endpoint: '\(.*\)',$/\1/p" "${CONFIG_FILE}")"
  [[ -n "${RENOVATE_REPOSITORIES}" ]] \
    || RENOVATE_REPOSITORIES="$(sed -n "s/^  repositories: '\(.*\)'\.split.*$/\1/p" "${CONFIG_FILE}")"
fi
RENOVATE_REPOSITORIES="${RENOVATE_REPOSITORIES:-denkfabrik/kwisatz}"
[[ -n "${RENOVATE_TOKEN}" ]] || RENOVATE_TOKEN="$(env_file_get "${ENV_FILE}" RENOVATE_TOKEN || true)"
[[ -n "${RENOVATE_GITHUB_COM_TOKEN}" ]] \
  || RENOVATE_GITHUB_COM_TOKEN="$(env_file_get "${ENV_FILE}" RENOVATE_GITHUB_COM_TOKEN || true)"

[[ "${RENOVATE_ENDPOINT}" =~ ^https?://[^[:space:]\']+$ ]] \
  || error "RENOVATE_ENDPOINT must be the Forgejo API URL, e.g. https://git.example.com/api/v1 (got '${RENOVATE_ENDPOINT}')"
[[ -n "${RENOVATE_TOKEN}" ]] \
  || error "RENOVATE_TOKEN is not set and not stored in ${ENV_FILE} — create a PAT for the Forgejo bot account (repository + issue read/write, user read) and pass it once"
for repo in ${RENOVATE_REPOSITORIES}; do
  [[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || error "RENOVATE_REPOSITORIES: '${repo}' is not owner/repo"
done
[[ -n "${RENOVATE_GITHUB_COM_TOKEN}" ]] \
  || warn "RENOVATE_GITHUB_COM_TOKEN is not set — GitHub-hosted entries of versions.yml are skipped (github-token-required)"
success "Endpoint ${RENOVATE_ENDPOINT}, repositories: ${RENOVATE_REPOSITORIES}"

# =============================================================================
# Files
# =============================================================================

step "Writing ${ENV_FILE} (secrets) and ${CONFIG_FILE}"
printf 'RENOVATE_TOKEN=%s\nRENOVATE_GITHUB_COM_TOKEN=%s\n' \
  "${RENOVATE_TOKEN}" "${RENOVATE_GITHUB_COM_TOKEN}" | env_file_write "${ENV_FILE}"

GENERATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
export GENERATED_DATE RENOVATE_DIR RENOVATE_ENDPOINT RENOVATE_REPOSITORIES \
  DOCKER_BIN RENOVATE_LOG_LEVEL RENOVATE_IMAGE RENOVATE_SCHEDULE

render() { # <template> <target> <mode> <vars>
  local tmp
  tmp="$(mktemp)"
  envsubst "$4" < "${TEMPLATE_DIR}/$1" > "${tmp}"
  sudo install -m "$3" "${tmp}" "$2"
  rm -f "${tmp}"
}
# shellcheck disable=SC2016  # envsubst takes the literal variable list
render config.js "${CONFIG_FILE}" 644 '${GENERATED_DATE} ${RENOVATE_DIR} ${RENOVATE_ENDPOINT} ${RENOVATE_REPOSITORIES}'
success "Config rendered"

step "Installing renovate.service and renovate.timer"
# shellcheck disable=SC2016
render renovate.service /etc/systemd/system/renovate.service 644 \
  '${DOCKER_BIN} ${RENOVATE_DIR} ${RENOVATE_LOG_LEVEL} ${RENOVATE_IMAGE}'
# shellcheck disable=SC2016
render renovate.timer /etc/systemd/system/renovate.timer 644 '${RENOVATE_SCHEDULE}'
sudo systemctl daemon-reload
sudo systemctl enable --now renovate.timer
systemctl is-active --quiet renovate.timer || error "renovate.timer is not active — systemctl status renovate.timer"
success "renovate.timer active (OnCalendar=${RENOVATE_SCHEDULE})"

step "Pulling ${RENOVATE_IMAGE}"
sudo docker pull -q "${RENOVATE_IMAGE}" >/dev/null
success "Image ready"

# =============================================================================
# Verification run
# =============================================================================

if [[ "${RUN_NOW}" == "true" ]]; then
  step "Verification run (renovate.service — this can take a few minutes)"
  if ! sudo systemctl start renovate.service; then
    sudo journalctl -u renovate.service -n 40 --no-pager >&2 || true
    error "The Renovate run failed — see the log above (journalctl -u renovate.service)"
  fi
  success "Renovate run finished — see the Dependency Dashboard issue in ${RENOVATE_REPOSITORIES}"
else
  info "Verification run skipped (--no-run): sudo systemctl start renovate.service"
fi

echo ""
echo -e "${BOLD}Renovate${RESET}"
echo -e "  Image      ${RENOVATE_IMAGE}"
echo -e "  Endpoint   ${RENOVATE_ENDPOINT}"
echo -e "  Repos      ${RENOVATE_REPOSITORIES}"
echo -e "  Next run   $(systemctl list-timers --no-legend renovate.timer 2>/dev/null | awk '{print $1" "$2" "$3}' | head -n1)"
echo -e "  Run now    sudo systemctl start renovate.service"
echo -e "  Logs       journalctl -u renovate.service"
