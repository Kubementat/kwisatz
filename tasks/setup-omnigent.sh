#!/usr/bin/env bash
# =============================================================================
# Omnigent Docker Setup Script
# =============================================================================
#
# DESCRIPTION:
#   Automated setup script for deploying Omnigent — an open-source meta-harness
#   that provides a common orchestration layer over multiple AI coding agents
#   (Claude Code, Codex, Cursor, Pi, etc.).
#
#   Deploys the Omnigent server via Docker Compose (Postgres + FastAPI) and
#   installs the runner CLI (`omnigent`) on the host for local agent execution.
#
# KEY ACTIONS:
#   1. Pre-flight checks: Docker, daemon, openssl, curl
#   2. Checks if an existing Omnigent compose stack is running (with prompt)
#   3. Generates a secure .env file with auto-generated secrets
#   4. Creates docker-compose.yml with Traefik or direct access mode
#   5. Pulls required Docker images
#   6. Starts the Docker Compose stack in detached mode
#   7. Waits for the server to become available (max 120s)
#   8. Installs runner CLI (uv, omnigent) and prerequisites (tmux, bubblewrap, Node.js, npm)
#   9. Prints registration instructions (manual login + host registration)
#  10. Configures UFW firewall rule (direct mode)
#  11. Displays access information and useful management commands
#
# IMPORTANT VARIABLES:
#   OMNIGENT_HOME                    - Host directory for persistent data (default: /srv/omnigent)
#   OMNIGENT_IMAGE                   - Docker image to use (default: versions.yml key omnigent-server)
#   OMNIGENT_IMAGE_TAG               - Docker image tag (default: versions.yml key omnigent-server)
#   POSTGRES_IMAGE                   - Postgres image for the bundled db service
#                                      (default: versions.yml key omnigent-postgres,
#                                      pinned; written to .env for compose)
#   OMNIGENT_PORT                    - Host port for direct web UI access (default: 8008)
#   OMNIGENT_TRAEFIK                 - Set to "true" to enable Traefik routing (default: false)
#   OMNIGENT_DOMAIN                  - Domain for Traefik access (required when Traefik=true)
#   PROXY_NETWORK                    - Traefik's external Docker network name (default: proxy)
#   OMNIGENT_AUTH_ENABLED            - Enable auth: "1" or "0" (default: 1)
#   OMNIGENT_AUTH_PROVIDER           - Force auth mode: "accounts", "oidc", or "header"
#   OMNIGENT_ACCOUNTS_BASE_URL       - Public URL for accounts mode
#   OMNIGENT_ACCOUNTS_AUTO_OPEN      - Disable auto-open in logs (default: 0)
#   OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME - Pre-seed admin username for headless deploys (default: admin)
#   OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD - Pre-seed admin password for headless deploys
#   POSTGRES_USER                    - Postgres user (default: omnigent)
#   POSTGRES_DB                      - Postgres database name (default: omnigent)
#
# DEPENDENCIES:
#   - Docker: Must be installed and daemon must be running
#   - Docker Compose v2+ recommended
#   - openssl: Used for generating secure secrets
#   - curl: Used for health check polling
#   - Traefik instance with proxy network (when OMNIGENT_TRAEFIK=true)
#
# OUTPUTS:
#   - ${OMNIGENT_HOME}/docker-compose.yml - Generated compose configuration
#   - ${OMNIGENT_HOME}/.env               - Secrets and environment variables (secure)
#   - Persistent volumes: postgres-data, artifact-data
#
# USAGE:
#   ./setup-omnigent.sh
#
#   # Or with custom configuration:
#   OMNIGENT_HOME=/opt/omnigent OMNIGENT_PORT=9000 ./setup-omnigent.sh
#
#   # With Traefik integration:
#   OMNIGENT_TRAEFIK=true OMNIGENT_DOMAIN=omnigent.example.com ./setup-omnigent.sh
#
# REFERENCE:
#   https://github.com/omnigent-ai/omnigent
#   https://github.com/omnigent-ai/omnigent/tree/main/deploy/docker
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# USAGE & ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Automated setup script for deploying Omnigent.

Options:
  --interactive   Offer tear-down/re-create of an existing stack (default:
                  converge); prompt on other risky conditions
  -h, --help      Show this help message and exit

Environment Variables:
  OMNIGENT_HOME                    Data directory (default: /srv/omnigent)
  OMNIGENT_IMAGE                   Docker image (default: $(kw_pin omnigent-server package))
  OMNIGENT_IMAGE_TAG               Image tag (default: $(kw_version omnigent-server))
  OMNIGENT_PORT                    Host port, direct mode (default: 8008)
  OMNIGENT_TRAEFIK                 Enable Traefik: "true" or "false" (default: false)
  OMNIGENT_DOMAIN                  Domain for Traefik access (required when Traefik=true)
  PROXY_NETWORK                    Traefik network name (default: proxy)
  OMNIGENT_AUTH_ENABLED            Enable auth: "1" or "0" (default: 1)
  OMNIGENT_AUTH_PROVIDER           Auth mode: "accounts", "oidc", or "header"
  OMNIGENT_ACCOUNTS_BASE_URL       Public URL for accounts mode
  OMNIGENT_ACCOUNTS_AUTO_OPEN      Disable auto-open in logs (default: 0)
  OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME  Pre-seed admin username for headless deploys (default: admin)
  OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD  Pre-seed admin password for headless deploys
  POSTGRES_USER                    Postgres user (default: omnigent)
  POSTGRES_DB                      Postgres database name (default: omnigent)
  POSTGRES_IMAGE                   Postgres image for the bundled db service
                                   (default: $(kw_image omnigent-postgres) — pinned so a
                                   re-run cannot silently major-bump the db)
  WAIT_TIMEOUT                     Max seconds to wait for the stack to come up
                                   and become healthy after 'docker compose up -d'
                                   (default: 180)

Examples:
  $(basename "$0")
  OMNIGENT_HOME=/opt/omnigent $(basename "$0")
  OMNIGENT_TRAEFIK=true OMNIGENT_DOMAIN=omnigent.example.com $(basename "$0")

Reference: https://github.com/omnigent-ai/omnigent
USAGE
}

# ─────────────────────────────────────────────────────────────────────────────
# SHARED HELPERS
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/helpers.sh"

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

INTERACTIVE=false
RECREATE=false     # --interactive + 'y' only; a plain re-run converges (ticket 12)

for arg in "$@"; do
  case "$arg" in
    --interactive)
      INTERACTIVE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown argument: $arg. Usage: $(basename "$0") [--help] [--interactive]"
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these variables before running
# ─────────────────────────────────────────────────────────────────────────────

OMNIGENT_HOME="${OMNIGENT_HOME:-/srv/omnigent}"            # Host directory for persistent data
OMNIGENT_IMAGE="${OMNIGENT_IMAGE:-$(kw_pin omnigent-server package)}"  # Docker image
OMNIGENT_IMAGE_TAG="${OMNIGENT_IMAGE_TAG:-$(kw_version omnigent-server)}"         # Docker image tag
POSTGRES_IMAGE="${POSTGRES_IMAGE:-$(kw_image omnigent-postgres)}"  # bundled db, HELD on its major
OMNIGENT_PORT="${OMNIGENT_PORT:-8008}"                     # Host port (direct mode)

# Traefik reverse-proxy integration (opt-in)
OMNIGENT_TRAEFIK="${OMNIGENT_TRAEFIK:-false}"              # Set to "true" to enable Traefik routing
OMNIGENT_DOMAIN="${OMNIGENT_DOMAIN:-}"                     # e.g. omnigent.example.com (required when Traefik=true)
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"                    # Traefik's external Docker network name

# Auth configuration
OMNIGENT_AUTH_ENABLED="${OMNIGENT_AUTH_ENABLED:-1}"         # Enable auth: "1" or "0"
OMNIGENT_AUTH_PROVIDER="${OMNIGENT_AUTH_PROVIDER:-}"       # Force auth mode: "accounts", "oidc", or "header"
OMNIGENT_ACCOUNTS_BASE_URL="${OMNIGENT_ACCOUNTS_BASE_URL:-}"
OMNIGENT_ACCOUNTS_AUTO_OPEN="${OMNIGENT_ACCOUNTS_AUTO_OPEN:-0}"
OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME="${OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME:-admin}" # Pre-seed admin username
OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD="${OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD:-}" # Pre-seed admin password

# Database configuration
POSTGRES_USER="${POSTGRES_USER:-omnigent}"                  # Postgres user
POSTGRES_DB="${POSTGRES_DB:-omnigent}"                      # Postgres database name

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — handles partial failures
# ─────────────────────────────────────────────────────────────────────────────

# Set to 1 immediately BEFORE 'up -d' and reset to 0 once the stack is proven
# healthy. The trap tears the stack down only while this flag is set, so a late
# failure (health gate, ufw, .env write) cannot stop a stack that was already
# running before this script was invoked.
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
  if [[ -d "$OMNIGENT_HOME" ]] && (cd "$OMNIGENT_HOME" && docker compose ps) &>/dev/null; then
    if [[ -n "$(cd "$OMNIGENT_HOME" && docker compose ps -q 2>/dev/null || true)" ]]; then
      (cd "$OMNIGENT_HOME" && docker compose down --remove-orphans 2>/dev/null) || true
      info "Removed partially created stack."
    else
      info "Stack from this run is already stopped — data volumes (postgres-data, artifact-data) are preserved."
    fi
  fi
}

trap cleanup_on_failure EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

# Run standard preflight checks (docker, daemon, openssl, curl)
run_preflight_checks
success "All pre-flight checks passed."

# Traefik pre-flight (only when opt-in)
if [[ "$OMNIGENT_TRAEFIK" == "true" ]]; then
  ensure_proxy_network
  ensure_traefik_running
  if [[ -z "$OMNIGENT_DOMAIN" ]]; then
    error "OMNIGENT_DOMAIN must be set when OMNIGENT_TRAEFIK=true."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK FOR EXISTING STACK
# ─────────────────────────────────────────────────────────────────────────────

step "Checking for an existing Omnigent compose stack"

COMPOSE_FILE="${OMNIGENT_HOME}/docker-compose.yml"

if [[ -f "$COMPOSE_FILE" ]]; then
  warn "Existing docker-compose.yml found at ${COMPOSE_FILE}."
  echo ""
  # Re-run policy (ticket 12): the existing stack is CONVERGED — the compose
  # file and .env are re-rendered (secrets reused) and 'docker compose up -d'
  # reconciles only what changed. Tear-down only on explicit interactive 'y'.
  info "Re-running will converge the existing stack (no tear-down)."
  info "${BOLD}IMPORTANT:${RESET} Your data in Docker named volumes will be PRESERVED."
  RECREATE=false
  if [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Stack exists. Converge (default) or tear down and re-create? [c/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      RECREATE=true
    fi
  fi
  if [[ "$RECREATE" == "true" ]]; then
    # The operator confirmed the re-create: the cleanup trap must cover it,
    # so a failure before 'up -d' or a half-created re-create is still
    # cleaned up — and the trap must not claim "nothing torn down".
    STACK_CREATED_THIS_RUN=1
    info "Stopping and removing existing stack..."
    (cd "$OMNIGENT_HOME" && docker compose down 2>/dev/null) || true
    success "Old stack removed. Data volumes preserved."
  fi
fi

# Check for port conflict (direct mode only)
# A RUNNING existing Omnigent stack holds the port itself — that is expected
# for a converge (ticket 12), so the conflict is only an error when our own
# stack is not the one using the port.
if [[ "$OMNIGENT_TRAEFIK" != "true" ]]; then
  _omnigent_stack_running=false
  if [[ -f "$COMPOSE_FILE" ]] && docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .; then
    _omnigent_stack_running=true
  fi
  if [[ "$_omnigent_stack_running" != "true" ]] && \
     { ss -tln 2>/dev/null | grep -q ":${OMNIGENT_PORT} " || \
       netstat -tln 2>/dev/null | grep -q ":${OMNIGENT_PORT} "; }; then
    error "Port ${OMNIGENT_PORT} is already in use. Choose a different OMNIGENT_PORT."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CREATE PERSISTENT HOST DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────

step "Creating persistent storage directories under ${OMNIGENT_HOME}"

[[ $EUID -eq 0 ]] || sudo mkdir -p "${OMNIGENT_HOME}"
[[ $EUID -eq 0 ]] || sudo chown "${USER:-$(whoami)}" "${OMNIGENT_HOME}"
success "Directories ready."

# ─────────────────────────────────────────────────────────────────────────────
# ENV FILE HELPERS — used by .env generation block
# ─────────────────────────────────────────────────────────────────────────────

# In-place edit helper — uses uname -s for reliable platform detection
sed_inplace() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Idempotent key-value setter.
# Uses awk for safe key matching and value replacement — avoids sed
# injection from special characters (& / \ |) in values such as URLs.
set_or_replace_kv() {
  local key="$1" value="$2"
  awk -v key="$key" -v val="$value" '
    BEGIN { found = 0 }
    {
      if ($0 ~ "^" key "=" || $0 ~ "^# *" key "=") {
        found = 1
        sub(/^[[:space:]]*#?[[:space:]]*/, "", $0)
        print key "=" val
      } else {
        print
      }
    }
    END { if (!found) print key "=" val }
  ' "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE .ENV FILE (only on first run — never overwrite)
# ─────────────────────────────────────────────────────────────────────────────

ENV_FILE="${OMNIGENT_HOME}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  step "Generating .env file"

  touch "$ENV_FILE"
  info "Created new .env file."

  # Generate secrets
  set_or_replace_kv POSTGRES_PASSWORD "$(openssl rand -hex 16)"
  info "Generated POSTGRES_PASSWORD."

  set_or_replace_kv OMNIGENT_ACCOUNTS_COOKIE_SECRET "$(openssl rand -hex 32)"
  info "Generated OMNIGENT_ACCOUNTS_COOKIE_SECRET."

  set_or_replace_kv OMNIGENT_OIDC_COOKIE_SECRET "$(openssl rand -hex 32)"
  info "Generated OMNIGENT_OIDC_COOKIE_SECRET."

  # Set OMNIGENT_AUTH_PROVIDER if provided
  if [[ -n "$OMNIGENT_AUTH_PROVIDER" ]]; then
    set_or_replace_kv OMNIGENT_AUTH_PROVIDER "$OMNIGENT_AUTH_PROVIDER"
    info "Set OMNIGENT_AUTH_PROVIDER=${OMNIGENT_AUTH_PROVIDER}."
  fi

  # Set derived values
  base_url="$([ "$OMNIGENT_TRAEFIK" = "true" ] && echo "https://${OMNIGENT_DOMAIN}" || echo "http://localhost:${OMNIGENT_PORT}")"
  set_or_replace_kv OMNIGENT_ACCOUNTS_BASE_URL "$base_url"
  info "Set OMNIGENT_ACCOUNTS_BASE_URL."

  set_or_replace_kv OMNIGENT_ACCOUNTS_AUTO_OPEN "${OMNIGENT_ACCOUNTS_AUTO_OPEN}"
  info "Set OMNIGENT_ACCOUNTS_AUTO_OPEN."

  # Set database defaults (required for DATABASE_URL in compose)
  set_or_replace_kv POSTGRES_USER "$POSTGRES_USER"
  info "Set POSTGRES_USER."

  set_or_replace_kv POSTGRES_DB "$POSTGRES_DB"
  info "Set POSTGRES_DB."

  # Set Docker image, tag, and port (required in .env for compose)
  set_or_replace_kv OMNIGENT_IMAGE "$OMNIGENT_IMAGE"
  info "Set OMNIGENT_IMAGE."

  set_or_replace_kv OMNIGENT_IMAGE_TAG "$OMNIGENT_IMAGE_TAG"
  info "Set OMNIGENT_IMAGE_TAG."

  set_or_replace_kv POSTGRES_IMAGE "$POSTGRES_IMAGE"
  info "Set POSTGRES_IMAGE."

  set_or_replace_kv OMNIGENT_PORT "$OMNIGENT_PORT"
  info "Set OMNIGENT_PORT."

  # Set auth enabled flag
  set_or_replace_kv OMNIGENT_AUTH_ENABLED "$OMNIGENT_AUTH_ENABLED"
  info "Set OMNIGENT_AUTH_ENABLED."

  # Set admin username (headless deploys)
  set_or_replace_kv OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME "$OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME"
  info "Set OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME=${OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME}."

  # Set admin password if provided (headless deploys)
  if [[ -n "$OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD" ]]; then
    set_or_replace_kv OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD "$OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD"
    info "Set OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD."
  else
    # Auto-generate a strong admin password for headless deploys
    new_admin_password="$(openssl rand -hex 24)"
    set_or_replace_kv OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD "$new_admin_password"
    info "Generated OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD (auto-generated)."
  fi

  chmod 600 "$ENV_FILE"
  success "Secrets stored securely in .env file (mode: 600)."
else
  step "Using existing .env file"
  info "Existing .env file found at ${ENV_FILE} — leaving it unchanged."
fi

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE DOCKER COMPOSE FILE FROM TEMPLATE
# ─────────────────────────────────────────────────────────────────────────────

step "Generating ${COMPOSE_FILE}"

TEMPLATE_DIR="${SCRIPT_DIR}/../templates/omnigent"

if [[ "$OMNIGENT_TRAEFIK" == "true" ]]; then
  COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.traefik.yml"
else
  COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.direct.yml"
fi

if [[ ! -f "$COMPOSE_TEMPLATE" ]]; then
  error "Compose template not found at ${COMPOSE_TEMPLATE}"
fi

# Copy template directly — Docker Compose resolves ${VAR:-default} from .env at runtime
# Only overwrite if the file doesn't already exist (preserve user modifications)
if [[ ! -f "$COMPOSE_FILE" ]]; then
  if [[ $EUID -eq 0 ]]; then
    cp "$COMPOSE_TEMPLATE" "$COMPOSE_FILE"
  else
    sudo cp "$COMPOSE_TEMPLATE" "$COMPOSE_FILE"
  fi
  success "docker-compose.yml written to ${COMPOSE_FILE}"
else
  info "docker-compose.yml already exists at ${COMPOSE_FILE}, leaving it unchanged."
fi

# ─────────────────────────────────────────────────────────────────────────────
# TEARDOWN & START
# ─────────────────────────────────────────────────────────────────────────────

# Re-run policy (ticket 12): NO unconditional teardown here — a re-run
# converges the existing stack, and 'up -d' alone never tears anything down.
# (The confirmed-recreate case tore down above; the RECREATE flag then also
# opts into a fresh image pull, so plain re-runs do not depend on the
# registry.) The STACK_CREATED_THIS_RUN flag set before 'up -d' marks the
# stack (re)created by THIS run for the cleanup trap.
step "Starting Omnigent stack (detached)"
STACK_CREATED_THIS_RUN=1
if [[ "$RECREATE" == "true" ]]; then
  (cd "$OMNIGENT_HOME" && docker compose up -d --pull always)
else
  (cd "$OMNIGENT_HOME" && docker compose up -d)
fi

# Health gate: prove the containers are actually up before reporting success.
# This also replaces the old ad-hoc "container running? / restart loop?"
# checks: they were dead code (error() exited before them) and the gate
# covers not-running, unhealthy and restart-loop states.
mapfile -t _ids < <(cd "$OMNIGENT_HOME" && docker compose ps -q)
wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
  || { (cd "$OMNIGENT_HOME" && docker compose logs --tail=50) 2>/dev/null || true
       error "Omnigent stack did not come up"; }
STACK_CREATED_THIS_RUN=0     # proven healthy -> a later failure must not tear it down

# ─────────────────────────────────────────────────────────────────────────────
# ENSURE POSTGRES PASSWORD MATCHES .ENV
# PostgreSQL ignores POSTGRES_PASSWORD when the data volume already exists.
# This step syncs the stored password with the .env value to prevent auth failures.
# ─────────────────────────────────────────────────────────────────────────────

step "Syncing postgres password with .env"

PG_PASSWORD_FROM_ENV="$(grep -E '^POSTGRES_PASSWORD=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2-)"
PG_USER_FROM_ENV="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2-)"

if [[ -n "$PG_PASSWORD_FROM_ENV" && -n "$PG_USER_FROM_ENV" ]]; then
  # Wait briefly for postgres to be ready
  pg_sync_max=30
  pg_sync_elapsed=0
  pg_sync_ready=false
  while [[ $pg_sync_elapsed -lt $pg_sync_max ]]; do
    if docker exec omnigent-postgres pg_isready -U "$PG_USER_FROM_ENV" &>/dev/null; then
      pg_sync_ready=true
      break
    fi
    sleep 2
    pg_sync_elapsed=$((pg_sync_elapsed + 2))
  done

  if [[ "$pg_sync_ready" == "true" ]]; then
    # Use local trust auth (no password needed) to set the password
    # Escape single quotes in password for SQL safety
    pg_password_escaped="${PG_PASSWORD_FROM_ENV//\'/\'\'}"
    if docker exec omnigent-postgres psql -U "$PG_USER_FROM_ENV" -d "$PG_USER_FROM_ENV" \
      -c "ALTER USER ${PG_USER_FROM_ENV} WITH PASSWORD '${pg_password_escaped}';" &>/dev/null; then
      success "Postgres password synced with .env."
    else
      warn "Could not sync postgres password. Connection may fail if .env password differs from stored password."
    fi
  else
    warn "Postgres not ready within ${pg_sync_max}s, skipping password sync."
  fi
else
  warn "POSTGRES_PASSWORD or POSTGRES_USER not found in .env, skipping password sync."
fi

# ─────────────────────────────────────────────────────────────────────────────
# HEALTH CHECK
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for Omnigent server to respond"

if [[ "$OMNIGENT_TRAEFIK" == "true" ]]; then
  # Traefik mode: skip direct health check (TLS via domain)
  info "Traefik mode: skipping direct health check (TLS access at https://${OMNIGENT_DOMAIN})"
  info "Container will be accessible once DNS resolves and TLS is provisioned"
  READY=true
else
  # Direct mode: check localhost:port
  ACCESS_URL="http://localhost:${OMNIGENT_PORT}"
  MAX_WAIT=120
  INTERVAL=5
  ELAPSED=0
  READY=false

  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    if curl -s -o /dev/null -w "%{http_code}" "$ACCESS_URL" | grep -qE "^(200|302|303)"; then
      READY=true
      break
    fi
    echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s ..."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  echo ""
fi

if [[ "$READY" == "true" ]]; then
  success "Omnigent server is up and responding!"
else
  # Show container status and recent logs to aid debugging
  echo ""
  info "Container status:"
  (cd "$OMNIGENT_HOME" && docker compose ps) 2>/dev/null || true
  echo ""
  info "Recent logs:"
  (cd "$OMNIGENT_HOME" && docker compose logs --tail=50) 2>/dev/null || true
  echo ""

  if [[ "$OMNIGENT_TRAEFIK" == "true" ]]; then
    if docker ps --format '{{.Names}}' | grep -q 'omnigent-omnigent'; then
      success "Omnigent container is running (Traefik mode)."
    else
      # error() exits here; the stack (already proven healthy by the gate)
      # must NOT be torn down — it is up, just not reachable via HTTP.
      error "Omnigent container is not running."
    fi
  else
    # error() exits here; the stack (already proven healthy by the gate)
    # must NOT be torn down — it is up, just not answering yet.
    error "Omnigent server did not respond within 120s."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL RUNNER CLI
# ─────────────────────────────────────────────────────────────────────────────

step "Installing runner CLI"

# Install uv if not present
if ! command -v uv &>/dev/null; then
  info "uv not found — installing via official installer..."
  if curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null; then
    # uv's installer drops the binary in ~/.local/bin (or ~/.cargo/bin)
    # and wires PATH for future shells; pull it onto PATH for the rest of this run.
    for d in "$HOME/.local/bin" "$HOME/.cargo/bin"; do
      if [ -x "$d/uv" ]; then
        PATH="$d:$PATH"
        export PATH
        break
      fi
    done
    success "uv installed."
  else
    warn "Failed to install uv. You may need to install it manually: https://docs.astral.sh/uv/getting-started/installation/"
  fi
else
  info "uv is already available."
fi

# Install omnigent CLI (prefer Python 3.12, fall back to system default)
if command -v python3.12 &>/dev/null; then
  info "Installing omnigent with Python 3.12..."
  uv tool install --force -q --python 3.12 omnigent
else
  info "Installing omnigent (using system Python)..."
  uv tool install --force -q omnigent
fi

# Ensure uv bin dir is on PATH
UV_BIN_DIR="$(uv tool dir --bin 2>/dev/null || echo "$HOME/.local/bin")"
if ! echo ":$PATH:" | grep -q ":$UV_BIN_DIR:"; then
  info "Adding $UV_BIN_DIR to PATH..."
  export PATH="$UV_BIN_DIR:$PATH"
  # Also add to profile for future shells
  PROFILE="$(
    case "$(uname -s):${SHELL:-}" in
      Darwin:*/zsh)       printf '%s/.zprofile' "$HOME" ;;
      Darwin:*/bash)      printf '%s/.bash_profile' "$HOME" ;;
      Linux:*/zsh)        printf '%s/.zshrc' "$HOME" ;;
      Linux:*/bash)       printf '%s/.bashrc' "$HOME" ;;
      *)                  printf '%s/.profile' "$HOME" ;;
    esac
  )"
  BEGIN_MARKER="# >>> Omnigent installer >>>"
  END_MARKER="# <<< Omnigent installer <<<"
  PATH_LINE="export PATH=\"$UV_BIN_DIR:\$PATH\""

  if [ -f "$PROFILE" ] && grep -qF "$BEGIN_MARKER" "$PROFILE" 2>/dev/null; then
    if grep -qF "$PATH_LINE" "$PROFILE" 2>/dev/null; then
      info "PATH already configured in $PROFILE"
    else
      {
        printf '\n%s\n' "$BEGIN_MARKER"
        printf '%s\n' "$PATH_LINE"
        printf '%s\n' "$END_MARKER"
      } >> "$PROFILE"
      info "Added $UV_BIN_DIR to PATH in $PROFILE"
    fi
  else
    {
      printf '\n%s\n' "$BEGIN_MARKER"
      printf '%s\n' "$PATH_LINE"
      printf '%s\n' "$END_MARKER"
    } >> "$PROFILE"
    info "Added $UV_BIN_DIR to PATH in $PROFILE"
  fi
fi

# Ensure omnigent is upgraded to the latest version
echo "Updating omnigent cli to the latest version..."
omnigent upgrade

# Verify installation
if omnigent --help &>/dev/null; then
  success "Omnigent CLI installed successfully."
else
  warn "omnigent CLI may not be fully ready yet. Run 'omnigent --help' to verify."
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PREREQUISITES (tmux, bubblewrap, Node.js 22+)
# ─────────────────────────────────────────────────────────────────────────────

step "Checking runner prerequisites"

# tmux
if command -v tmux &>/dev/null; then
  info "tmux is available."
else
  case "$(uname -s)" in
    Darwin)
      if command -v brew &>/dev/null; then
        info "Installing tmux via brew..."
        if brew install tmux 2>/dev/null; then
          success "tmux installed."
        else
          warn "tmux install failed."
        fi
      else
        warn "tmux not found. Install with: brew install tmux"
      fi
      ;;
    Linux)
      if command -v apt-get &>/dev/null; then
        info "Installing tmux via apt..."
        if sudo apt-get install -y tmux 2>/dev/null; then
          success "tmux installed."
        else
          warn "tmux install failed."
        fi
      elif command -v dnf &>/dev/null; then
        info "Installing tmux via dnf..."
        if sudo dnf install -y tmux 2>/dev/null; then
          success "tmux installed."
        else
          warn "tmux install failed."
        fi
      else
        warn "tmux not found. Install with your package manager."
      fi
      ;;
  esac
fi

# bubblewrap (Linux only)
if [ "$(uname -s)" = Linux ]; then
  if command -v bwrap &>/dev/null; then
    info "bubblewrap (bwrap) is available."
  else
    if command -v apt-get &>/dev/null; then
      info "Installing bubblewrap via apt..."
      if sudo apt-get install -y bubblewrap 2>/dev/null; then
        success "bubblewrap installed."
      else
        warn "bubblewrap install failed."
      fi
    elif command -v dnf &>/dev/null; then
      info "Installing bubblewrap via dnf..."
      if sudo dnf install -y bubblewrap 2>/dev/null; then
        success "bubblewrap installed."
      else
        warn "bubblewrap install failed."
      fi
    else
      warn "bubblewrap not found. Install with your package manager."
    fi
  fi
fi

# Node.js 22+ (probe worker_threads.markAsUncloneable, not version string)
if ! command -v node &>/dev/null || ! node -e "process.exit(typeof require('node:worker_threads').markAsUncloneable === 'function' ? 0 : 1)" &>/dev/null; then
  warn "Node.js 22+ not found (needed for Claude/Codex/Pi harnesses)."
  warn "Install from: https://nodejs.org"
else
  info "Node.js 22+ is available."
fi

# npm (needed to install the harness CLIs)
if ! command -v npm &>/dev/null; then
  warn "npm not found — needed to install the Claude/Codex/Pi harness CLIs (https://nodejs.org)."
else
  info "npm is available."
fi

# ─────────────────────────────────────────────────────────────────────────────
# MANUAL REGISTRATION INSTRUCTIONS
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# UFW RULE (direct mode only)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$OMNIGENT_TRAEFIK" != "true" ]]; then
  ufw_add_rule "$OMNIGENT_PORT" tcp "Omnigent server"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUCCESS — disable cleanup trap
# ─────────────────────────────────────────────────────────────────────────────

trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

# Determine server URL (needed for SUMMARY and Runner Registration sections)
if [[ "$OMNIGENT_TRAEFIK" == "true" ]]; then
  OMNIGENT_SERVER_URL="https://${OMNIGENT_DOMAIN}"
else
  OMNIGENT_SERVER_URL="http://localhost:${OMNIGENT_PORT}"
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Omnigent setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${RESET}"
echo ""

if [[ "$OMNIGENT_TRAEFIK" == "true" ]]; then
  echo -e "  ${BOLD}Web UI (Traefik)${RESET}   https://${OMNIGENT_DOMAIN}"
  echo -e "  ${BOLD}TLS${RESET}                Enabled via Let's Encrypt"
else
  echo -e "  ${BOLD}Web UI${RESET}             http://localhost:${OMNIGENT_PORT}"
fi

echo ""
echo -e "  ${BOLD}Data directory${RESET}     ${OMNIGENT_HOME}"
echo -e "  ${BOLD}Compose file${RESET}       ${COMPOSE_FILE}"
echo -e "  ${BOLD}Environment file${RESET}   ${ENV_FILE}"
# Read admin credentials from .env for display
SUMMARY_ADMIN_USERNAME="$(grep -E '^OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2-)"
echo -e "  ${BOLD}Admin credentials${RESET}  ${SUMMARY_ADMIN_USERNAME}"
echo -e "see $ENV_FILE for the password in the OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD variable"
echo -e "  ${BOLD}Config path${RESET}        /data/config.yaml (in container)"
echo -e "  ${BOLD}Auth tokens${RESET}        ${HOME}/.omnigent/auth_tokens.json (after login)"
echo ""
echo -e "${YELLOW}  Note:${RESET}"
echo -e "  Admin account was auto-created with the credentials shown above."
echo -e "  To change the password: sign in via Web UI → Account menu → Change password."
echo -e "  Register this machine as a runner:  omnigent host ${OMNIGENT_SERVER_URL}"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Follow logs    :  docker compose -f ${COMPOSE_FILE} logs -f"
echo -e "  Stop stack     :  docker compose -f ${COMPOSE_FILE} down"
echo -e "  Start stack    :  docker compose -f ${COMPOSE_FILE} up -d"
echo -e "  Restart stack  :  docker compose -f ${COMPOSE_FILE} restart"
echo -e "  Shell into app :  docker exec -it omnigent-postgres bash"
echo ""

if [[ "$OMNIGENT_TRAEFIK" == "true" ]]; then
  echo -e "${CYAN}  # Traefik-specific debug commands${RESET}"
  echo -e "  Check access logs:  docker logs traefik | grep ${OMNIGENT_DOMAIN}"
  echo -e "  Verify DNS        :  dig ${OMNIGENT_DOMAIN}"
  echo ""
fi

echo -e "${BOLD}🔐 Security Notice:${RESET}"
echo -e "  Your secrets are stored in .env file (mode: 600)."
echo -e "  Do not share this file or expose it publicly without TLS protection."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# RUNNER REGISTRATION INSTRUCTIONS
# ─────────────────────────────────────────────────────────────────────────────

step "Runner Registration instructions"

# Read admin credentials from .env
OMNIGENT_ADMIN_USERNAME="$(grep -E '^OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2-)"
OMNIGENT_ADMIN_PASSWORD="$(grep -E '^OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2-)"

if [[ -z "$OMNIGENT_ADMIN_USERNAME" || -z "$OMNIGENT_ADMIN_PASSWORD" ]]; then
  warn "Admin credentials not found in .env — please set them before registering."
fi

# ── STEP 1: Login ──────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}${BOLD}Step 1: Login to the Omnigent server${RESET}"
echo -e "  Run:  omnigent login ${OMNIGENT_SERVER_URL}"
if [[ -n "$OMNIGENT_ADMIN_USERNAME" && -n "$OMNIGENT_ADMIN_PASSWORD" ]]; then
  echo -e "  ${CYAN}Credentials:${RESET}"
  echo -e "    Username : ${OMNIGENT_ADMIN_USERNAME}"
  echo -e "    Password : see in ${ENV_FILE}"
  echo -e "  ${CYAN}Credentials file:${RESET}  ${ENV_FILE}"
fi

# ── STEP 2: run omnigent setup ───────────────────────────────────
echo ""
echo -e "${YELLOW}${BOLD}Step 2: Run ominigent setup${RESET}"
echo -e "  Run:  omnigent Setup"

# ── STEP 3: Register the host as a runner ───────────────────────────────────
echo ""
echo -e "${YELLOW}${BOLD}Step 3: Register this machine as a runner${RESET}"
echo -e "  Run:  omnigent host ${OMNIGENT_SERVER_URL}"

# ── STEP 4: Verify registration ─────────────────────────────────────────────
echo ""
echo -e "${YELLOW}${BOLD}Step 4: Verify the registration${RESET}"
echo -e "  Run:  omnigent host status"

# ── File locations ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}File locations:${RESET}"
echo -e "  ${BOLD}Omnigent config (in container):${RESET}  /data/config.yaml"
echo -e "  ${BOLD}Environment / secrets:${RESET}           ${ENV_FILE}"
echo -e "  ${BOLD}Compose file:${RESET}                    ${COMPOSE_FILE}"
echo -e "  ${BOLD}Auth tokens (after login):${RESET}        ${HOME}/.omnigent/auth_tokens.json"
echo -e "  ${BOLD}Runner CLI config:${RESET}               ${HOME}/.omnigent/"
echo ""

# ── Quick reference ─────────────────────────────────────────────────────────
echo -e "${BOLD}Quick reference:${RESET}"
if [[ -n "$OMNIGENT_ADMIN_USERNAME" && -n "$OMNIGENT_ADMIN_PASSWORD" ]]; then
  echo -e "  ${BOLD}Admin login:${RESET}  ${OMNIGENT_SERVER_URL} → ${OMNIGENT_ADMIN_USERNAME} / see ${ENV_FILE} -> OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD"
else
  echo -e "  ${BOLD}Admin login:${RESET}  ${OMNIGENT_SERVER_URL} → (credentials not set)"
fi
echo -e "  ${BOLD}Login command:${RESET}  omnigent login ${OMNIGENT_SERVER_URL}"
echo -e "  ${BOLD}Register command:${RESET}  omnigent host ${OMNIGENT_SERVER_URL}"
echo ""

info "For more information, see: https://github.com/omnigent-ai/omnigent"
echo ""

# TODO: add functionality that auto-configures the worker host .
# - Also it should start the host worker process via systemd and keep it started always
