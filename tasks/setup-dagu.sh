#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-dagu.sh — Install Dagu workflow orchestrator
# =============================================================================
#
# Description:
#   Installs Dagu (self-hostable workflow orchestrator) using Docker Compose.
#   The host Docker socket is mounted so workflows can run container steps.
#   No Traefik integration — accessed via configurable bind address.
#
# Environment Variables (optional):
#   DAGU_DIR           - Installation directory (default: /srv/dagu)
#   DAGU_BIND_IP       - Bind address (default: 127.0.0.1)
#   DAGU_PORT          - Host port for the web UI (default: 8080)
#   DAGU_IMAGE         - Dagu image (default: versions.yml key dagu, pinned)
#   DAGU_TZ            - Timezone for Dagu (default: UTC)
#   DAGU_USERNAME      - Admin username (default: dagu)
#   DAGU_PASSWORD      - Admin password (default: auto-generated on first run)
#   WAIT_TIMEOUT       - Max seconds to wait for stack health (default: 120)
#
# Usage:
#   ./setup-dagu.sh
#   DAGU_PORT=9090 ./setup-dagu.sh
#   DAGU_USERNAME=admin DAGU_PASSWORD=s3cret ./setup-dagu.sh
#   ./setup-dagu.sh --help
# =============================================================================

set -euo pipefail

# Determine script directory and source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# =============================================================================
# USAGE / HELP
# =============================================================================

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs Dagu (workflow orchestrator) using Docker Compose.
The host Docker socket is mounted so workflows can run container steps.
No Traefik integration — accessed via configurable bind address.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  DAGU_DIR           Installation directory (default: /srv/dagu)
  DAGU_BIND_IP       Bind address (default: 127.0.0.1)
  DAGU_PORT          Host port for the web UI (default: 8080)
  DAGU_IMAGE         Dagu image (default: $(kw_image dagu),
                     pinned — override with an explicit version tag)
  DAGU_TZ            Timezone for Dagu (default: UTC)
  DAGU_USERNAME      Admin username (default: dagu)
  DAGU_PASSWORD      Admin password (default: auto-generated on first run;
                     on re-runs the existing password from ${DAGU_DIR:-/srv/dagu}/.env
                     is reused)
  WAIT_TIMEOUT       Max seconds to wait for the stack to become healthy
                     after 'docker compose up -d' (default: 120)

${BOLD}Security note:${RESET} The host Docker socket is mounted into the
container, granting workflows control of the host Docker daemon. Use only
for trusted workflows.

${BOLD}Re-run policy${RESET} (converge by default): re-running an existing stack
converges it — 'docker compose up -d' reconciles only what changed (no tear-down,
no silent skip). See specification/project/conventions.md.
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1 (see --help)"
      ;;
  esac
done

# =============================================================================
# Configuration
# =============================================================================

: "${DAGU_DIR:=/srv/dagu}"
: "${DAGU_BIND_IP:=127.0.0.1}"
: "${DAGU_PORT:=8080}"
: "${DAGU_TZ:=UTC}"
: "${DAGU_USERNAME:=dagu}"
: "${DAGU_PASSWORD:=-}"
: "${WAIT_TIMEOUT:=120}"
COMPOSE_FILE="${DAGU_DIR}/docker-compose.yml"
ENV_FILE="${DAGU_DIR}/.env"
DAGU_DATA_DIR="${DAGU_DIR}/data"

# Pinned image — the default lives in versions.yml (key dagu)
DAGU_IMAGE="${DAGU_IMAGE:-$(kw_image dagu)}"
warn_moving_image "${DAGU_IMAGE}" "DAGU_IMAGE"

command -v envsubst >/dev/null 2>&1 \
  || error "envsubst is not installed. Install with: sudo apt-get install gettext-base"
command -v openssl >/dev/null 2>&1 \
  || error "openssl is not installed. Install with: sudo apt-get install openssl"

# =============================================================================
# Main
# =============================================================================

step "Setting up Dagu workflow orchestrator"

# Pre-flight
if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run setup-docker.sh first."
fi

# Create workspace
step "Creating workspace at ${DAGU_DIR}"
sudo mkdir -p "${DAGU_DATA_DIR}"
success "Directories ready."

# Handle .env (secrets) — read back existing values so re-runs never rotate
# credentials the persisted volume depends on.
step "Configuring authentication"
if [[ -f "${ENV_FILE}" ]]; then
  _existing_user="$(env_file_get "${ENV_FILE}" "DAGU_AUTH_BUILTIN_INITIAL_ADMIN_USERNAME")" || true
  _existing_pass="$(env_file_get "${ENV_FILE}" "DAGU_AUTH_BUILTIN_INITIAL_ADMIN_PASSWORD")" || true

  if [[ -n "${_existing_pass}" ]]; then
    DAGU_PASSWORD="${_existing_pass}"
    info "Reusing existing credentials from ${ENV_FILE}"
    # If the user explicitly passed a different username, honour it.
    if [[ "${DAGU_USERNAME}" != "-" && "${DAGU_USERNAME}" != "${_existing_user}" ]]; then
      warn "Username changed from '${_existing_user}' to '${DAGU_USERNAME}' — this only affects new .env; the running server keeps the original admin."
    fi
  else
    # .env exists but has no password (shouldn't happen, but be safe)
    if [[ "${DAGU_PASSWORD}" == "-" ]]; then
      DAGU_PASSWORD="$(openssl rand -base64 18)"
      info "Generated new admin password"
    fi
  fi
else
  if [[ "${DAGU_PASSWORD}" == "-" ]]; then
    DAGU_PASSWORD="$(openssl rand -base64 18)"
    info "Generated new admin password"
  fi
fi

tmp_env="$(mktemp)"
cat > "${tmp_env}" <<EOF
DAGU_AUTH_BUILTIN_INITIAL_ADMIN_USERNAME=${DAGU_USERNAME}
DAGU_AUTH_BUILTIN_INITIAL_ADMIN_PASSWORD=${DAGU_PASSWORD}
EOF
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "${tmp_env}" "${ENV_FILE}"
rm -f "${tmp_env}"
success ".env written (${ENV_FILE})"

# Render docker-compose.yml from template. Only non-secret layout values are
# envsubst'ed; auth variables stay as literal ${...} and are resolved at
# runtime from .env via the env_file: directive in the compose file.
step "Creating docker-compose.yml"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/dagu"
tmp="$(mktempfile docker-compose.yml)"
export DAGU_IMAGE DAGU_BIND_IP DAGU_PORT DAGU_TZ DAGU_DATA_DIR
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${DAGU_IMAGE} ${DAGU_BIND_IP} ${DAGU_PORT} ${DAGU_TZ} ${DAGU_DATA_DIR}' < "${TEMPLATE_DIR}/docker-compose.yml" > "${tmp}"
sudo install -m 0644 "${tmp}" "${COMPOSE_FILE}"
rm -f "${tmp}"
success "docker-compose.yml written"

# Bring stack up
step "Starting Dagu"
docker compose -f "${COMPOSE_FILE}" up -d

# Health gate: prove the container is actually up before reporting success.
mapfile -t _ids < <(docker compose -f "${COMPOSE_FILE}" ps -q)
wait_for_healthy "${WAIT_TIMEOUT}" "${_ids[@]}" \
  || error "Dagu stack did not come up — see the status output above"

success "Dagu installed successfully"
info "Access at http://${DAGU_BIND_IP}:${DAGU_PORT}"
info "Login: ${DAGU_USERNAME} / (see ${ENV_FILE})"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "- Add .dagu.yml workflow files to ${DAGU_DATA_DIR}/dags/"
echo "- View logs: docker compose -f ${COMPOSE_FILE} logs -f"
echo "- Run a DAG: docker exec dagu dagu start <dag-name>"
echo ""
