#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-n8n.sh — Install n8n automation platform
# =============================================================================
#
# Description:
#   Installs n8n with PostgreSQL. Can optionally configure with Traefik labels.
#
# Environment Variables (optional):
#   N8N_DIR           - Installation directory (default: /srv/n8n)
#   TRAEFIK_ENABLED   - Enable Traefik integration (default: false)
#   N8N_IMAGE         - n8n image (default: versions.yml key n8n, pinned)
#   N8N_TRAEFIK_IMAGE - Private sidecar Traefik, Traefik variant only
#                       (default: versions.yml key traefik, pinned)
#   POSTGRES_IMAGE    - Database image (default: versions.yml key n8n-postgres, pinned)
#
# Usage:
#   ./setup-n8n.sh
#   TRAEFIK_ENABLED=true ./setup-n8n.sh
#   ./setup-n8n.sh --help
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

Installs n8n (automation platform) with PostgreSQL using Docker Compose.
Can optionally configure Traefik integration.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  N8N_DIR           Installation directory (default: /srv/n8n)
  TRAEFIK_ENABLED   Enable Traefik integration (default: false)
  N8N_IMAGE         n8n image (default: $(kw_image n8n),
                    pinned — override with an explicit version tag)
  N8N_TRAEFIK_IMAGE Private sidecar Traefik, written by the Traefik variant
                    only (default: $(kw_image traefik), pinned)
  POSTGRES_IMAGE    Database image (default: $(kw_image n8n-postgres), pinned)
  WAIT_TIMEOUT      Max seconds to wait for the stack to come up and become
                    healthy after 'docker compose up -d' (default: 180)

${BOLD}Note:${RESET} A .env template with placeholder values is written to
${N8N_DIR:-/srv/n8n}/.env — review it before starting n8n.

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

# Configuration
: "${N8N_DIR:=/srv/n8n}"
: "${TRAEFIK_ENABLED:=false}"
COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"

# Container images — pinned on purpose (ticket improvements-2/17): the templates
# used to carry an untagged n8n reference (i.e. `:latest`), an untagged Traefik
# sidecar and a hard-coded postgres tag.
# The defaults live in versions.yml (Renovate keeps them current); the Traefik
# sidecar shares the `traefik` entry with setup-traefik.sh.
N8N_IMAGE="${N8N_IMAGE:-$(kw_image n8n)}"
N8N_TRAEFIK_IMAGE="${N8N_TRAEFIK_IMAGE:-$(kw_image traefik)}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-$(kw_image n8n-postgres)}"
warn_moving_image "${N8N_IMAGE}" "N8N_IMAGE"
warn_moving_image "${N8N_TRAEFIK_IMAGE}" "N8N_TRAEFIK_IMAGE"
warn_moving_image "${POSTGRES_IMAGE}" "POSTGRES_IMAGE"

command -v envsubst >/dev/null 2>&1 \
  || error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"

# Render docker-compose.yml from the matching template variant. Only the image
# references are substituted here; ${SUBDOMAIN}/${DOMAIN_NAME}/${GENERIC_TIMEZONE}
# stay literal in the generated file and are resolved at runtime from
# ${N8N_DIR}/.env (see AGENTS.md, "Secrets and templating").
_render_n8n_compose() {
  local template="$1" dest="$2" tmp
  tmp="$(mktempfile docker-compose.yml)"
  export N8N_IMAGE N8N_TRAEFIK_IMAGE POSTGRES_IMAGE
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${N8N_IMAGE} ${N8N_TRAEFIK_IMAGE} ${POSTGRES_IMAGE}' < "${template}" > "${tmp}"
  sudo install -m 0644 "${tmp}" "${dest}"
  rm -f "${tmp}"
}

# =============================================================================
# Main
# =============================================================================

step "Setting up n8n automation platform"

# Pre-flight
if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run setup-docker.sh first."
fi

# Create workspace
step "Creating workspace at ${N8N_DIR}"
sudo mkdir -p "${N8N_DIR}"
sudo mkdir -p "${N8N_DIR}/local-files"
success "Directories ready."

# Render .env from template (static quoted heredoc → plain cp)
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/n8n"
step "Creating .env file"
sudo cp "${TEMPLATE_DIR}/env.template" "${N8N_DIR}/.env"

info ".env written – review values before starting n8n"

# Render docker-compose.yml from template (images envsubst'ed from the pinned
# defaults above; everything else stays literal for compose/.env)
step "Creating docker-compose.yml"
if [[ "${TRAEFIK_ENABLED}" == "true" ]]; then
  _render_n8n_compose "${TEMPLATE_DIR}/docker-compose.traefik.yml" "${COMPOSE_FILE}"
else
  _render_n8n_compose "${TEMPLATE_DIR}/docker-compose.local.yml" "${COMPOSE_FILE}"
fi

success "docker-compose.yml written"

# Traefik network setup
if [[ "${TRAEFIK_ENABLED}" == "true" ]]; then
  if ! docker network inspect proxy >/dev/null 2>&1; then
    info "Creating 'proxy' Docker network"
    docker network create proxy || true
  fi
fi

# Bring stack up
step "Starting n8n"
docker compose -f "${COMPOSE_FILE}" up -d --build n8n

# Health gate: prove the containers are actually up before reporting success.
mapfile -t _ids < <(docker compose -f "${COMPOSE_FILE}" ps -q)
wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
  || error "n8n stack did not come up — see the status output above"

success "n8n installed successfully"
info "Access at http://localhost:5678 (or https://automation.example.com with Traefik)"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "- Edit ${N8N_DIR}/.env to configure domain/password"
echo "- View logs: docker compose -f ${COMPOSE_FILE} logs -f"