#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-kestra.sh — Install Kestra workflow orchestrator
# =============================================================================
#
# Description:
#   Installs Kestra (workflow & orchestration platform) in standalone mode
#   using Docker Compose, with a dedicated PostgreSQL backend.
#   The host Docker socket is mounted so Kestra's docker script tasks can
#   run containers.
#
#   Two access modes:
#   - direct   : web UI bound to KESTRA_BIND_IP:KESTRA_PORT (default mode)
#   - traefik  : routed via Traefik on KESTRA_DOMAIN with TLS (opt-in)
#
# Environment Variables (optional):
#   KESTRA_DIR           - Installation directory (default: /srv/kestra)
#   KESTRA_BIND_IP       - Bind address, direct mode (default: 127.0.0.1)
#   KESTRA_PORT          - Host port for the web UI (default: 8084)
#   KESTRA_IMAGE         - Kestra image (default: versions.yml key kestra, pinned)
#   POSTGRES_IMAGE       - PostgreSQL image (default: versions.yml key kestra-postgres, pinned —
#                          see the Kestra docs on the 16/17 data-dir issue)
#   KESTRA_USERNAME      - Web UI basic-auth username, must be a mail address
#                          (default: admin@example.com)
#   KESTRA_PASSWORD      - Web UI basic-auth password (default: auto-generated
#                          on first run, then reused from .env — never rotated)
#   POSTGRES_PASSWORD    - Postgres password (default: auto-generated on first
#                          run, then reused from .env — never rotated)
#   KESTRA_TRAEFIK       - Set to "true" to enable Traefik routing (default: false)
#   KESTRA_DOMAIN        - Domain for Traefik access (required when KESTRA_TRAEFIK=true)
#   PROXY_NETWORK        - Traefik's external Docker network name (default: proxy)
#   WAIT_TIMEOUT         - Max seconds to wait for stack health (default: 180)
#
# Usage:
#   ./setup-kestra.sh
#   KESTRA_PORT=9090 ./setup-kestra.sh
#   KESTRA_TRAEFIK=true KESTRA_DOMAIN=kestra.example.com ./setup-kestra.sh
#   ./setup-kestra.sh --help
# =============================================================================

set -euo pipefail

# Determine script directory and source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/kestra"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# =============================================================================
# CLEANUP TRAP — handles partial failures
# =============================================================================

# Set to 1 immediately BEFORE 'up -d' and reset to 0 once the stack is proven
# healthy. The trap tears the stack down only while this flag is set, so a
# late failure cannot stop a stack that was already running before this run.
STACK_CREATED_THIS_RUN=0

cleanup_on_failure() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  if (( STACK_CREATED_THIS_RUN != 1 )); then
    warn "Setup failed (exit code: ${exit_code}). No stack was started by this run — nothing torn down."
    return 0
  fi
  echo ""
  warn "Setup failed (exit code: ${exit_code})! Removing the stack created by this run..."
  if [[ -f "${COMPOSE_FILE:-}" ]]; then
    if [[ -n "$(docker compose -f "${COMPOSE_FILE}" ps -q 2>/dev/null || true)" ]]; then
      docker compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
      info "Removed partially created stack. Volumes are preserved."
    else
      info "Stack from this run is already stopped — volume data is preserved."
    fi
  fi
}

trap cleanup_on_failure EXIT

# =============================================================================
# USAGE / HELP
# =============================================================================

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs Kestra (workflow orchestrator) in standalone mode using Docker
Compose, with a dedicated PostgreSQL backend. The host Docker socket is
mounted so Kestra's docker script tasks can run containers.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  KESTRA_DIR           Installation directory (default: /srv/kestra)
  KESTRA_BIND_IP       Bind address, direct mode (default: 127.0.0.1)
  KESTRA_PORT          Host port for the web UI (default: 8084)
  KESTRA_IMAGE         Kestra image (default: $(kw_image kestra), pinned —
                       override with an explicit version tag)
  POSTGRES_IMAGE       PostgreSQL image (default: $(kw_image kestra-postgres), pinned — the
                       Kestra docs warn about data-dir incompatibility when
                       moving between major Postgres versions)
  KESTRA_USERNAME      Web UI basic-auth username, must be a mail address
                       (default: admin@example.com)
  KESTRA_PASSWORD      Web UI basic-auth password (default: auto-generated on
                       first run; on re-runs the existing password from
                       ${KESTRA_DIR:-/srv/kestra}/.env is reused — never rotated)
  POSTGRES_PASSWORD    Postgres password (default: auto-generated on first
                       run; on re-runs the existing password is reused —
                       never rotated)
  KESTRA_TRAEFIK       Set to "true" to enable Traefik routing (default: false)
  KESTRA_DOMAIN        Domain for Traefik access (required when
                       KESTRA_TRAEFIK=true)
  PROXY_NETWORK        Traefik's external Docker network name (default: proxy)
  WAIT_TIMEOUT         Max seconds to wait for the stack to become healthy
                       after 'docker compose up -d' (default: 180)

${BOLD}Security note:${RESET} The host Docker socket is mounted into the
Kestra container, granting Kestra workflows control of the host Docker
daemon. Use only for trusted workflows.

${BOLD}Re-run policy${RESET} (converge by default): re-running an existing
stack converges it — templates are re-rendered, stored secrets are reused
(never rotated), 'docker compose up -d' reconciles only what changed (no
tear-down). See specification/project/conventions.md.
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

: "${KESTRA_DIR:=/srv/kestra}"
: "${KESTRA_BIND_IP:=127.0.0.1}"
: "${KESTRA_PORT:=8084}"
: "${KESTRA_USERNAME:=admin@example.com}"
: "${KESTRA_PASSWORD:=-}"
: "${POSTGRES_PASSWORD:=-}"
: "${KESTRA_TRAEFIK:=false}"
: "${KESTRA_DOMAIN:=-}"
: "${PROXY_NETWORK:=proxy}"
: "${WAIT_TIMEOUT:=180}"
COMPOSE_FILE="${KESTRA_DIR}/docker-compose.yml"
ENV_FILE="${KESTRA_DIR}/.env"
KESTRA_WD_DIR="${KESTRA_DIR}/wd"

# Pinned images. Kestra publishes immutable v<X.X.X> tags and recommends them
# for locked-down production (rolling: latest, latest-lts — avoid via the
# warn_moving_image check). The defaults live in versions.yml.
KESTRA_IMAGE="${KESTRA_IMAGE:-$(kw_image kestra)}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-$(kw_image kestra-postgres)}"
warn_moving_image "${KESTRA_IMAGE}" "KESTRA_IMAGE"
warn_moving_image "${POSTGRES_IMAGE}" "POSTGRES_IMAGE"

command -v envsubst >/dev/null 2>&1 \
  || error "envsubst is not installed. Install with: sudo apt-get install gettext-base"
command -v openssl >/dev/null 2>&1 \
  || error "openssl is not installed. Install with: sudo apt-get install openssl"
command -v curl >/dev/null 2>&1 \
  || error "curl is not installed. Install with: sudo apt-get install curl"

# =============================================================================
# Main
# =============================================================================

step "Setting up Kestra workflow orchestrator"

# Pre-flight
if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run setup-docker.sh first."
fi
if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi

# Traefik pre-flight (only when opt-in)
if [[ "${KESTRA_TRAEFIK}" == "true" ]]; then
  if [[ "${KESTRA_DOMAIN}" == "-" || -z "${KESTRA_DOMAIN}" ]]; then
    error "KESTRA_DOMAIN must be set when KESTRA_TRAEFIK=true."
  fi
  ensure_proxy_network
else
  # Direct mode: refuse to take a port another service already holds.
  # A re-run is not a conflict: tolerate the port being held by our own
  # `kestra` container (the converge path brings the stack up again).
  if ss -tln 2>/dev/null | grep -qE "[:.]${KESTRA_PORT}[[:space:]]" || \
     netstat -tln 2>/dev/null | grep -q ":${KESTRA_PORT} "; then
    if docker ps --filter name='^kestra$' --format '{{.Names}}' 2>/dev/null | grep -qx kestra; then
      info "Port ${KESTRA_PORT} is held by our own kestra container — re-run, converging."
    else
      error "Port ${KESTRA_PORT} is already in use. Choose a different KESTRA_PORT."
    fi
  fi
fi

# Create workspace
step "Creating workspace at ${KESTRA_DIR}"
sudo mkdir -p "${KESTRA_DIR}" "${KESTRA_WD_DIR}"
sudo chown "$(id -un):$(id -gn)" "${KESTRA_DIR}" "${KESTRA_WD_DIR}"
success "Directories ready."

# Handle .env (secrets) — read back existing values so re-runs never rotate
# credentials the Postgres volume or the web UI depends on.
step "Configuring credentials"
if [[ -f "${ENV_FILE}" ]]; then
  _existing_user="$(env_file_get "${ENV_FILE}" "KESTRA_USERNAME" || true)"
  _existing_ui_pass="$(env_file_get "${ENV_FILE}" "KESTRA_PASSWORD" || true)"
  _existing_db_pass="$(env_file_get "${ENV_FILE}" "POSTGRES_PASSWORD" || true)"

  if [[ -n "${_existing_db_pass}" ]]; then
    POSTGRES_PASSWORD="${_existing_db_pass}"
    info "Reusing POSTGRES_PASSWORD from ${ENV_FILE}"
  fi
  if [[ -n "${_existing_ui_pass}" ]]; then
    KESTRA_PASSWORD="${_existing_ui_pass}"
    info "Reusing KESTRA_PASSWORD from ${ENV_FILE}"
  fi
  if [[ -n "${_existing_user}" && "${KESTRA_USERNAME}" != "${_existing_user}" ]]; then
    warn "Username changed from '${_existing_user}' to '${KESTRA_USERNAME}' — only new .env is affected."
  fi
else
  info "No existing .env found — generating credentials on first run."
fi

if [[ "${KESTRA_PASSWORD}" == "-" ]]; then
  KESTRA_PASSWORD="$(openssl rand -base64 18)"
  info "Generated new web UI password"
fi
if [[ "${POSTGRES_PASSWORD}" == "-" ]]; then
  POSTGRES_PASSWORD="$(openssl rand -base64 18)"
  info "Generated new Postgres password"
fi

# Render .env from template. Back up the existing .env ONLY when the content
# actually changes, so a no-op re-run never clobbers a good backup.
tmp_env="$(mktempfile .env)"
export KESTRA_USERNAME KESTRA_PASSWORD POSTGRES_PASSWORD
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${KESTRA_USERNAME} ${KESTRA_PASSWORD} ${POSTGRES_PASSWORD}' < "${TEMPLATE_DIR}/env.template" > "${tmp_env}"
if [[ -f "${ENV_FILE}" ]] && ! cmp -s "${tmp_env}" "${ENV_FILE}"; then
  warn "Existing .env changed — backing up to ${ENV_FILE}.bak"
  cp "${ENV_FILE}" "${ENV_FILE}.bak"
fi
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "${tmp_env}" "${ENV_FILE}"
rm -f "${tmp_env}"
success ".env written (${ENV_FILE})"

# Render docker-compose.yml from the matching template variant. Only
# non-secret layout values are envsubst'ed; secrets stay literal and are
# resolved by docker compose from .env at runtime (--env-file).
step "Creating docker-compose.yml"
if [[ "${KESTRA_TRAEFIK}" == "true" ]]; then
  COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.traefik.yml"
  KESTRA_URL="https://${KESTRA_DOMAIN}/"
else
  COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.direct.yml"
  KESTRA_URL="http://${KESTRA_BIND_IP}:${KESTRA_PORT}/"
fi

tmp="$(mktempfile docker-compose.yml)"
GENERATED_DATE="$(date -Iseconds)"
export KESTRA_IMAGE POSTGRES_IMAGE KESTRA_BIND_IP KESTRA_PORT PROXY_NETWORK \
       KESTRA_DOMAIN KESTRA_URL KESTRA_WD_DIR GENERATED_DATE
# shellcheck disable=SC2016  # envsubst expects the literal variable list;
# KESTRA_PASSWORD / POSTGRES_PASSWORD stay LITERAL on purpose — docker compose
# resolves them from ${KESTRA_DIR}/.env at runtime.
envsubst '${GENERATED_DATE} ${KESTRA_IMAGE} ${POSTGRES_IMAGE} ${KESTRA_BIND_IP} ${KESTRA_PORT} ${PROXY_NETWORK} ${KESTRA_DOMAIN} ${KESTRA_URL} ${KESTRA_WD_DIR}' \
  < "${COMPOSE_TEMPLATE}" > "${tmp}"
sudo install -m 0644 "${tmp}" "${COMPOSE_FILE}"
rm -f "${tmp}"
success "docker-compose.yml written"

# Pull images
step "Pulling Docker images"
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" pull
success "Images pulled."

# Bring stack up
step "Starting Kestra"
STACK_CREATED_THIS_RUN=1
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d

# Health gate: prove the containers are actually up before reporting success.
# Postgres carries a pg_isready healthcheck; Kestra counts as ready once
# running (slow JVM start), proven HTTP-ready below in direct mode.
mapfile -t _ids < <(docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" ps -q)
wait_for_healthy "${WAIT_TIMEOUT}" "${_ids[@]}" \
  || error "Kestra stack did not come up — see the status output above"
STACK_CREATED_THIS_RUN=0

# HTTP readiness poll (direct mode only — traefik mode needs DNS/TLS first)
if [[ "${KESTRA_TRAEFIK}" != "true" ]]; then
  step "Waiting for the Kestra web UI to respond"
  _elapsed=0; _interval=5; _ready=false
  while (( _elapsed < WAIT_TIMEOUT )); do
    _code="$(curl -s -o /dev/null -w '%{http_code}' "http://${KESTRA_BIND_IP}:${KESTRA_PORT}/ui/login" || true)"
    if [[ "${_code}" =~ ^(200|302|303)$ ]]; then
      _ready=true
      break
    fi
    echo -ne "\r    Waited ${_elapsed}s / ${WAIT_TIMEOUT}s ..."
    sleep "${_interval}"; _elapsed=$(( _elapsed + _interval ))
  done
  echo ""
  if [[ "${_ready}" != "true" ]]; then
    error "Kestra web UI did not respond at http://${KESTRA_BIND_IP}:${KESTRA_PORT}/ui/login within ${WAIT_TIMEOUT}s — check: docker compose -f ${COMPOSE_FILE} logs kestra"
  fi
  success "Kestra web UI is responding."
else
  info "Traefik mode: skipping direct HTTP check (access at https://${KESTRA_DOMAIN} once DNS/TLS are provisioned)."
fi

# Disable cleanup trap on successful completion
trap - EXIT

success "Kestra installed successfully"
echo ""
if [[ "${KESTRA_TRAEFIK}" == "true" ]]; then
  info "Access at https://${KESTRA_DOMAIN}"
else
  info "Access at http://${KESTRA_BIND_IP}:${KESTRA_PORT}"
fi
info "Login: ${KESTRA_USERNAME} / (see ${ENV_FILE})"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "- View logs: docker compose -f ${COMPOSE_FILE} logs -f"
echo "- Stop the stack: docker compose -f ${COMPOSE_FILE} down"
echo "- Workflows run against the host Docker daemon (trusted workflows only)."
echo ""
