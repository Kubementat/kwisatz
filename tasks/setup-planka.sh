#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-planka.sh — Install Planka Kanban board
# =============================================================================
#
# Description:
#   Deploys Planka, a self-hosted Kanban board, using Docker Compose.
#   Secrets are stored in PLANKA_HOME/.env (mode 600) and reused on re-runs;
#   the generated docker-compose.yml contains no secret values.
#
# Usage:
#   ./setup-planka.sh                 # install with defaults
#   ./setup-planka.sh --help          # show help and all configuration options
#
# All configuration is done via environment variables — run with --help for
# the full list (PLANKA_HOME, BASE_URL, PLANKA_HOST_IP, PLANKA_EXTRA_ORIGINS, ...).
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


# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Deploys Planka (self-hosted Kanban board) using Docker Compose.
Data is stored under PLANKA_HOME (default: /srv/planka).

${BOLD}Options:${RESET}
  --interactive   Offer tear-down/re-create of an existing stack (default:
                  converge); prompt on other risky conditions
                  (weak ADMIN_PASSWORD, …)
  -h, --help      Show this help and exit

${BOLD}Environment variables${RESET} (all optional):

  Application:
    PLANKA_HOME             Data directory (default: /srv/planka)
    PLANKA_IMAGE            Container image (default: $(kw_image planka))
    POSTGRES_IMAGE          Database image (default: $(kw_image planka-postgres), pinned)
    CONTAINER_NAME          Container name (default: planka)
    BASE_URL                Base URL for Planka, and the allowlist of origins Planka
                            accepts socket.io (WebSocket) connections from.
                            Comma-separated list of URLs — every host:port a browser
                            may use to reach Planka must be listed, otherwise
                            realtime features break (Planka's sails config
                            onlyAllowOrigins). Default: http://localhost:HTTP_PORT
                            plus the detected LAN IP (direct mode), or
                            https://PLANKA_DOMAIN (Traefik mode).
    PLANKA_HOST_IP          Host IP used to build the default LAN origin
                            (default: auto-detected, first non-loopback IPv4)
    PLANKA_EXTRA_ORIGINS    Extra comma-separated origins to allow, e.g.
                            http://evobox:1337,http://100.64.0.2:1337
    HTTP_PORT               Host port (default: 1337, ignored when PLANKA_TRAEFIK=true)
    SECRET_KEY              App secret (auto-generated on first run, then reused
                            from PLANKA_HOME/.env on re-runs; set explicitly
                            to override)

  Traefik reverse-proxy integration (opt-in):
    PLANKA_TRAEFIK          Set to "true" to enable Traefik routing (default: false)
    PLANKA_DOMAIN           Domain for Traefik access (required when PLANKA_TRAEFIK=true)
    PROXY_NETWORK           Traefik's external Docker network name (default: proxy)

  PostgreSQL:
    POSTGRES_DB             Database name (default: planka)
    POSTGRES_USER           Database user (default: postgres)
    POSTGRES_PASSWORD       Database password (auto-generated on first run,
                            then reused from PLANKA_HOME/.env on re-runs; set
                            explicitly to override). The former "empty = trust
                            auth" dev mode is gone — a password is always
                            stored (md5 auth). Supplying a different value
                            while PLANKA_HOME/postgres already holds data is
                            refused (the cluster keeps its old password);
                            change it inside the DB instead.

  Startup:
    WAIT_TIMEOUT            Max seconds to wait for the stack to come up and
                            become healthy after 'docker compose up -d'
                            (default: 180)

  Admin user:
    ADMIN_EMAIL             Create admin user non-interactively
                            (default: empty = print the admin-user creation
                            command after startup; with --interactive, prompt
                            to run it now)
    ADMIN_PASSWORD          Admin password
    ADMIN_NAME              Admin display name (default: Admin)
    ADMIN_USERNAME          Admin username (optional, forwarded to Planka)

  Secrets:
    All secrets are stored in PLANKA_HOME/.env (mode 600) and reused on every
    re-run. The generated docker-compose.yml contains no secret values — only
    literal \${VAR} placeholders resolved at runtime via --env-file.

${BOLD}Examples:${RESET}
  $0
  HTTP_PORT=8080 $0
  PLANKA_TRAEFIK=true PLANKA_DOMAIN=planka.example.com $0
  ADMIN_EMAIL=admin@example.com ADMIN_PASSWORD=secret $0
EOF
  exit 0
}


# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive) INTERACTIVE=true ;;
    -h|--help) usage ;;
    *) error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done


# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these variables before running (or export them)
# ─────────────────────────────────────────────────────────────────────────────

PLANKA_HOME="${PLANKA_HOME:-/srv/planka}"
PLANKA_IMAGE="${PLANKA_IMAGE:-$(kw_image planka)}"
# Database image — pinned per stack (ticket improvements-2/17): the tag is the one
# these templates already used, now overridable instead of hard-coded.
# Update deliberately: docker buildx imagetools inspect library/postgres
POSTGRES_IMAGE="${POSTGRES_IMAGE:-$(kw_image planka-postgres)}"
CONTAINER_NAME="${CONTAINER_NAME:-planka}"

HTTP_PORT="${HTTP_PORT:-1337}"
# BASE_URL may stay empty — it is resolved below (localhost + LAN IP by default).
# It doubles as Planka's socket.io origin allowlist (comma-separated URLs).
BASE_URL="${BASE_URL:-}"
PLANKA_HOST_IP="${PLANKA_HOST_IP:-}"
PLANKA_EXTRA_ORIGINS="${PLANKA_EXTRA_ORIGINS:-}"

# Traefik reverse-proxy integration (opt-in)
PLANKA_TRAEFIK="${PLANKA_TRAEFIK:-false}"
PLANKA_DOMAIN="${PLANKA_DOMAIN:-}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"

# PostgreSQL settings
POSTGRES_DB="${POSTGRES_DB:-planka}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
# Database password — auto-generated on first run, then reused from
# ${PLANKA_HOME}/.env on every re-run. The former "empty = trust auth" dev
# mode is gone: a password is always stored (md5 auth).
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

# Application secret key — auto-generated on first run, then reused from
# ${PLANKA_HOME}/.env on every re-run
SECRET_KEY="${SECRET_KEY:-}"

# Admin user (optional — leave ADMIN_EMAIL empty to be prompted after startup)
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ADMIN_NAME="${ADMIN_NAME:-Admin}"
ADMIN_USERNAME="${ADMIN_USERNAME:-}"


# ─────────────────────────────────────────────────────────────────────────────
# LOCAL HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# First non-loopback IPv4 address of this host (empty output if none found).
detect_lan_ip() {
  local ip
  for ip in $(hostname -I 2>/dev/null); do
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != 127.* && "$ip" != 169.254.* ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# Collapse a comma-separated list: trim whitespace, drop empties, dedupe (order kept).
dedupe_csv() {
  printf '%s\n' "$1" | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | awk 'NF && !seen[$0]++' \
    | paste -sd',' -
}


# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

# Docker commands don't require root if user is in docker group
if ! command -v docker &>/dev/null; then
  error "Docker is not installed or not in PATH. Run setup-docker.sh first."
fi

if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi

if ! command -v openssl &>/dev/null; then
  error "openssl is not installed. Install it with: apt-get install openssl"
fi

success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

# Traefik pre-flight (only when opt-in)
if [[ "$PLANKA_TRAEFIK" == "true" ]]; then
  if ! ensure_proxy_network; then
    error "Traefik proxy network '${PROXY_NETWORK}' not found or inaccessible."
  fi
  if [[ -z "$PLANKA_DOMAIN" ]]; then
    error "PLANKA_DOMAIN must be set when PLANKA_TRAEFIK=true."
  fi
  # Auto-set BASE_URL for Traefik mode
  BASE_URL="https://${PLANKA_DOMAIN}"
fi

# Warn if admin password looks weak
if [[ -n "$ADMIN_EMAIL" && -n "$ADMIN_PASSWORD" && ${#ADMIN_PASSWORD} -lt 8 ]]; then
  warn "ADMIN_PASSWORD is shorter than 8 characters — consider a stronger password."
  if [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Continue anyway? [y/N] " _ans
    [[ "${_ans,,}" == "y" ]] || exit 0
  else
    error "ADMIN_PASSWORD is shorter than 8 characters. Set a stronger ADMIN_PASSWORD (at least 8 characters) and re-run, or re-run with --interactive to confirm manually."
  fi
fi


# ─────────────────────────────────────────────────────────────────────────────
# RESOLVE BASE_URL (also Planka's socket.io origin allowlist)
# ─────────────────────────────────────────────────────────────────────────────
#
# Planka whitelists WebSocket origins from BASE_URL: it accepts a comma-separated
# list of URLs and only accepts socket.io connections from those origins
# (server/config/env/production.js: onlyAllowOrigins). Every host:port a browser
# may use to reach Planka must be listed, otherwise the WebSocket handshake is
# rejected and realtime features break.

step "Resolving BASE_URL (socket origin allowlist)"

LAN_IP="${PLANKA_HOST_IP:-}"

if [[ "$PLANKA_TRAEFIK" != "true" && -z "$BASE_URL" ]]; then
  BASE_URL="http://localhost:${HTTP_PORT}"
  if [[ -z "$LAN_IP" ]]; then
    LAN_IP="$(detect_lan_ip || true)"
  fi
  if [[ -n "$LAN_IP" ]]; then
    BASE_URL="${BASE_URL},http://${LAN_IP}:${HTTP_PORT}"
    info "Included LAN origin http://${LAN_IP}:${HTTP_PORT} (override with PLANKA_HOST_IP)."
  else
    warn "Could not detect a LAN IP — allowlist is localhost only. Set PLANKA_HOST_IP for LAN access."
  fi
fi

if [[ -n "$PLANKA_EXTRA_ORIGINS" ]]; then
  BASE_URL="${BASE_URL},${PLANKA_EXTRA_ORIGINS}"
fi
BASE_URL="$(dedupe_csv "$BASE_URL")"

# Warn if the allowlist only covers loopback — LAN browsers would be rejected.
IFS=',' read -ra _allowlist <<< "$BASE_URL"
_loopback_only=true
for _entry in "${_allowlist[@]}"; do
  _host="${_entry#*://}"; _host="${_host%%/*}"; _host="${_host%%:*}"
  if [[ "$_host" != "localhost" && "$_host" != "127.0.0.1" ]]; then
    _loopback_only=false
    break
  fi
done
if [[ "$_loopback_only" == "true" ]]; then
  warn "BASE_URL only contains loopback origins — browsers on other machines will"
  warn "fail the WebSocket handshake (realtime features break). Add e.g."
  warn "PLANKA_HOST_IP=<your host IP> or PLANKA_EXTRA_ORIGINS=http://<host>:${HTTP_PORT}"
fi

success "BASE_URL: ${BASE_URL}"


# ─────────────────────────────────────────────────────────────────────────────
# SECRETS — REUSE, GENERATE, PERSIST (.env, mode 600)
# ─────────────────────────────────────────────────────────────────────────────
#
# ${PLANKA_HOME}/.env is the source of truth for SECRET_KEY and
# POSTGRES_PASSWORD: a re-run must reuse the stored values, because the
# Postgres cluster (data dir ${PLANKA_HOME}/postgres) honours the password it
# was initialised with and the app's sessions are tied to SECRET_KEY.
# The compose file never contains secret values — only ${VAR} references,
# resolved at runtime from this .env via --env-file.
#
# This happens BEFORE the existing-stack check below on purpose: reuse and
# the drift check must run even when the script exits early there.

ENV_FILE="${PLANKA_HOME}/.env"
COMPOSE_FILE="${PLANKA_HOME}/docker-compose.yml"

# Capture whether the operator supplied POSTGRES_PASSWORD via the environment
# on THIS run, before any .env reuse can answer the question (drift check).
POSTGRES_PASSWORD_SUPPLIED=0
[[ -n "${POSTGRES_PASSWORD:-}" ]] && POSTGRES_PASSWORD_SUPPLIED=1

step "Reusing existing secrets where present"

_stored_pg_pw=""
if [[ -f "$ENV_FILE" ]]; then
  info "Found ${ENV_FILE} — reusing stored secrets."
  SECRET_KEY="${SECRET_KEY:-$(env_file_get "$ENV_FILE" SECRET_KEY)}"
  _stored_pg_pw="$(env_file_get "$ENV_FILE" POSTGRES_PASSWORD)"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$_stored_pg_pw}"
fi

[[ -n "$SECRET_KEY" ]] || { SECRET_KEY="$(openssl rand -hex 64)"; info "Generated a new SECRET_KEY."; }
[[ -n "$POSTGRES_PASSWORD" ]] || { POSTGRES_PASSWORD="$(openssl rand -hex 24)"; info "Generated a new POSTGRES_PASSWORD."; }

# A deliberately changed password against a populated cluster would leave the
# stack broken: the postgres image honours POSTGRES_PASSWORD only while its
# data dir is empty. Fail with instructions instead of silently producing a
# broken stack.
if [[ "${POSTGRES_PASSWORD_SUPPLIED}" == "1" && "${POSTGRES_PASSWORD}" != "${_stored_pg_pw}" \
      && -n "$(ls -A "${PLANKA_HOME}/postgres" 2>/dev/null)" ]]; then
  error "POSTGRES_PASSWORD was supplied but differs from the password of the existing cluster in ${PLANKA_HOME}/postgres. The cluster keeps its old password, so the stack would come up broken. Change the password inside the DB instead:
    docker exec -it ${CONTAINER_NAME}-postgres psql -U ${POSTGRES_USER} -c \"ALTER USER ${POSTGRES_USER} PASSWORD '<new-password>'\"
  then update POSTGRES_PASSWORD and DATABASE_URL in ${ENV_FILE} and re-run."
fi

# DATABASE_URL is derived once and lives only in the .env (never in compose).
DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres/${POSTGRES_DB}"
PG_AUTH_METHOD="md5"

step "Writing ${ENV_FILE} (mode 600)"
#
# Written with printf (never a heredoc that could expand values). Owned by the
# invoking user, mode 600 — NOT root:root, because docker compose --env-file
# runs as the invoking user and cannot read a root-owned 600 file. No
# timestamp line: a no-op re-run must produce byte-identical content so the
# backup check below (and operators comparing checksums) see a stable file.
_env_new="$(mktemp)"
{
  printf '# Planka secrets — KEEP SECURE (mode 600). Re-runs reuse these values.\n'
  printf 'SECRET_KEY=%s\n'        "${SECRET_KEY}"
  printf 'POSTGRES_DB=%s\n'       "${POSTGRES_DB}"
  printf 'POSTGRES_USER=%s\n'     "${POSTGRES_USER}"
  printf 'POSTGRES_PASSWORD=%s\n' "${POSTGRES_PASSWORD}"
  printf 'DATABASE_URL=%s\n'      "${DATABASE_URL}"
  printf 'PG_AUTH_METHOD=%s\n'    "${PG_AUTH_METHOD}"
} > "$_env_new"
# Parent dir must exist for the install (fresh machines create it here; the
# storage subdirectories are created by the next section).
sudo mkdir -p "${PLANKA_HOME}"
# Back up only on an actual content change, so a no-op re-run never clobbers a good .env.bak
if [[ -f "$ENV_FILE" ]] && ! sudo cmp -s "$_env_new" "$ENV_FILE"; then
  sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "$ENV_FILE" "${ENV_FILE}.bak"
fi
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "$_env_new" "$ENV_FILE"
rm -f "$_env_new"
success "Secrets stored in ${ENV_FILE} (mode 600, owner: $(id -un))."


# ─────────────────────────────────────────────────────────────────────────────
# STOP & REMOVE EXISTING COMPOSE STACK (if any)
# ─────────────────────────────────────────────────────────────────────────────

step "Checking for an existing Planka compose stack"

if [[ -f "$COMPOSE_FILE" ]]; then
  warn "Existing docker-compose.yml found at ${COMPOSE_FILE}."
  # Re-run policy (ticket 12): the existing stack is CONVERGED — the compose
  # file is re-rendered, the secrets in ${ENV_FILE} are reused (never
  # rotated), and 'docker compose up -d' reconciles only what changed.
  # Tear-down only on explicit interactive 'y'.
  info "Re-running will converge the existing stack (no tear-down). Data in ${PLANKA_HOME}/data is preserved."
  RECREATE=false
  if [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Stack exists. Converge (default) or tear down and re-create? [c/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      RECREATE=true
    fi
  fi
  if [[ "$RECREATE" == "true" ]]; then
    info "Stopping and removing existing stack..."
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down 2>/dev/null || true
    success "Old stack removed."
  fi
fi


# ─────────────────────────────────────────────────────────────────────────────
# CREATE PERSISTENT HOST DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────

step "Creating persistent storage directories under ${PLANKA_HOME}"

# Create directories with sudo since /srv requires elevated privileges
sudo mkdir -p "${PLANKA_HOME}/data" "${PLANKA_HOME}/postgres"

# Planka's Node process runs as UID 1000 — ensure it can write to the data dir
# Also make postgres directory writable (PostgreSQL container may need to create files there)
# Change ownership of the entire PLANKA_HOME so we can write docker-compose.yml as regular user
sudo chown -R 1000:1000 "${PLANKA_HOME}" || {
  warn "Could not change ownership of ${PLANKA_HOME}. You may need to run this script with sudo."
}
success "Directories ready."

success "Directories ready."


# ─────────────────────────────────────────────────────────────────────────────
# GENERATE DOCKER COMPOSE FILE
# ─────────────────────────────────────────────────────────────────────────────

step "Generating ${COMPOSE_FILE}"

# Render docker-compose.yml from template
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/planka"
command -v envsubst || error "envsubst not installed — install with: sudo apt-get install gettext-base"

# Select compose variant: deployment mode x postgres password presence.
# A POSTGRES_PASSWORD is now always set (md5 auth, value in ${ENV_FILE}), so
# the .password variants — content-identical to the base ones and marked
# superseded there — are always selected. Variant consolidation is ticket 19.
if [[ "$PLANKA_TRAEFIK" == "true" ]]; then
  _planka_mode="traefik"
else
  _planka_mode="direct"
fi
if [[ -n "$POSTGRES_PASSWORD" ]]; then
  _planka_pw=".password"
else
  _planka_pw=""
fi
TEMPLATE_FILE="${TEMPLATE_DIR}/docker-compose.${_planka_mode}${_planka_pw}.yml"

# LAN hint suffix for the ports comment (empty when no LAN IP is set)
_planka_lan_suffix="${LAN_IP:+, http://${LAN_IP}:${HTTP_PORT}}"

# Export variables for envsubst (explicit list, never bare envsubst).
# Layout values ONLY — secrets (SECRET_KEY, POSTGRES_PASSWORD, DATABASE_URL,
# PG_AUTH_METHOD) are never substituted: they stay ${VAR}-literal in the
# rendered file and are resolved at runtime from ${ENV_FILE} via --env-file.
export PLANKA_IMAGE POSTGRES_IMAGE CONTAINER_NAME PLANKA_HOME BASE_URL \
  POSTGRES_DB POSTGRES_USER
if [[ "$PLANKA_TRAEFIK" == "true" ]]; then
  export PROXY_NETWORK PLANKA_DOMAIN
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${PLANKA_IMAGE} ${POSTGRES_IMAGE} ${CONTAINER_NAME} ${PLANKA_HOME} ${BASE_URL} ${PROXY_NETWORK} ${PLANKA_DOMAIN} ${POSTGRES_DB} ${POSTGRES_USER}' \
    < "${TEMPLATE_FILE}" > "$COMPOSE_FILE"
else
  export HTTP_PORT _planka_lan_suffix
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${PLANKA_IMAGE} ${POSTGRES_IMAGE} ${CONTAINER_NAME} ${HTTP_PORT} ${_planka_lan_suffix} ${PLANKA_HOME} ${BASE_URL} ${POSTGRES_DB} ${POSTGRES_USER}' \
    < "${TEMPLATE_FILE}" > "$COMPOSE_FILE"
fi

success "docker-compose.yml written to ${COMPOSE_FILE}"


# ─────────────────────────────────────────────────────────────────────────────
# PULL IMAGES
# ─────────────────────────────────────────────────────────────────────────────

step "Pulling Docker images"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull
success "Images pulled."


# ─────────────────────────────────────────────────────────────────────────────
# START THE STACK
# ─────────────────────────────────────────────────────────────────────────────

step "Starting Planka stack (detached)"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

# Health gate: prove the containers are actually up before reporting success.
mapfile -t _ids < <(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps -q)
wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
  || error "Planka stack did not come up — see the status output above"


# ─────────────────────────────────────────────────────────────────────────────
# WAIT FOR PLANKA TO BECOME AVAILABLE
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for Planka web UI to respond on port ${HTTP_PORT}"

MAX_WAIT=120
INTERVAL=5
ELAPSED=0
READY=false

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HTTP_PORT}" || true)
  if echo "$HTTP_CODE" | grep -qE "^(200|302|303|401)"; then
    READY=true
    break
  fi
  echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s (HTTP ${HTTP_CODE}) ..."
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""

if [[ "$READY" == "true" ]]; then
  success "Planka is up and responding!"
else
  if [[ "$PLANKA_TRAEFIK" == "true" ]]; then
    warn "Planka did not respond within ${MAX_WAIT}s."
    warn "It may still be starting, or DNS/TLS may need time to propagate."
    warn "  Check container: docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs -f"
    warn "  Check Traefik:  docker logs traefik | grep ${PLANKA_DOMAIN}"
  else
    warn "Planka did not respond within ${MAX_WAIT}s."
    warn "It may still be starting. Check logs with:"
    warn "  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs -f"
  fi
fi


# ─────────────────────────────────────────────────────────────────────────────
# CREATE ADMIN USER
# ─────────────────────────────────────────────────────────────────────────────

step "Creating admin user"

if [[ -n "$ADMIN_EMAIL" && -n "$ADMIN_PASSWORD" ]]; then
  info "Creating admin user non-interactively (${ADMIN_EMAIL})..."
  if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" run --rm planka \
    npm run db:create-admin-user -- \
      --email "${ADMIN_EMAIL}" \
      --password "${ADMIN_PASSWORD}" \
      --name "${ADMIN_NAME}" \
      ${ADMIN_USERNAME:+--username "${ADMIN_USERNAME}"}
  then
    success "Admin user '${ADMIN_EMAIL}' created."
  else
    warn "Admin user creation failed — the user may already exist, or Planka is still initialising."
  fi
else
  if [[ "$INTERACTIVE" == "true" ]]; then
    info "No ADMIN_EMAIL/ADMIN_PASSWORD provided — run interactively now:"
  else
    info "No ADMIN_EMAIL/ADMIN_PASSWORD provided — create the admin user later:"
  fi
  echo ""
  echo -e "  ${BOLD}docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} run --rm planka npm run db:create-admin-user${RESET}"
  echo ""
  if [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Create admin user interactively now? [Y/n] " _create
    if [[ "${_create,,}" != "n" ]]; then
      if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" run --rm planka npm run db:create-admin-user
      then
        success "Admin user created."
      else
        warn "Interactive admin creation exited with an error. You can re-run the command above later."
      fi
    else
      info "Skipping admin user creation. Remember to create one before first use."
    fi
  else
    info "Non-interactive mode: skipping interactive admin user creation (optional post-setup step)."
    info "Run the command above to create the admin user, or set ADMIN_EMAIL/ADMIN_PASSWORD and re-run."
    exit 0
  fi
fi


# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Planka setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Web UI${RESET}           ${BASE_URL}"
if [[ "$PLANKA_TRAEFIK" != "true" ]]; then
  echo -e "  ${BOLD}Local port${RESET}       http://localhost:${HTTP_PORT}"
  if [[ -n "$LAN_IP" ]]; then
    echo -e "  ${BOLD}LAN access${RESET}       http://${LAN_IP}:${HTTP_PORT}"
  fi
fi
echo -e "  ${BOLD}Socket origins${RESET}   ${BASE_URL}"
echo -e "  ${BOLD}Data directory${RESET}   ${PLANKA_HOME}/data"
echo -e "  ${BOLD}DB directory${RESET}     ${PLANKA_HOME}/postgres"
echo -e "  ${BOLD}Compose file${RESET}     ${COMPOSE_FILE}"
echo ""
if [[ -n "$ADMIN_EMAIL" ]]; then
  echo -e "  ${BOLD}Admin email${RESET}      ${ADMIN_EMAIL}"
  echo ""
fi
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Follow logs        :  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs -f"
echo -e "  Stop stack         :  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} down"
echo -e "  Start stack        :  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} up -d"
echo -e "  Restart stack      :  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} restart"
echo -e "  Shell into app     :  docker exec -it ${CONTAINER_NAME} sh"
echo -e "  Create admin user  :  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} run --rm planka npm run db:create-admin-user"
if [[ "$PLANKA_TRAEFIK" == "true" ]]; then
  echo ""
  echo -e "${CYAN}  # Traefik-specific debug commands${RESET}"
  echo -e "  Check access logs:  docker logs traefik | grep ${PLANKA_DOMAIN}"
  echo -e "  Verify DNS       :  dig ${PLANKA_DOMAIN}"
fi
echo ""
