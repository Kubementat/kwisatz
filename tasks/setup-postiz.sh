#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-postiz.sh — Install Postiz social-media scheduler
# =============================================================================
#
# Description:
#   Deploys Postiz (self-hosted social-media scheduler, 28+ platforms) with
#   Docker Compose: Postiz app + PostgreSQL + Redis + the full Temporal stack
#   (auto-setup, its PostgreSQL, Elasticsearch, UI). Postiz v2.12+ requires
#   Temporal for cron/scheduled posting (RUN_CRON=true).
#
#   Secrets are stored in POSTIZ_HOME/.env (mode 600) and reused on re-runs;
#   the generated docker-compose.yml contains no secret values.
#
#   Based on the official gitroomhq/postiz-docker-compose compose file
#   (checked 2026-09-30), slimmed per docs/plans/postiz-setup.md: no
#   `spotlight` debug profile, no `temporal-admin-tools` tty container
#   (`docker exec -it temporal temporal …` covers CLI needs), temporal-ui
#   bound to 127.0.0.1:18080.
#
# Usage:
#   ./setup-postiz.sh                 # install with defaults
#   ./setup-postiz.sh --help          # show help and all configuration options
#
# All configuration is done via environment variables — run with --help for
# the full list (POSTIZ_HOME, HTTP_PORT, POSTIZ_TRAEFIK, POSTIZ_DOMAIN, ...).
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

Deploys Postiz (self-hosted social-media scheduler) using Docker Compose:
Postiz app + PostgreSQL + Redis + Temporal (auto-setup, PostgreSQL,
Elasticsearch, UI). Data is stored under POSTIZ_HOME (default: /srv/postiz).

${BOLD}Options:${RESET}
  -h, --help      Show this help and exit

${BOLD}Environment variables${RESET} (all optional):

  Application:
    POSTIZ_HOME             Data directory (default: /srv/postiz)
    POSTIZ_IMAGE            Container image (default: ghcr.io/gitroomhq/postiz-app:v2.24.0, pinned)
    HTTP_PORT               Host port for the Postiz web UI (default: 4007,
                            ignored when POSTIZ_TRAEFIK=true)
    POSTIZ_HOST_IP          Host IP used to build the default MAIN_URL in
                            direct mode (default: auto-detected, first
                            non-loopback IPv4; falls back to localhost)
    OPENAI_API_KEY          Optional — enables Postiz AI features
                            (stored in the .env, forwarded to the app)
    POSTIZ_DISABLE_REGISTRATION
                            'true' to lock public signup after the first org
                            exists (default: true). Postiz still allows exactly
                            the FIRST registration when the org count is 0,
                            which is what the admin bootstrap below uses.

  Admin bootstrap (organization + first user, created via the API):
    POSTIZ_ADMIN_EMAIL      Email of the admin user (default on fresh
                            install: the machine user's email — global git
                            config user.email, else <user>@<host>.local)
    POSTIZ_ADMIN_ORG        Organization name (default: my organization)
    POSTIZ_ADMIN_PASSWORD   Admin password (auto-generated on first run,
                            stored in the .env, reused on re-runs)
    The script logs in first (re-runs) and registers only when the account
    does not exist yet; it then stores the organization's auto-generated API
    key as POSTIZ_API_KEY in the .env. Idempotent — see
    docs/research/postiz-auto-config-2026-09-30.md.

  Traefik reverse-proxy integration (opt-in):
    POSTIZ_TRAEFIK          Set to "true" to enable Traefik routing (default: false)
    POSTIZ_DOMAIN           Domain for Traefik access (required when POSTIZ_TRAEFIK=true)
    PROXY_NETWORK           Traefik's external Docker network name (default: proxy)

  Temporal stack images (pinned — update deliberately):
    POSTGRES_IMAGE          Postiz DB image (default: postgres:17-alpine)
    TEMPORAL_POSTGRES_IMAGE Temporal DB image (default: postgres:16)
    REDIS_IMAGE             Redis image (default: redis:7.2)
    ES_IMAGE                Temporal visibility index (default: elasticsearch:7.17.27)
    TEMPORAL_IMAGE          Temporal auto-setup (default: temporalio/auto-setup:1.28.1)
    TEMPORAL_UI_IMAGE       Temporal UI (default: temporalio/ui:2.34.0)
    TEMPORAL_UI_PORT        Temporal UI host port, loopback-only (default: 18080)

  Startup:
    WAIT_TIMEOUT            Max seconds to wait for the stack to come up and
                            become healthy after 'docker compose up -d'
                            (default: 300 — Elasticsearch + Temporal need
                            longer than the 180 s house default)

  Secrets:
    JWT_SECRET              Postiz JWT secret (auto-generated on first run,
                            then reused from POSTIZ_HOME/.env on re-runs)
    POSTGRES_PASSWORD       Postiz DB password (auto-generated on first run,
                            then reused from POSTIZ_HOME/.env on re-runs)
    TEMPORAL_POSTGRES_PASSWORD
                            Temporal DB password (auto-generated on first run,
                            then reused from POSTIZ_HOME/.env on re-runs)
    All secrets are stored in POSTIZ_HOME/.env (mode 600) and reused on every
    re-run. The generated docker-compose.yml contains no secret values — only
    literal \${VAR} placeholders resolved at runtime via --env-file.

${BOLD}Examples:${RESET}
  $0
  HTTP_PORT=8080 $0
  POSTIZ_TRAEFIK=true POSTIZ_DOMAIN=postiz.example.com $0

${BOLD}Note:${RESET} On first start the script creates the organization and the
first admin user via the Postiz API and locks registration (default).
Platform integrations (LinkedIn/X/dev.to/Reddit) and the Postiz MCP server
are still UI/agent steps — the script prints the checklist at the end.

${BOLD}Re-run policy${RESET} (converge by default): re-running an existing stack
converges it — config is re-rendered, secrets are reused (never rotated),
'docker compose up -d' reconciles only what changed, and the health gate
re-verifies the stack. No tear-down. See specification/project/conventions.md.
EOF
  exit 0
}


# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    *) error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done


# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these variables before running (or export them)
# ─────────────────────────────────────────────────────────────────────────────

POSTIZ_HOME="${POSTIZ_HOME:-/srv/postiz}"
HTTP_PORT="${HTTP_PORT:-4007}"
POSTIZ_HOST_IP="${POSTIZ_HOST_IP:-}"

# Traefik reverse-proxy integration (opt-in)
POSTIZ_TRAEFIK="${POSTIZ_TRAEFIK:-false}"
POSTIZ_DOMAIN="${POSTIZ_DOMAIN:-}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"

# Image pins — matched to the official gitroomhq/postiz-docker-compose as of
# 2026-09-30; the Postiz app tag is the newest release at implementation time
# (checked 2026-10-01 via the GHCR tag list / GitHub releases).
# Update deliberately: ghcr tag list for gitroomhq/postiz-app, GitHub releases
# for the Temporal images.
POSTIZ_IMAGE="${POSTIZ_IMAGE:-ghcr.io/gitroomhq/postiz-app:v2.24.0}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"
TEMPORAL_POSTGRES_IMAGE="${TEMPORAL_POSTGRES_IMAGE:-postgres:16}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7.2}"
ES_IMAGE="${ES_IMAGE:-elasticsearch:7.17.27}"
TEMPORAL_IMAGE="${TEMPORAL_IMAGE:-temporalio/auto-setup:1.28.1}"
TEMPORAL_UI_IMAGE="${TEMPORAL_UI_IMAGE:-temporalio/ui:2.34.0}"
TEMPORAL_UI_PORT="${TEMPORAL_UI_PORT:-18080}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

# Admin bootstrap — the script creates org + first user via the Postiz API
# (login-first, register-fallback; Postiz has no seed mechanism — see
# docs/research/postiz-auto-config-2026-09-30.md). Persisted in the .env.
POSTIZ_ADMIN_EMAIL="${POSTIZ_ADMIN_EMAIL:-}"
POSTIZ_ADMIN_ORG="${POSTIZ_ADMIN_ORG:-}"
POSTIZ_ADMIN_PASSWORD="${POSTIZ_ADMIN_PASSWORD:-}"
POSTIZ_API_KEY="${POSTIZ_API_KEY:-}"

# Read back from the .env before writing it (see below) — a default here would
# silently clobber operator-edited .env values on re-runs.
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
POSTIZ_DISABLE_REGISTRATION="${POSTIZ_DISABLE_REGISTRATION:-}"

# Secrets — auto-generated on first run, then reused from POSTIZ_HOME/.env.
JWT_SECRET="${JWT_SECRET:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
TEMPORAL_POSTGRES_PASSWORD="${TEMPORAL_POSTGRES_PASSWORD:-}"

for _img in "$POSTIZ_IMAGE" "$POSTGRES_IMAGE" "$TEMPORAL_POSTGRES_IMAGE" \
  "$REDIS_IMAGE" "$ES_IMAGE" "$TEMPORAL_IMAGE" "$TEMPORAL_UI_IMAGE"; do
  warn_moving_image "$_img" "image"
done

ENV_FILE="${POSTIZ_HOME}/.env"
COMPOSE_FILE="${POSTIZ_HOME}/docker-compose.yml"


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


# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

if ! command -v docker &>/dev/null; then
  error "Docker is not installed or not in PATH. Run setup-docker.sh first."
fi

if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi

if ! command -v openssl &>/dev/null; then
  error "openssl is not installed. Install it with: apt-get install openssl"
fi

if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Install it with: sudo apt-get install gettext-base"
fi

if ! command -v curl &>/dev/null; then
  error "curl is not installed. Install it with: apt-get install curl"
fi

if ! command -v jq &>/dev/null; then
  error "jq is not installed. Install it with: apt-get install jq"
fi

success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

# Traefik pre-flight (only when opt-in)
if [[ "$POSTIZ_TRAEFIK" == "true" ]]; then
  if ! ensure_proxy_network; then
    error "Traefik proxy network '${PROXY_NETWORK}' not found or inaccessible."
  fi
  if [[ -z "$POSTIZ_DOMAIN" ]]; then
    error "POSTIZ_DOMAIN must be set when POSTIZ_TRAEFIK=true."
  fi
fi


# ─────────────────────────────────────────────────────────────────────────────
# RESOLVE MAIN_URL
# ─────────────────────────────────────────────────────────────────────────────
#
# Postiz bakes MAIN_URL/FRONTEND_URL/NEXT_PUBLIC_BACKEND_URL into the frontend
# (the NEXT_PUBLIC_* values are used in the browser), so the host part must be
# reachable from wherever the browser sits — the LAN IP in direct mode, the
# Traefik domain in proxy mode.

step "Resolving MAIN_URL"

if [[ "$POSTIZ_TRAEFIK" == "true" ]]; then
  MAIN_URL="https://${POSTIZ_DOMAIN}"
else
  _host="${POSTIZ_HOST_IP:-$(detect_lan_ip || true)}"
  if [[ -z "$_host" ]]; then
    _host="localhost"
    warn "Could not detect a LAN IP — MAIN_URL is localhost only. Set POSTIZ_HOST_IP for LAN access."
  else
    info "Using host ${_host} for MAIN_URL (override with POSTIZ_HOST_IP)."
  fi
  MAIN_URL="http://${_host}:${HTTP_PORT}"
fi
NEXT_PUBLIC_BACKEND_URL="${MAIN_URL}/api"
success "MAIN_URL: ${MAIN_URL}"


# ─────────────────────────────────────────────────────────────────────────────
# SECRETS — REUSE, GENERATE, PERSIST (.env, mode 600)
# ─────────────────────────────────────────────────────────────────────────────
#
# ${POSTIZ_HOME}/.env is the source of truth for JWT_SECRET, POSTGRES_PASSWORD
# and TEMPORAL_POSTGRES_PASSWORD: a re-run must reuse the stored values,
# because both Postgres data dirs honour the password they were initialised
# with and Postiz sessions are tied to JWT_SECRET. The compose file never
# contains secret values — only ${VAR} references, resolved at runtime from
# this .env via --env-file.

step "Reusing existing secrets where present"

if [[ -f "$ENV_FILE" ]]; then
  info "Found ${ENV_FILE} — reusing stored secrets."
  JWT_SECRET="${JWT_SECRET:-$(env_file_get "$ENV_FILE" JWT_SECRET)}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(env_file_get "$ENV_FILE" POSTGRES_PASSWORD)}"
  TEMPORAL_POSTGRES_PASSWORD="${TEMPORAL_POSTGRES_PASSWORD:-$(env_file_get "$ENV_FILE" TEMPORAL_POSTGRES_PASSWORD)}"
  POSTIZ_DISABLE_REGISTRATION="${POSTIZ_DISABLE_REGISTRATION:-$(env_file_get "$ENV_FILE" POSTIZ_DISABLE_REGISTRATION)}"
  OPENAI_API_KEY="${OPENAI_API_KEY:-$(env_file_get "$ENV_FILE" OPENAI_API_KEY)}"
  POSTIZ_ADMIN_EMAIL="${POSTIZ_ADMIN_EMAIL:-$(env_file_get "$ENV_FILE" POSTIZ_ADMIN_EMAIL)}"
  POSTIZ_ADMIN_ORG="${POSTIZ_ADMIN_ORG:-$(env_file_get "$ENV_FILE" POSTIZ_ADMIN_ORG)}"
  POSTIZ_ADMIN_PASSWORD="${POSTIZ_ADMIN_PASSWORD:-$(env_file_get "$ENV_FILE" POSTIZ_ADMIN_PASSWORD)}"
  POSTIZ_API_KEY="${POSTIZ_API_KEY:-$(env_file_get "$ENV_FILE" POSTIZ_API_KEY)}"
fi

# Defaults — Postiz still allows exactly the FIRST registration when the org
# count is 0 even with registration disabled (canRegister in auth.service.ts),
# so the bootstrap below works and every signup after that is locked out.
[[ -n "$POSTIZ_DISABLE_REGISTRATION" ]] || POSTIZ_DISABLE_REGISTRATION="true"

# First-run defaults for the admin bootstrap: once written to the .env they
# are read back on re-runs (stable identity, never regenerated).
# Fresh install: admin email = the machine user's email (global git config
# user.email when set, otherwise <user>@<host>.local), org = "my organization".
if [[ -z "$POSTIZ_ADMIN_EMAIL" ]]; then
  _user_email="$(git config --global user.email 2>/dev/null || true)"
  if [[ -z "$_user_email" ]]; then
    _user_email="$(id -un)@$(hostname -s).local"
  fi
  POSTIZ_ADMIN_EMAIL="$_user_email"
  unset _user_email
fi
[[ -n "$POSTIZ_ADMIN_ORG" ]] || POSTIZ_ADMIN_ORG="my organization"
[[ -n "$POSTIZ_ADMIN_PASSWORD" ]] || {
  POSTIZ_ADMIN_PASSWORD="$(openssl rand -hex 16)"
  info "Generated a new POSTIZ_ADMIN_PASSWORD."
}

[[ -n "$JWT_SECRET" ]] || { JWT_SECRET="$(openssl rand -hex 64)"; info "Generated a new JWT_SECRET."; }
[[ -n "$POSTGRES_PASSWORD" ]] || { POSTGRES_PASSWORD="$(openssl rand -hex 24)"; info "Generated a new POSTGRES_PASSWORD."; }
[[ -n "$TEMPORAL_POSTGRES_PASSWORD" ]] || { TEMPORAL_POSTGRES_PASSWORD="$(openssl rand -hex 24)"; info "Generated a new TEMPORAL_POSTGRES_PASSWORD."; }

# DATABASE_URL is derived once and lives only in the .env (never in compose).
DATABASE_URL="postgresql://postiz-user:${POSTGRES_PASSWORD}@postiz-postgres:5432/postiz-db-local"

step "Writing ${ENV_FILE} (mode 600)"
#
# Written with printf (never a heredoc that could expand values). Owned by the
# invoking user, mode 600 — NOT root:root, because docker compose --env-file
# runs as the invoking user and cannot read a root-owned 600 file. No
# timestamp line: a no-op re-run must produce byte-identical content.
_env_new="$(mktemp)"
{
  printf '# Postiz secrets — KEEP SECURE (mode 600). Re-runs reuse these values.\n'
  printf 'JWT_SECRET=%s\n'                  "${JWT_SECRET}"
  printf 'POSTGRES_USER=%s\n'               "postiz-user"
  printf 'POSTGRES_DB=%s\n'                 "postiz-db-local"
  printf 'POSTGRES_PASSWORD=%s\n'           "${POSTGRES_PASSWORD}"
  printf 'TEMPORAL_POSTGRES_PASSWORD=%s\n'  "${TEMPORAL_POSTGRES_PASSWORD}"
  printf 'DATABASE_URL=%s\n'                "${DATABASE_URL}"
  printf 'POSTIZ_DISABLE_REGISTRATION=%s\n' "${POSTIZ_DISABLE_REGISTRATION}"
  printf 'OPENAI_API_KEY=%s\n'              "${OPENAI_API_KEY}"
  printf 'POSTIZ_ADMIN_EMAIL=%s\n'          "${POSTIZ_ADMIN_EMAIL}"
  printf 'POSTIZ_ADMIN_ORG=%s\n'            "${POSTIZ_ADMIN_ORG}"
  printf 'POSTIZ_ADMIN_PASSWORD=%s\n'       "${POSTIZ_ADMIN_PASSWORD}"
  # Only written once known (first run: the bootstrap step appends it after
  # the stack is up; re-runs read it back, keeping the file byte-stable).
  if [[ -n "$POSTIZ_API_KEY" ]]; then
    printf 'POSTIZ_API_KEY=%s\n'            "${POSTIZ_API_KEY}"
  fi
} > "$_env_new"
# Parent dir must exist for the install (fresh machines create it here).
sudo mkdir -p "${POSTIZ_HOME}"
# Back up only on an actual content change, so a no-op re-run never clobbers a good .env.bak
if [[ -f "$ENV_FILE" ]] && ! sudo cmp -s "$_env_new" "$ENV_FILE"; then
  sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "$ENV_FILE" "${ENV_FILE}.bak"
fi
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "$_env_new" "$ENV_FILE"
rm -f "$_env_new"
success "Secrets stored in ${ENV_FILE} (mode 600, owner: $(id -un))."


# ─────────────────────────────────────────────────────────────────────────────
# EXISTING STACK
# ─────────────────────────────────────────────────────────────────────────────

step "Checking for an existing Postiz compose stack"

if [[ -f "$COMPOSE_FILE" ]]; then
  info "Existing docker-compose.yml at ${COMPOSE_FILE} — re-run will converge it (no tear-down)."
fi


# ─────────────────────────────────────────────────────────────────────────────
# RENDER DOCKER COMPOSE FILE
# ─────────────────────────────────────────────────────────────────────────────

step "Generating ${COMPOSE_FILE}"

TEMPLATE_DIR="${SCRIPT_DIR}/../templates/postiz"
if [[ "$POSTIZ_TRAEFIK" == "true" ]]; then
  TEMPLATE_FILE="${TEMPLATE_DIR}/docker-compose.traefik.yml"
else
  TEMPLATE_FILE="${TEMPLATE_DIR}/docker-compose.direct.yml"
fi

# Render into a mktemp file, then install (AGENTS.md, "Secrets and templating").
# Export variables for envsubst (explicit list, never bare envsubst).
# Layout values ONLY — secrets (JWT_SECRET, POSTGRES_PASSWORD,
# TEMPORAL_POSTGRES_PASSWORD, DATABASE_URL, OPENAI_API_KEY,
# POSTIZ_DISABLE_REGISTRATION) are never substituted: they stay ${VAR}-literal
# in the rendered file and are resolved at runtime from ${ENV_FILE} via
# --env-file.
export POSTIZ_IMAGE POSTGRES_IMAGE TEMPORAL_POSTGRES_IMAGE REDIS_IMAGE \
  ES_IMAGE TEMPORAL_IMAGE TEMPORAL_UI_IMAGE MAIN_URL \
  NEXT_PUBLIC_BACKEND_URL TEMPORAL_UI_PORT
_render_tmp="$(mktemp)"
if [[ "$POSTIZ_TRAEFIK" == "true" ]]; then
  export PROXY_NETWORK POSTIZ_DOMAIN
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${POSTIZ_IMAGE} ${POSTGRES_IMAGE} ${TEMPORAL_POSTGRES_IMAGE} ${REDIS_IMAGE} ${ES_IMAGE} ${TEMPORAL_IMAGE} ${TEMPORAL_UI_IMAGE} ${MAIN_URL} ${NEXT_PUBLIC_BACKEND_URL} ${PROXY_NETWORK} ${POSTIZ_DOMAIN} ${TEMPORAL_UI_PORT}' \
    < "${TEMPLATE_FILE}" > "$_render_tmp"
else
  export HTTP_PORT
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${POSTIZ_IMAGE} ${POSTGRES_IMAGE} ${TEMPORAL_POSTGRES_IMAGE} ${REDIS_IMAGE} ${ES_IMAGE} ${TEMPORAL_IMAGE} ${TEMPORAL_UI_IMAGE} ${MAIN_URL} ${NEXT_PUBLIC_BACKEND_URL} ${HTTP_PORT} ${TEMPORAL_UI_PORT}' \
    < "${TEMPLATE_FILE}" > "$_render_tmp"
fi
sudo install -m 0644 -o "$(id -un)" -g "$(id -gn)" "$_render_tmp" "${COMPOSE_FILE}"
rm -f "$_render_tmp"
success "docker-compose.yml written to ${COMPOSE_FILE}"

# Temporal's dynamic config — the temporal container mounts
# ./dynamicconfig (relative to the compose file); without it Temporal does not
# come up. Copy from the template (identical content is harmless on re-runs).
step "Installing Temporal dynamic config into ${POSTIZ_HOME}/dynamicconfig"
sudo mkdir -p "${POSTIZ_HOME}/dynamicconfig"
sudo install -m 0644 "${TEMPLATE_DIR}/dynamicconfig/development-sql.yaml" \
  "${POSTIZ_HOME}/dynamicconfig/development-sql.yaml"
success "dynamicconfig/development-sql.yaml installed."


# ─────────────────────────────────────────────────────────────────────────────
# PULL IMAGES
# ─────────────────────────────────────────────────────────────────────────────

step "Pulling Docker images"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull
success "Images pulled."


# ─────────────────────────────────────────────────────────────────────────────
# START THE STACK
# ─────────────────────────────────────────────────────────────────────────────

step "Starting Postiz stack (detached)"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

# Health gate: prove the containers are actually up before reporting success.
mapfile -t _ids < <(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps -q)
wait_for_healthy "${WAIT_TIMEOUT}" "${_ids[@]}" \
  || error "Postiz stack did not come up — see the status output above"


# ─────────────────────────────────────────────────────────────────────────────
# WAIT FOR POSTIZ TO BECOME AVAILABLE
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for Postiz web UI to respond"

MAX_WAIT=120
INTERVAL=5
ELAPSED=0
READY=false
# Direct mode: poll the local port. Traefik mode: poll loopback is not
# possible for the domain — the container healthcheck already proves the app
# answers (the health gate above), so skip the HTTP poll there.
if [[ "$POSTIZ_TRAEFIK" != "true" ]]; then
  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HTTP_PORT}" || true)
    if echo "$HTTP_CODE" | grep -qE "^[1-4]"; then
      READY=true
      break
    fi
    echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s (HTTP ${HTTP_CODE}) ..."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  echo ""
fi

if [[ "$POSTIZ_TRAEFIK" == "true" ]]; then
  success "Containers healthy. Site should be reachable at https://${POSTIZ_DOMAIN} (DNS/TLS may need a moment)."
elif [[ "$READY" == "true" ]]; then
  success "Postiz is up and responding at ${MAIN_URL}"
else
  warn "Postiz did not respond on port ${HTTP_PORT} within ${MAX_WAIT}s."
  warn "It may still be starting. Check logs with:"
  warn "  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs -f"
  # Still a hard failure: the stack must prove itself up (conventions).
  error "Postiz web UI did not become reachable — see the log hint above"
fi


# ─────────────────────────────────────────────────────────────────────────────
# BOOTSTRAP ORGANIZATION + ADMIN USER (IDEMPOTENT)
# ─────────────────────────────────────────────────────────────────────────────
#
# Postiz has no env-var seed, init script, or CLI for the first user (verified
# against v2.24.0 source — docs/research/postiz-auto-config-2026-09-30.md).
# Instead the plain REST registration endpoint is used: every registration
# creates a NEW organization whose sole user is SUPERADMIN, an org API key is
# generated automatically, and without an SMTP provider the user is
# auto-activated immediately. Idempotency: login first (re-runs), register
# only when the login fails; re-registering the same email is a 400
# "Email already exists" (treated as already-existing), and with
# DISABLE_REGISTRATION=true any later signup is blocked by the app itself.

step "Ensuring organization + admin user exist (API bootstrap)"

if [[ "$POSTIZ_TRAEFIK" == "true" ]]; then
  API_BASE="${MAIN_URL}/api"
else
  # The script runs on the host: loopback is the reliable address.
  API_BASE="http://localhost:${HTTP_PORT}/api"
fi

_cookie_jar="$(mktemp)"
trap 'rm -f "$_cookie_jar"' EXIT
_api_jwt=""

# Try logging in with the bootstrap credentials. On success sets _api_jwt.
try_admin_login() {
  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' -c "$_cookie_jar" \
    -H 'Content-Type: application/json' \
    --data "{\"email\":\"${POSTIZ_ADMIN_EMAIL}\",\"password\":\"${POSTIZ_ADMIN_PASSWORD}\",\"provider\":\"LOCAL\"}" \
    --max-time 15 "${API_BASE}/auth/login" 2>/dev/null) || return 1
  [[ "$http_code" == "200" ]] || return 1
  _api_jwt="$(awk 'tolower($6) == "auth" { print $7 }' "$_cookie_jar")"
  [[ -n "$_api_jwt" ]] || return 1
  return 0
}

# The backend may need a moment after the health gate; retry the login probe.
_api_up=false
for _ in $(seq 1 12); do
  if curl -sS -o /dev/null --max-time 5 "${API_BASE}/auth/can-register" 2>/dev/null; then
    _api_up=true
    break
  fi
  sleep 5
done
if [[ "$_api_up" != "true" ]]; then
  error "Postiz API did not answer at ${API_BASE} — check: docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs postiz"
fi

_admin_created=false
if try_admin_login; then
  info "Admin login OK — organization '${POSTIZ_ADMIN_ORG}' already exists."
else
  info "Login failed — attempting first-time registration of ${POSTIZ_ADMIN_EMAIL} ..."
  _reg_out=$(curl -sS -w $'\n%{http_code}' -c "$_cookie_jar" \
    -H 'Content-Type: application/json' \
    --data "{\"email\":\"${POSTIZ_ADMIN_EMAIL}\",\"password\":\"${POSTIZ_ADMIN_PASSWORD}\",\"company\":\"${POSTIZ_ADMIN_ORG}\",\"provider\":\"LOCAL\"}" \
    --max-time 30 "${API_BASE}/auth/register" 2>&1) || true
  _reg_code="${_reg_out##*$'\n'}"
  _reg_msg="${_reg_out%$'\n'*}"
  if [[ "$_reg_code" == "200" ]]; then
    _admin_created=true
    _api_jwt="$(awk 'tolower($6) == "auth" { print $7 }' "$_cookie_jar")"
    success "Created organization '${POSTIZ_ADMIN_ORG}' with SUPERADMIN user ${POSTIZ_ADMIN_EMAIL}."
  elif [[ "$_reg_code" == "400" && "$_reg_msg" == *"Email already exists"* ]]; then
    info "Account ${POSTIZ_ADMIN_EMAIL} already exists (password may differ — see POSTIZ_ADMIN_PASSWORD in ${ENV_FILE})."
  elif [[ "$_reg_code" == "400" && "$_reg_msg" == *"Registration is disabled"* ]]; then
    info "An organization already exists on this instance — bootstrap skipped."
  else
    error "Postiz registration failed (HTTP ${_reg_code}): ${_reg_msg}. Existing instance with a different admin? Check the credentials in ${ENV_FILE} or log in via the UI once."
  fi
fi

# Fetch the org's auto-generated public API key (present on every org) and
# persist it for the Postiz MCP server / public API (docs.postiz.com/mcp).
if [[ -n "$_api_jwt" && ("$_admin_created" == "true" || -z "$POSTIZ_API_KEY") ]]; then
  _self_json=$(curl -sS -H "auth: ${_api_jwt}" --max-time 15 "${API_BASE}/user/self" 2>/dev/null) || true
  _new_key="$(jq -r '.publicApi // empty' <<<"${_self_json}" 2>/dev/null)" || true
  if [[ -n "${_new_key}" ]]; then
    POSTIZ_API_KEY="${_new_key}"
    # Append only when missing: the main .env write above already includes
    # the key on re-runs, so a no-op re-run never rewrites the file.
    if ! grep -q '^POSTIZ_API_KEY=' "$ENV_FILE"; then
      # The .env is owned by the invoking user, so a plain append works.
      echo "POSTIZ_API_KEY=${POSTIZ_API_KEY}" >> "$ENV_FILE"
      info "Stored the organization API key as POSTIZ_API_KEY in ${ENV_FILE}."
    fi
  else
    warn "Could not fetch the org API key via /api/user/self — create it in the UI (Account settings) and store it as POSTIZ_API_KEY in ${ENV_FILE}."
  fi
else
  [[ -n "$POSTIZ_API_KEY" ]] || warn "No org API key available (existing instance) — see POSTIZ_API_KEY in ${ENV_FILE} or the UI (Account settings)."
fi


# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY + POST-INSTALL CHECKLIST
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Postiz setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
if [[ "$POSTIZ_TRAEFIK" == "true" ]]; then
  echo -e "  ${BOLD}Web UI${RESET}           https://${POSTIZ_DOMAIN}"
else
  echo -e "  ${BOLD}Web UI${RESET}           ${MAIN_URL}"
  echo -e "  ${BOLD}Local port${RESET}       http://localhost:${HTTP_PORT}"
fi
echo -e "  ${BOLD}Admin user${RESET}       ${POSTIZ_ADMIN_EMAIL}"
echo -e "  ${BOLD}Organization${RESET}     ${POSTIZ_ADMIN_ORG}"
if [[ "$_admin_created" == "true" ]]; then
  echo -e "  ${BOLD}Admin password${RESET}   ${POSTIZ_ADMIN_PASSWORD}"
else
  echo -e "  ${BOLD}Admin password${RESET}   (stored as POSTIZ_ADMIN_PASSWORD in ${ENV_FILE})"
fi
echo -e "  ${BOLD}Temporal UI${RESET}      http://127.0.0.1:${TEMPORAL_UI_PORT} (loopback only)"
echo -e "  ${BOLD}Data directory${RESET}   ${POSTIZ_HOME}"
echo -e "  ${BOLD}Compose file${RESET}     ${COMPOSE_FILE}"
echo ""
echo -e "${BOLD}Post-install checklist${RESET} (UI steps, run as human):"
echo -e "  1. Log in to the UI with the admin user above"
echo -e "     (registration is locked by default after this first account)."
echo -e "  2. Create platform Integrations in the UI: LinkedIn (Share-on-LinkedIn app,"
echo -e "     w_member_social), X (API key), dev.to (API token), Reddit (OAuth app —"
echo -e "     new tokens need Reddit approval, do it early)."
echo -e "  3. Wire the Postiz MCP server into the agent (docs.postiz.com/mcp) using"
echo -e "     POSTIZ_API_URL=${MAIN_URL}/api + the API key stored as"
echo -e "     POSTIZ_API_KEY in ${ENV_FILE}."
echo -e "  4. (Follow-up) Add the Postiz postgres volume to the backup rotation"
echo -e "     (lib/docker-backup.sh pattern)."
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Follow logs :  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs -f"
echo -e "  Stop stack  :  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} down"
echo -e "  Start stack :  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} up -d"
echo -e "  Temporal CLI:  docker exec -it temporal temporal workflow list --namespace default"
echo -e "  Upgrade     :  bump POSTIZ_IMAGE (newest ghcr tag), re-run this script,"
echo -e "                 'docker compose pull && up -d' — migrations run on boot."
