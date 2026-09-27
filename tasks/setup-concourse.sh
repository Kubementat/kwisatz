#!/usr/bin/env bash
# =============================================================================
# Concourse CI Docker Setup Script
# =============================================================================
#
# DESCRIPTION:
#   Automated setup script for deploying Concourse CI, a continuous integration
#   platform, using Docker Compose. Includes TSA key generation, PostgreSQL
#   database, web UI (ATC), and worker node configuration. Also installs the
#   fly CLI on the host machine.
#
# KEY ACTIONS:
#   1. Pre-flight checks: Verifies Docker installation & daemon
#   2. Idempotency detection: Checks for existing deployment
#   3. RSA key generation: Creates TSA and worker key pairs
#   4. Environment file generation: Creates .env with credentials
#   5. Docker Compose file generation: Creates docker-compose.yml
#   6. Pulls required Docker images (postgres, concourse/concourse)
#   7. Starts the Docker Compose stack in detached mode
#   8. Waits for Concourse web UI to become available (max 120s)
#   9. Installs fly CLI if not present and configures target
#   10. Displays access information and useful management commands
#
# IMPORTANT VARIABLES:
#   CONCOURSE_HOME       - Base installation directory (default: /srv/concourse)
#   CONCOURSE_WEB_PORT   - Host port for web UI (default: 8089)
#   CONCOURSE_ADMIN_USER - Admin username (default: admin)
#   CONCOURSE_ADMIN_PASSWORD - Admin password (auto-generated if not set)
#   CONCOURSE_DB_PASSWORD - Database password (auto-generated if not set)
#   CONCOURSE_CLUSTER_NAME - Display name in UI (default: denkfabrik)
#   CONCOURSE_DNS_SERVER - DNS for worker containers (default: 8.8.8.8)
#   CONCOURSE_TRAEFIK    - Enable Traefik integration (default: false)
#   CONCOURSE_DOMAIN     - Domain for Traefik routing (required when TRAEFIK=true)
#   CONCOURSE_FLY_TARGET - Target name in ~/.flyrc (default: concourse)
#   CONCOURSE_IMAGE      - Concourse image (default: concourse/concourse:8.3.0, pinned)
#   POSTGRES_IMAGE       - Concourse DB image (default: postgres:15, pinned)
#
# DEPENDENCIES:
#   - Docker: Must be installed and daemon must be running
#   - Docker Compose: Required for orchestration
#   - OpenSSL: Used for password and key generation
#   - curl: Used for health check polling
#
# OUTPUTS:
#   - ${CONCOURSE_HOME}/docker-compose.yml - Generated compose configuration
#   - ${CONCOURSE_HOME}/.env              - Secret variables (chmod 600)
#   - ${CONCOURSE_HOME}/keys/web/         - TSA and session keys
#   - ${CONCOURSE_HOME}/keys/worker/      - Worker key pair
#   - ~/.flyrc                            - fly CLI target configuration
#
# USAGE:
#   sudo ./setup-concourse.sh
#   
#   # Or with custom configuration:
#   CONCOURSE_WEB_PORT=9000 CONCOURSE_ADMIN_USER=myuser sudo ./setup-concourse.sh
#
#   # Show help:
#   sudo ./setup-concourse.sh --help
#
# REFERENCE:
#   Implementation plan: docs/concourse/concourse-ci-implementation-plan.md
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these variables before running
# ─────────────────────────────────────────────────────────────────────────────

CONCOURSE_HOME="${CONCOURSE_HOME:-/srv/concourse}"          # Base installation directory
CONCOURSE_WEB_PORT="${CONCOURSE_WEB_PORT:-8089}"            # Host port for web UI
CONCOURSE_ADMIN_USER="${CONCOURSE_ADMIN_USER:-admin}"       # Admin username
CONCOURSE_ADMIN_PASSWORD="${CONCOURSE_ADMIN_PASSWORD:-}"    # Auto-generated if empty
CONCOURSE_DB_PASSWORD="${CONCOURSE_DB_PASSWORD:-}"          # Auto-generated if empty
CONCOURSE_CLUSTER_NAME="${CONCOURSE_CLUSTER_NAME:-denkfabrik}" # Display name in UI
CONCOURSE_DNS_SERVER="${CONCOURSE_DNS_SERVER:-8.8.8.8}"     # DNS for workers
CONCOURSE_EXTERNAL_URL="${CONCOURSE_EXTERNAL_URL:-}"        # Auto-detected if empty
CONCOURSE_FLY_TARGET="${CONCOURSE_FLY_TARGET:-concourse}"   # Target name in ~/.flyrc

# Container images — pinned on purpose (ticket improvements-2/17): an unpinned
# tag makes every generated docker-compose.yml pull a moving reference.
# Defaults looked up 2026-08-31 from
#   https://github.com/concourse/concourse/releases (latest release v8.3.0) and
#   the postgres tag already in use in templates/concourse/.
# Update deliberately: docker buildx imagetools inspect concourse/concourse
: "${CONCOURSE_IMAGE:=concourse/concourse:8.3.0}"
: "${POSTGRES_IMAGE:=postgres:15}"

# Traefik integration (optional)
CONCOURSE_TRAEFIK="${CONCOURSE_TRAEFIK:-false}"             # Set to "true" to enable
CONCOURSE_DOMAIN="${CONCOURSE_DOMAIN:-}"                    # e.g. concourse.example.com
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"                     # Traefik's network name

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE SHARED LIBRARIES
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/helpers.sh"

# Warn (never fail) if an operator override moved the image off a version tag.
warn_moving_image "${CONCOURSE_IMAGE}" "CONCOURSE_IMAGE"
warn_moving_image "${POSTGRES_IMAGE}" "POSTGRES_IMAGE"


# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} sudo $0 [OPTIONS]

Deploys Concourse CI using Docker Compose (web UI + PostgreSQL + worker),
generates TSA/worker RSA keys, writes ${CONCOURSE_HOME}/.env with credentials,
and installs/configures the fly CLI.

${BOLD}Options:${RESET}
  --interactive   Offer tear-down/re-create of an existing stack (default:
                  converge); prompt on other risky conditions
                  (port conflicts, …)
  -h, --help      Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  CONCOURSE_HOME            Base installation directory (default: /srv/concourse)
  CONCOURSE_WEB_PORT        Host port for web UI (default: 8089)
  CONCOURSE_ADMIN_USER      Admin username (default: admin)
  CONCOURSE_ADMIN_PASSWORD  Admin password (auto-generated if not set)
  CONCOURSE_DB_PASSWORD     Database password (auto-generated if not set)
  CONCOURSE_CLUSTER_NAME    Display name in UI (default: denkfabrik)
  CONCOURSE_DNS_SERVER      DNS for worker containers (default: 8.8.8.8)
  CONCOURSE_EXTERNAL_URL    External URL (auto-detected if not set)
  CONCOURSE_FLY_TARGET      Target name in ~/.flyrc (default: concourse)
  CONCOURSE_TRAEFIK         Enable Traefik integration: true/false (default: false)
  CONCOURSE_DOMAIN          Domain for Traefik routing (required when CONCOURSE_TRAEFIK=true)
  PROXY_NETWORK             Traefik's network name (default: proxy)
  CONCOURSE_IMAGE           Concourse image (default: concourse/concourse:8.3.0,
                            pinned — override with an explicit version tag)
  POSTGRES_IMAGE            Concourse DB image (default: postgres:15, pinned)
  WAIT_TIMEOUT              Max seconds to wait for the stack to come up and
                            become healthy after 'docker compose up -d'
                            (default: 180)
EOF
}

# Parse arguments
INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive)
      INTERACTIVE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1 (see --help)"
      ;;
  esac
  shift
done


# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"
run_preflight_checks

# Verify ssh-keygen is available (required for RSA key generation)
if ! command -v ssh-keygen &>/dev/null; then
  error "ssh-keygen is not installed. Install OpenSSH: sudo apt-get install -y openssh-client"
fi

# Traefik pre-flight (only when opt-in)
if [[ "$CONCOURSE_TRAEFIK" == "true" ]]; then
  ensure_proxy_network
  if [[ -z "$CONCOURSE_DOMAIN" ]]; then
    error "CONCOURSE_DOMAIN must be set when CONCOURSE_TRAEFIK=true."
  fi
fi

# True when this script's own stack is running: the ports it publishes are
# expected on a converge re-run and must not abort the script.
_concourse_stack_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^concourse-web$'
}

# Port availability check (when not using Traefik)
if [[ "$CONCOURSE_TRAEFIK" == "false" ]]; then
  if ss -tln 2>/dev/null | grep -qE ":${CONCOURSE_WEB_PORT}[[:space:]]"; then
    if _concourse_stack_running; then
      info "Port ${CONCOURSE_WEB_PORT} is published by the existing Concourse stack — reusing it."
    else
      warn "Port ${CONCOURSE_WEB_PORT} is already in use."
      warn "Either stop the existing service or choose a different CONCOURSE_WEB_PORT."
      if [[ "$INTERACTIVE" == "true" ]]; then
        read -rp "    Continue anyway? [y/N] " answer
        [[ "${answer,,}" == "y" ]] || exit 0
      else
        error "Port ${CONCOURSE_WEB_PORT} is already in use. Stop the conflicting service or set CONCOURSE_WEB_PORT to a free port, or re-run with --interactive to confirm manually."
      fi
    fi
  else
    info "Port ${CONCOURSE_WEB_PORT} is available."
  fi

  # TSA host port check (direct mode only: the Traefik variant publishes no
  # host ports — workers reach TSA via the internal network at
  # concourse-web:2222).
  if ss -tln 2>/dev/null | grep -qE ":2225[[:space:]]"; then
    if _concourse_stack_running; then
      info "Port 2225 (TSA) is published by the existing Concourse stack — reusing it."
    else
      warn "Port 2225 (TSA) is already in use."
      warn "The worker will fail to register until port 2225 is free."
      if [[ "$INTERACTIVE" == "true" ]]; then
        read -rp "    Continue anyway? [y/N] " answer
        [[ "${answer,,}" == "y" ]] || exit 0
      else
        error "Port 2225 (TSA) is already in use. Free the port, or re-run with --interactive to confirm manually."
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# IDEMPOTENCY DETECTION
# ─────────────────────────────────────────────────────────────────────────────

step "Checking for existing Concourse deployment"

COMPOSE_FILE="${CONCOURSE_HOME}/docker-compose.yml"
ENV_FILE="${CONCOURSE_HOME}/.env"

if [[ -f "$COMPOSE_FILE" ]]; then
  warn "Existing docker-compose.yml found at ${COMPOSE_FILE}."
  # Re-run policy (ticket 12): the existing stack is CONVERGED — config is
  # re-rendered, the stored credentials in ${ENV_FILE} are reused to match
  # the persisted postgres volume, and 'docker compose up -d' reconciles only
  # what changed. Tear-down (and the optional volume wipe) is only offered
  # with --interactive, and only then only on explicit 'y'.
  info "Re-running will converge the existing stack (no tear-down)."

  # Preserve RSA keys - they are bind-mounted and will survive re-deployment
  if [[ -d "${CONCOURSE_HOME}/keys" ]]; then
    info "RSA keys in ${CONCOURSE_HOME}/keys/ will be preserved for session continuity."
  fi

  RECREATE=false
  WIPE_VOLUMES=false
  if [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Stack exists. Converge (default) or tear down and re-create? [c/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      RECREATE=true
      read -rp "    Also wipe the PostgreSQL data volume? Credentials will be regenerated. [y/N] " wipe_answer
      if [[ "${wipe_answer,,}" == "y" ]]; then
        WIPE_VOLUMES=true
      fi
    fi
  fi

  if [[ "$RECREATE" == "true" ]]; then
    info "Stopping and removing existing stack..."
    if [[ "$WIPE_VOLUMES" == "true" ]]; then
      sudo docker compose --env-file "${ENV_FILE}" -f "$COMPOSE_FILE" down -v 2>/dev/null || true
      success "Old stack and database volume removed."
    else
      sudo docker compose --env-file "${ENV_FILE}" -f "$COMPOSE_FILE" down 2>/dev/null || true
      info "Existing credentials from ${ENV_FILE} will be reused to match the preserved volume."
      success "Old stack removed. Database volume and keys preserved."
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CREATE DIRECTORY STRUCTURE
# ─────────────────────────────────────────────────────────────────────────────

step "Creating directory structure under ${CONCOURSE_HOME}"

# Create the base CONCOURSE_HOME directory if it doesn't exist
if [[ ! -d "${CONCOURSE_HOME}" ]]; then
  if ! sudo mkdir -p "${CONCOURSE_HOME}" 2>/dev/null; then
    error "Failed to create ${CONCOURSE_HOME}. Check permissions."
    exit 1
  fi
fi

# Create subdirectories for keys
sudo mkdir -p "${CONCOURSE_HOME}/keys/web"
sudo mkdir -p "${CONCOURSE_HOME}/keys/worker"

# Ensure directories are accessible by Docker daemon
if ! groups "$USER" 2>/dev/null | grep -qw docker; then
  info "Note: Add user '$USER' to docker group for Docker access: sudo usermod -aG docker $USER"
fi


success "Directories created."

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE RSA KEY PAIRS
# ─────────────────────────────────────────────────────────────────────────────

step "Generating RSA key pairs for TSA authentication"

# Generate keys only if they don't exist (idempotent)
# ssh-keygen is used (not openssl) to produce the OpenSSH key format Concourse requires
if [[ ! -f "${CONCOURSE_HOME}/keys/web/tsa_host_key" ]]; then
  info "Generating TSA host key pair..."
  sudo ssh-keygen -t rsa -b 4096 -m PEM -f "${CONCOURSE_HOME}/keys/web/tsa_host_key" -N ""
fi

if [[ ! -f "${CONCOURSE_HOME}/keys/web/session_signing_key" ]]; then
  info "Generating session signing key pair..."
  sudo ssh-keygen -t rsa -b 4096 -m PEM -f "${CONCOURSE_HOME}/keys/web/session_signing_key" -N ""
fi

if [[ ! -f "${CONCOURSE_HOME}/keys/worker/worker_key" ]]; then
  info "Generating worker key pair..."
  sudo ssh-keygen -t rsa -b 4096 -m PEM -f "${CONCOURSE_HOME}/keys/worker/worker_key" -N ""
fi

# Create authorized_worker_keys (copy of worker public key)
if [[ ! -f "${CONCOURSE_HOME}/keys/web/authorized_worker_keys" ]]; then
  sudo cp "${CONCOURSE_HOME}/keys/worker/worker_key.pub" \
     "${CONCOURSE_HOME}/keys/web/authorized_worker_keys"
fi

# Set permissions
sudo chmod -R 700 "${CONCOURSE_HOME}/keys/"

success "Keys generated and permissions set."

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE ENVIRONMENT FILE
# ─────────────────────────────────────────────────────────────────────────────

step "Generating ${ENV_FILE}"

# If .env already exists, source the existing passwords so they are preserved across re-runs.
# PostgreSQL ignores POSTGRES_PASSWORD once the data volume is initialized, so changing the
# password would break authentication against an existing volume.
if [[ -f "${ENV_FILE}" ]]; then
  info "Existing .env found — reusing stored credentials to match the postgres volume."
  # shellcheck disable=SC1090
  source <(sudo grep -E '^CONCOURSE_(DB_PASSWORD|ADMIN_PASSWORD)=' "${ENV_FILE}")
fi

# Generate passwords if not already set (first run, or env vars were pre-set by caller)
if [[ -z "$CONCOURSE_ADMIN_PASSWORD" ]]; then
  CONCOURSE_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
fi

if [[ -z "$CONCOURSE_DB_PASSWORD" ]]; then
  CONCOURSE_DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
fi

# Detect external URL if not set
if [[ -z "$CONCOURSE_EXTERNAL_URL" ]]; then
  if [[ "$CONCOURSE_TRAEFIK" == "true" ]]; then
    # Traefik mode: the TLS domain is the external address (no host ports
    # are published in this variant, so an http://LAN-IP URL is dead).
    CONCOURSE_EXTERNAL_URL="https://${CONCOURSE_DOMAIN}"
  else
    LAN_IP=$(hostname -I | awk '{print $1}')
    CONCOURSE_EXTERNAL_URL="http://${LAN_IP}:${CONCOURSE_WEB_PORT}"
  fi
fi

# Write .env file from template (unquoted heredoc → envsubst)
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/concourse"
command -v envsubst || error "envsubst not installed — install with: sudo apt-get install gettext-base"

# Export variables for envsubst (explicit list, never bare envsubst)
_concourse_generated_date="$(date -Iseconds)"
export CONCOURSE_DB_PASSWORD CONCOURSE_EXTERNAL_URL CONCOURSE_WEB_PORT \
  CONCOURSE_CLUSTER_NAME CONCOURSE_ADMIN_USER CONCOURSE_ADMIN_PASSWORD \
  CONCOURSE_DNS_SERVER _concourse_generated_date
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${CONCOURSE_DB_PASSWORD} ${CONCOURSE_EXTERNAL_URL} ${CONCOURSE_WEB_PORT} ${CONCOURSE_CLUSTER_NAME} ${CONCOURSE_ADMIN_USER} ${CONCOURSE_ADMIN_PASSWORD} ${CONCOURSE_DNS_SERVER} ${_concourse_generated_date}' \
  < "${TEMPLATE_DIR}/env.template" | sudo tee "${ENV_FILE}" > /dev/null

sudo chmod 600 "${ENV_FILE}"
# Keep the env file readable by the invoking operator: manual 'docker compose'
# commands (logs, ps, down) run as that user and hard-fail if they cannot
# read the .env that compose auto-loads. SUDO_USER covers 'sudo ./script' runs.
sudo chown "${SUDO_USER:-$USER}" "${ENV_FILE}"

success "Environment file written with auto-generated credentials."

# Store for later use (fly CLI login)
STORED_ADMIN_PASSWORD="$CONCOURSE_ADMIN_PASSWORD"

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE DOCKER COMPOSE FILE
# ─────────────────────────────────────────────────────────────────────────────

step "Generating ${COMPOSE_FILE}"

# Render docker-compose.yml from template (static quoted heredoc with awk/sed → envsubst)
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/concourse"
command -v envsubst || error "envsubst not installed — install with: sudo apt-get install gettext-base"

# Select compose variant based on deployment mode
if [[ "$CONCOURSE_TRAEFIK" == "true" ]]; then
  TEMPLATE_FILE="${TEMPLATE_DIR}/docker-compose.traefik.yml"
else
  TEMPLATE_FILE="${TEMPLATE_DIR}/docker-compose.yml"
fi

# The original script's quoted heredoc left the service-section ${...} tokens
# literal in the rendered file (compose resolves them at runtime via
# --env-file), so only the inserted networks/ports/labels sections are
# substituted here — never the literal service-section variables.
# CONCOURSE_IMAGE / POSTGRES_IMAGE are substituted here (pinned script defaults,
# ticket improvements-2/17); the service-section variables above stay literal.
export CONCOURSE_IMAGE POSTGRES_IMAGE
if [[ "$CONCOURSE_TRAEFIK" == "true" ]]; then
  export PROXY_NETWORK CONCOURSE_DOMAIN
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${PROXY_NETWORK} ${CONCOURSE_DOMAIN} ${CONCOURSE_IMAGE} ${POSTGRES_IMAGE}' < "${TEMPLATE_FILE}" | sudo tee "${COMPOSE_FILE}" > /dev/null
else
  export CONCOURSE_WEB_PORT
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${CONCOURSE_WEB_PORT} ${CONCOURSE_IMAGE} ${POSTGRES_IMAGE}' < "${TEMPLATE_FILE}" | sudo tee "${COMPOSE_FILE}" > /dev/null
fi

success "Docker Compose file written to ${COMPOSE_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# PULL IMAGES
# ─────────────────────────────────────────────────────────────────────────────

step "Pulling Docker images"
sudo docker compose --env-file "${ENV_FILE}" -f "$COMPOSE_FILE" pull
success "Images pulled."

# ─────────────────────────────────────────────────────────────────────────────
# START THE STACK
# ─────────────────────────────────────────────────────────────────────────────

step "Starting Concourse stack (detached)"
sudo docker compose --env-file "${ENV_FILE}" -f "$COMPOSE_FILE" up -d

# Health gate: prove the containers are actually up before reporting success.
# (Single implementation in lib/helpers.sh — also covers crash loops, not just
# already-exited containers.)
mapfile -t _ids < <(sudo docker compose --env-file "${ENV_FILE}" -f "$COMPOSE_FILE" ps -q)
wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
  || error "Concourse stack did not come up — see the status output above"

# ─────────────────────────────────────────────────────────────────────────────
# WAIT FOR CONCOURSE TO BECOME AVAILABLE
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for Concourse web UI to respond"

MAX_WAIT=120
INTERVAL=5
ELAPSED=0
READY=false
HTTP_CODE=""

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  # Check via the public URL: the web image ships no curl, and in Traefik
  # mode this also proves the router rule and TLS certificate work end-to-end.
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "${CONCOURSE_EXTERNAL_URL}/api/v1/info" 2>/dev/null) || true

  if [[ "$HTTP_CODE" =~ ^(200|302|303)$ ]]; then
    READY=true
    break
  fi

  echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s ..."
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""

if [[ "$READY" == "true" ]]; then
  if [[ "$CONCOURSE_TRAEFIK" == "true" ]]; then
    success "Concourse is up and responding via Traefik!"
  else
    success "Concourse is up and responding on port ${CONCOURSE_WEB_PORT}!"
  fi
else
  error "Concourse did not respond within ${MAX_WAIT}s. Check logs with: sudo docker compose -f ${COMPOSE_FILE} logs -f"
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL FLY CLI (if not present)
# ─────────────────────────────────────────────────────────────────────────────

step "Checking fly CLI installation"

if command -v fly &>/dev/null; then
  info "Fly CLI already installed at $(command -v fly)"
  INSTALL_FLY=false
else
  INSTALL_FLY=true
fi

if [[ "$INSTALL_FLY" == "true" ]]; then
  step "Installing fly CLI"
  
  # Detect architecture
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) PLATFORM="amd64" ;;
    aarch64|arm64) PLATFORM="arm64" ;;
    *) error "Unsupported architecture: $ARCH";;
  esac
  
  info "Detected architecture: ${ARCH} (${PLATFORM})"
  
  # Download fly CLI
  info "Downloading fly CLI from Concourse web UI..."
  curl -fsSL \
    "${CONCOURSE_EXTERNAL_URL}/api/v1/cli?arch=${PLATFORM}&platform=linux" \
    -o /tmp/fly
  
  # Verify download
  if ! file /tmp/fly | grep -q "ELF 64-bit"; then
    error "Downloaded file is not a valid ELF binary"
  fi
  
  success "Download verified."
  
  # Install
  sudo install -m 0755 /tmp/fly /usr/local/bin/fly
  fly --version
  success "Fly CLI installed at /usr/local/bin/fly"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE FLY TARGET
# ─────────────────────────────────────────────────────────────────────────────

step "Configuring fly target: ${CONCOURSE_FLY_TARGET}"

fly -t "${CONCOURSE_FLY_TARGET}" login \
  --concourse-url "${CONCOURSE_EXTERNAL_URL}" \
  --username "${CONCOURSE_ADMIN_USER}" \
  --password "${STORED_ADMIN_PASSWORD}"

success "Target configured in ~/.flyrc"

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Concourse setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Web UI${RESET}           ${CONCOURSE_EXTERNAL_URL}"
echo -e "  ${BOLD}Admin User${RESET}       ${CONCOURSE_ADMIN_USER}"
echo -e "  ${BOLD}Admin Password${RESET}   ${STORED_ADMIN_PASSWORD}"
echo -e "  ${BOLD}Database${RESET}         PostgreSQL (internal)"
echo -e "  ${BOLD}Data directory${RESET}   ${CONCOURSE_HOME}"
echo -e "  ${BOLD}Compose file${RESET}     ${COMPOSE_FILE}"
echo -e "  ${BOLD}Fly target${RESET}       ${CONCOURSE_FLY_TARGET}"
echo ""
echo -e "${YELLOW}  First-time setup:${RESET}"
echo -e "  Open the Web UI and create your first pipeline."
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Follow logs    :  docker compose -f ${COMPOSE_FILE} logs -f"
echo -e "  Stop stack     :  docker compose -f ${COMPOSE_FILE} down"
echo -e "  Start stack    :  docker compose -f ${COMPOSE_FILE} up -d"
echo -e "  Shell into web :  docker exec -it concourse-web bash"
echo ""
echo -e "${BOLD}Fly CLI:${RESET}"
echo -e "  Target           : ${CONCOURSE_FLY_TARGET}"
echo -e "  Login command    : fly -t ${CONCOURSE_FLY_TARGET} login -c ${CONCOURSE_EXTERNAL_URL} -u ${CONCOURSE_ADMIN_USER} -p <password>"
echo -e "  List pipelines   : fly -t ${CONCOURSE_FLY_TARGET} pipelines"
echo -e "  Trigger job      : fly -t ${CONCOURSE_FLY_TARGET} trigger-job -j pipeline/job --watch"
echo ""
echo ""
echo -e "${BOLD}Example pipeline:${RESET}"
echo -e "  Find an example in templates/concourse/hello-world-pipeline.yml"
echo ""
echo ""
