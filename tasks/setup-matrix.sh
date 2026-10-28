#!/usr/bin/env bash
# shellcheck disable=SC1091
# =============================================================================
# Matrix Homeserver Setup Script (Synapse + MAS + Element, optional calls)
# =============================================================================
#
# DESCRIPTION:
#   Private, self-hosted Matrix team chat behind the shared Traefik proxy:
#   Synapse + PostgreSQL 17 + Matrix Authentication Service (MAS) + Element
#   Web + .well-known delegation. Optional: voice/video calls (LiveKit +
#   lk-jwt-service, MATRIX_RTC=true), the Ketesa admin UI (MATRIX_ADMIN_UI=
#   true), federation (MATRIX_FEDERATION=true), Prometheus metrics. Every
#   file is rendered from templates/matrix/ — never generated inline.
#
# KEY ACTIONS:
#   1. Pre-flight: docker + compose v2, openssl, envsubst, jq, curl, the
#      Traefik proxy network
#   2. Identity guard: MATRIX_SERVER_NAME is immutable once a .env exists
#   3. Secrets: generated once into ${MATRIX_HOME}/.env (mode 600), reused on
#      every re-run (never rotated) and materialised into the mode-600 secret
#      files Synapse and MAS read (*_path / *_file config keys)
#   4. Key material: Synapse signing key (generate_signing_key in the image)
#      and MAS signing keys (openssl) — generated once, never overwritten
#   5. Renders homeserver.yaml (fragments), MAS config, Element config,
#      well-known documents, LiveKit config, docker-compose.yml
#   6. db first, then the MAS role/database, then the full stack; health gate
#      + readiness polls (Synapse, MAS, through Traefik)
#   7. Creates the first MAS admin (first install only), 'mas-cli config sync'
#   8. UFW rules for the LiveKit media ports (calls only)
#
# SECRET-BEARING GENERATED FILES (documented exceptions, mode 600):
#   - ${MATRIX_HOME}/synapse/appservices/lk-jwt.yaml (as_token/hs_token —
#     Synapse has no file indirection for appservice tokens; calls only)
#   - the materialised secret files under synapse/secrets/ and secrets/mas/
#     (copies of .env values, read via *_path/*_file — that is their purpose)
#
# IMPORTANT VARIABLES (full list in --help):
#   MATRIX_SERVER_NAME   - Matrix server name, e.g. example.com (REQUIRED on
#                          the first run, immutable afterwards)
#   MATRIX_RTC           - "true" enables calls (default: false)
#   MATRIX_FEDERATION    - "true" federates with other servers (default: false)
#   MATRIX_ADMIN_UI      - "true" adds the Ketesa admin UI (default: false)
#
# DEPENDENCIES:
#   - Docker + Compose v2 (setup-docker.sh), Traefik (setup-traefik.sh)
#   - openssl, envsubst (gettext-base), jq, curl
#
# OUTPUTS:
#   - ${MATRIX_HOME}/.env, docker-compose.yml, synapse/, mas/, secrets/,
#     element/, wellknown/, livekit/, admin/, db/
#   - containers: matrix-db, matrix-synapse, matrix-mas, matrix-element
#     (+ matrix-wellknown, matrix-livekit, matrix-lk-jwt, matrix-admin)
#
# USAGE:
#   MATRIX_SERVER_NAME=example.com ./setup-matrix.sh
#   MATRIX_SERVER_NAME=example.com MATRIX_RTC=true ./setup-matrix.sh
#   ./setup-matrix.sh --help
#
# REFERENCE:
#   README_MATRIX.md, docs/research/2026-10-28-matrix-self-hosting.md
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — handles partial failures
# ─────────────────────────────────────────────────────────────────────────────

# Set to 1 immediately before the first 'up -d' when no stack was running,
# reset to 0 once the stack is proven healthy. The trap tears the stack down
# only while this flag is set, so a late failure never stops a stack that was
# running before this script was invoked. Bind-mounted data is never removed.
STACK_CREATED_THIS_RUN=0

cleanup_on_failure() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  if (( STACK_CREATED_THIS_RUN != 1 )); then
    warn "Setup failed (exit code: ${exit_code}). Nothing torn down — this run either never started a stack or the stack was already running before."
    return 0
  fi
  echo ""
  warn "Setup failed (exit code: ${exit_code})! Removing the stack created by this run..."
  if [[ -f "${MATRIX_HOME}/docker-compose.yml" ]]; then
    sudo docker compose -f "${MATRIX_HOME}/docker-compose.yml" --env-file "${MATRIX_HOME}/.env" \
      down --remove-orphans 2>/dev/null || true
    info "Removed partially created stack — data in ${MATRIX_HOME} is preserved."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# COLOURS & HELPERS
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}▶ $*${RESET}"; }

trap cleanup_on_failure EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP (parsed before CONFIGURATION: --help must not touch .env)
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Deploys a private Matrix homeserver for a team behind the shared Traefik
proxy: Synapse + PostgreSQL + Matrix Authentication Service (MAS) + Element
Web + .well-known delegation; optional calls (LiveKit + lk-jwt-service),
admin UI (Ketesa), federation and metrics. Re-runs converge the stack;
secrets in ${MATRIX_HOME:-/srv/matrix}/.env (mode 600) are never rotated.

Options:
  --interactive   Offer tear-down/re-create of an existing stack (default:
                  converge). Bind-mounted data is never deleted.
  --force         Re-create all containers (also MATRIX_FORCE=true). Never
                  touches db/, synapse/ or secrets/.
  -h, --help      Show this help and exit

Environment variables:
  MATRIX_SERVER_NAME        Matrix server name — the part after the colon in
                            @user:example.com. REQUIRED on the first run;
                            IMMUTABLE afterwards (a different value is an
                            error; changing it means a new server)
  MATRIX_DOMAIN             Synapse host (default: matrix.<server_name>); may
                            equal MATRIX_SERVER_NAME
  MATRIX_AUTH_DOMAIN        MAS host (default: auth.<server_name>)
  MATRIX_CHAT_DOMAIN        Element Web host (default: chat.<server_name>)
  MATRIX_RTC_DOMAIN         LiveKit + lk-jwt host (default: rtc.<server_name>)
  MATRIX_ADMIN_DOMAIN       Ketesa host (default: admin.<server_name>)
  MATRIX_WELLKNOWN          traefik  = nginx container answers on the apex
                            synapse  = Synapse serves it (needs
                                       MATRIX_DOMAIN == MATRIX_SERVER_NAME)
                            external = print the JSON to host elsewhere
                            (default: synapse when MATRIX_DOMAIN ==
                            MATRIX_SERVER_NAME, else traefik)
  MATRIX_FEDERATION         true/false (default: false = private server)
  MATRIX_RTC                true/false: voice/video calls (default: false)
  MATRIX_ADMIN_UI           true/false: Ketesa admin UI (default: false)
  MATRIX_ADMIN_ALLOW_CIDRS  ipAllowList for /_synapse/admin and the admin UI
                            (default: 127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,
                            192.168.0.0/16,100.64.0.0/10)
  MATRIX_ADMIN_USER         First MAS admin, created at first install only
                            (default: admin)
  MATRIX_ADMIN_PASSWORD     Its password (generated, stored in .env; applied at
                            first install only — change it later with
                            'docker exec matrix-mas mas-cli manage set-password')
  MATRIX_E2EE_DEFAULT       Default room encryption: all / invite / off
                            (default: invite)
  MATRIX_MAX_UPLOAD         max_upload_size (default: 50M; above ~100M raise
                            Traefik's readTimeout, see README_MATRIX.md)
  MATRIX_URL_PREVIEWS       true/false (default: true; always with the full
                            private-range blacklist)
  MATRIX_METRICS            true/false: Synapse metrics listener on :9000
                            (not published) + prometheus.scrape labels
                            (default: false)
  LIVEKIT_TCP_PORT          Published ICE/TCP port (default: 7881)
  LIVEKIT_UDP_PORT          Published UDP mux port (default: 7882)
  LIVEKIT_NODE_IP           IP LiveKit announces to clients (default: empty =
                            discover the public IP via STUN). Set the
                            NetBird/LAN IP for VPN-only deployments.
  PROXY_NETWORK             Traefik's external network (default: proxy)
  MATRIX_HOME               Data directory (default: /srv/matrix)
  WAIT_TIMEOUT              Seconds for the health gate and each readiness
                            poll (default: 300)
  MATRIX_DB_IMAGE           (default: postgres:17-alpine; follows
                            db/PG_VERSION of an existing install)
  SYNAPSE_IMAGE             (default: matrixdotorg/synapse:v1.164.0 — read
                            Synapse's upgrade.md and back up before bumping)
  MAS_IMAGE                 (default: ghcr.io/element-hq/matrix-authentication-service:1.28.0)
  ELEMENT_IMAGE             (default: vectorim/element-web:v1.12.33)
  MATRIX_WELLKNOWN_IMAGE    (default: nginx:1.30-alpine)
  LIVEKIT_IMAGE             (default: livekit/livekit-server:v1.13.11)
  LK_JWT_IMAGE              (default: ghcr.io/element-hq/lk-jwt-service:0.9.0)
  KETESA_IMAGE              (default: ghcr.io/etkecc/ketesa:v1.5.2)

DNS prerequisites (A/AAAA records, or NetBird DNS records for VPN-only):
  MATRIX_DOMAIN, MATRIX_AUTH_DOMAIN, MATRIX_CHAT_DOMAIN
  + MATRIX_RTC_DOMAIN (calls), MATRIX_ADMIN_DOMAIN (admin UI)
  + MATRIX_SERVER_NAME when MATRIX_WELLKNOWN=traefik
  VPN-only hosts need Traefik with DNS_PROVIDER (DNS-01): HTTP-01 cannot
  reach them.

Secrets: all generated values live in ${MATRIX_HOME:-/srv/matrix}/.env (mode
600). Synapse and MAS read them from mode-600 files materialised from that
.env on every run. Documented exception: the lk-jwt appservice registration
(synapse/appservices/lk-jwt.yaml, mode 600) carries its tokens inline.
The admin bootstrap passes the password to 'mas-cli manage register-user' on
its command line (no stdin option) — visible inside the container for the
duration of that one call.

Ports: no 8448 (federation is delegated to :443). Calls publish
LIVEKIT_TCP_PORT/tcp and LIVEKIT_UDP_PORT/udp directly; Docker-published ports
bypass UFW INPUT rules.
EOF
}

INTERACTIVE=false
FORCE="${MATRIX_FORCE:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive) INTERACTIVE=true ;;
    --force)       FORCE=true ;;
    -h|--help)     usage; exit 0 ;;
    *)             error "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

MATRIX_HOME="${MATRIX_HOME:-/srv/matrix}"
ENV_FILE="${MATRIX_HOME}/.env"
COMPOSE_FILE="${MATRIX_HOME}/docker-compose.yml"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/matrix"

# The .env is root-owned (mode 600): read it once, parse with grep/cut, never
# source it.
_existing_env=""
if sudo test -f "$ENV_FILE"; then
  _existing_env="$(sudo cat "$ENV_FILE")"
fi
_stored() { grep -m1 "^${1}=" <<<"${_existing_env}" | cut -d= -f2- || true; }

# ── Identity: server_name is part of every user ID, room ID and the signing
# key — it can never change on an existing server.
_stored_server_name="$(_stored MATRIX_SERVER_NAME)"
MATRIX_SERVER_NAME="${MATRIX_SERVER_NAME:-${_stored_server_name}}"
[[ -n "$MATRIX_SERVER_NAME" ]] \
  || error "MATRIX_SERVER_NAME is required (e.g. MATRIX_SERVER_NAME=example.com) — see --help"
[[ "$MATRIX_SERVER_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
  || error "MATRIX_SERVER_NAME '${MATRIX_SERVER_NAME}' is not a valid host name"
if [[ -n "$_stored_server_name" && "$_stored_server_name" != "$MATRIX_SERVER_NAME" ]]; then
  error "MATRIX_SERVER_NAME is immutable: this server was created as '${_stored_server_name}' (${ENV_FILE}), requested '${MATRIX_SERVER_NAME}'.
        The server name is part of every user and room ID and of the signing key;
        changing it means a NEW, empty server. To do that deliberately, stop the stack
        and remove ${MATRIX_HOME} by hand (back it up first). Nothing was modified."
fi

MATRIX_DOMAIN="${MATRIX_DOMAIN:-matrix.${MATRIX_SERVER_NAME}}"
MATRIX_AUTH_DOMAIN="${MATRIX_AUTH_DOMAIN:-auth.${MATRIX_SERVER_NAME}}"
MATRIX_CHAT_DOMAIN="${MATRIX_CHAT_DOMAIN:-chat.${MATRIX_SERVER_NAME}}"
MATRIX_RTC_DOMAIN="${MATRIX_RTC_DOMAIN:-rtc.${MATRIX_SERVER_NAME}}"
MATRIX_ADMIN_DOMAIN="${MATRIX_ADMIN_DOMAIN:-admin.${MATRIX_SERVER_NAME}}"

if [[ "$MATRIX_DOMAIN" == "$MATRIX_SERVER_NAME" ]]; then
  MATRIX_WELLKNOWN="${MATRIX_WELLKNOWN:-synapse}"
else
  MATRIX_WELLKNOWN="${MATRIX_WELLKNOWN:-traefik}"
fi
case "$MATRIX_WELLKNOWN" in
  traefik|external) ;;
  synapse)
    [[ "$MATRIX_DOMAIN" == "$MATRIX_SERVER_NAME" ]] \
      || error "MATRIX_WELLKNOWN=synapse needs MATRIX_DOMAIN == MATRIX_SERVER_NAME (Synapse can only answer on its own host). Use traefik or external."
    ;;
  *) error "MATRIX_WELLKNOWN must be traefik, synapse or external (got '${MATRIX_WELLKNOWN}')" ;;
esac

MATRIX_FEDERATION="${MATRIX_FEDERATION:-false}"
MATRIX_RTC="${MATRIX_RTC:-false}"
MATRIX_ADMIN_UI="${MATRIX_ADMIN_UI:-false}"
MATRIX_URL_PREVIEWS="${MATRIX_URL_PREVIEWS:-true}"
MATRIX_METRICS="${MATRIX_METRICS:-false}"
for _b in MATRIX_FEDERATION MATRIX_RTC MATRIX_ADMIN_UI MATRIX_URL_PREVIEWS MATRIX_METRICS FORCE; do
  [[ "${!_b}" == "true" || "${!_b}" == "false" ]] || error "${_b} must be true or false (got '${!_b}')"
done

MATRIX_E2EE_DEFAULT="${MATRIX_E2EE_DEFAULT:-invite}"
[[ "$MATRIX_E2EE_DEFAULT" =~ ^(all|invite|off)$ ]] \
  || error "MATRIX_E2EE_DEFAULT must be all, invite or off (got '${MATRIX_E2EE_DEFAULT}')"
MATRIX_MAX_UPLOAD="${MATRIX_MAX_UPLOAD:-50M}"
[[ "$MATRIX_MAX_UPLOAD" =~ ^[0-9]+[KMG]?$ ]] \
  || error "MATRIX_MAX_UPLOAD must look like 50M (got '${MATRIX_MAX_UPLOAD}')"
MATRIX_ADMIN_ALLOW_CIDRS="${MATRIX_ADMIN_ALLOW_CIDRS:-127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10}"
MATRIX_ADMIN_USER="${MATRIX_ADMIN_USER:-$(_stored MATRIX_ADMIN_USER)}"
MATRIX_ADMIN_USER="${MATRIX_ADMIN_USER:-admin}"

LIVEKIT_TCP_PORT="${LIVEKIT_TCP_PORT:-7881}"
LIVEKIT_UDP_PORT="${LIVEKIT_UDP_PORT:-7882}"
LIVEKIT_NODE_IP="${LIVEKIT_NODE_IP:-}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

# Pinned images. Never start a newer-major postgres against an older datadir:
# the default follows db/PG_VERSION of an existing install.
if [[ -z "${MATRIX_DB_IMAGE:-}" ]]; then
  _pg_major="$(sudo cat "${MATRIX_HOME}/db/PG_VERSION" 2>/dev/null || true)"
  if [[ "${_pg_major}" =~ ^[0-9]+$ ]]; then
    MATRIX_DB_IMAGE="postgres:${_pg_major}-alpine"
  else
    MATRIX_DB_IMAGE="postgres:17-alpine"
  fi
fi
SYNAPSE_IMAGE="${SYNAPSE_IMAGE:-matrixdotorg/synapse:v1.164.0}"
MAS_IMAGE="${MAS_IMAGE:-ghcr.io/element-hq/matrix-authentication-service:1.28.0}"
ELEMENT_IMAGE="${ELEMENT_IMAGE:-vectorim/element-web:v1.12.33}"
MATRIX_WELLKNOWN_IMAGE="${MATRIX_WELLKNOWN_IMAGE:-nginx:1.30-alpine}"
LIVEKIT_IMAGE="${LIVEKIT_IMAGE:-livekit/livekit-server:v1.13.11}"
LK_JWT_IMAGE="${LK_JWT_IMAGE:-ghcr.io/element-hq/lk-jwt-service:0.9.0}"
KETESA_IMAGE="${KETESA_IMAGE:-ghcr.io/etkecc/ketesa:v1.5.2}"
for _i in MATRIX_DB_IMAGE SYNAPSE_IMAGE MAS_IMAGE ELEMENT_IMAGE MATRIX_WELLKNOWN_IMAGE \
          LIVEKIT_IMAGE LK_JWT_IMAGE KETESA_IMAGE; do
  warn_moving_image "${!_i}" "$_i"
done

# Container UIDs that must own the files they read
SYNAPSE_UID=991
MAS_UID=65532   # distroless nonroot (verified: docker inspect Config.User)

# ── Secrets: reuse-first, never rotated ─────────────────────────────────────
# Explicit env wins, else the stored .env value, else a fresh random value.
_env_reuse() { # <VAR_NAME> [generator...]
  local __n="$1" __old; shift
  [[ -n "${!__n:-}" ]] && return 0
  __old="$(_stored "$__n")"
  if [[ -n "$__old" ]]; then
    printf -v "$__n" '%s' "$__old"
  else
    printf -v "$__n" '%s' "$("$@")"
  fi
}
_hex32()    { openssl rand -hex 32; }
_password() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24; }
_lk_key()   { printf 'lk%s' "$(openssl rand -hex 8)"; }

# The admin password is applied at first install only: an explicit value that
# differs from the stored one cannot be converged, so keep the stored one
# (the .env must name the password that is actually in effect) and say how
# to change it.
_stored_admin_password="$(_stored MATRIX_ADMIN_PASSWORD)"
ADMIN_PASSWORD_DIVERGED=false
if [[ -n "$_stored_admin_password" && -n "${MATRIX_ADMIN_PASSWORD:-}" \
      && "$MATRIX_ADMIN_PASSWORD" != "$_stored_admin_password" ]]; then
  ADMIN_PASSWORD_DIVERGED=true
  MATRIX_ADMIN_PASSWORD="$_stored_admin_password"
fi

_env_reuse MATRIX_DB_PASSWORD                 _hex32
_env_reuse MAS_DB_PASSWORD                    _hex32
_env_reuse SYNAPSE_REGISTRATION_SHARED_SECRET _hex32
_env_reuse SYNAPSE_MACAROON_SECRET            _hex32
_env_reuse SYNAPSE_FORM_SECRET                _hex32
_env_reuse MAS_SYNAPSE_SECRET                 _hex32
_env_reuse MAS_ENCRYPTION_SECRET              _hex32
_env_reuse LIVEKIT_KEY                        _lk_key
_env_reuse LIVEKIT_SECRET                     _hex32
_env_reuse LK_AS_TOKEN                        _hex32
_env_reuse LK_HS_TOKEN                        _hex32
_env_reuse MATRIX_ADMIN_PASSWORD              _password

# Optional components → compose profiles (stored in .env, so the backup
# dispatcher's bare 'docker compose up -d' starts the same set)
_profiles=()
[[ "$MATRIX_WELLKNOWN" == "traefik" ]] && _profiles+=(wellknown)
[[ "$MATRIX_RTC" == "true" ]] && _profiles+=(rtc)
[[ "$MATRIX_ADMIN_UI" == "true" ]] && _profiles+=(admin)
COMPOSE_PROFILES="$(IFS=,; echo "${_profiles[*]:-}")"

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

command -v docker &>/dev/null || error "Docker is not installed. Run setup-docker.sh first."
sudo docker info &>/dev/null || error "Docker daemon is not running. Start it with: sudo systemctl start docker"
COMPOSE_VERSION="$(sudo docker compose version --short 2>/dev/null || echo 0)"
[[ "${COMPOSE_VERSION%%.*}" -ge 2 ]] 2>/dev/null \
  || error "Docker Compose v2 is required (found: ${COMPOSE_VERSION})"
for _t in openssl envsubst jq curl; do
  command -v "$_t" &>/dev/null || error "${_t} is not installed (sudo apt-get install ${_t/envsubst/gettext-base})"
done
success "Docker $(sudo docker version --format '{{.Server.Version}}'), Compose ${COMPOSE_VERSION}, openssl, envsubst, jq, curl."

ensure_proxy_network   # exits with "run setup-traefik.sh first" when missing

# ─────────────────────────────────────────────────────────────────────────────
# EXISTING STACK (converge by default)
# ─────────────────────────────────────────────────────────────────────────────

step "Checking for an existing Matrix stack"

_dc() { sudo docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

STACK_WAS_RUNNING=false
if sudo test -f "$COMPOSE_FILE"; then
  [[ -n "$(_dc ps -q 2>/dev/null || true)" ]] && STACK_WAS_RUNNING=true
  info "Existing stack found (${COMPOSE_FILE}) — converging: config re-rendered,"
  info "stored secrets reused, 'docker compose up -d' reconciles only what changed."
  if [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Converge (default) or tear down and re-create? [c/r] " _answer
    if [[ "${_answer,,}" == "r" ]]; then
      STACK_CREATED_THIS_RUN=1
      info "Stopping and removing the containers (data in ${MATRIX_HOME} is kept)..."
      _dc down --remove-orphans || true
      STACK_WAS_RUNNING=false
    fi
  fi
else
  info "No existing stack — fresh install."
fi

# ─────────────────────────────────────────────────────────────────────────────
# DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────

step "Creating ${MATRIX_HOME}"

# install -d sets the mode; chown separately (install -o wants a user name,
# the container UIDs have none on the host)
_dir() { # <mode> <uid> <dir...>
  local mode="$1" uid="$2"; shift 2
  sudo install -d -m "$mode" "$@"
  sudo chown "${uid}:${uid}" "$@"
}
_dir 755 0 "$MATRIX_HOME" "${MATRIX_HOME}/mas" \
  "${MATRIX_HOME}/element" "${MATRIX_HOME}/wellknown" "${MATRIX_HOME}/wellknown/conf" \
  "${MATRIX_HOME}/wellknown/matrix" "${MATRIX_HOME}/livekit" "${MATRIX_HOME}/admin"
# The postgres image owns db/ (uid 70, mode 700) — create it, never touch it
sudo mkdir -p "${MATRIX_HOME}/db"
# synapse/ stays world-readable so the (non-root) backup user's borg run
# picks up homeserver.yaml and media_store/; everything secret below it is
# mode 600/700 and travels in the backup's identity tar instead.
_dir 755 "$SYNAPSE_UID" "${MATRIX_HOME}/synapse"
_dir 750 "$SYNAPSE_UID" "${MATRIX_HOME}/synapse/appservices"
_dir 700 "$SYNAPSE_UID" "${MATRIX_HOME}/synapse/secrets"
_dir 700 0 "${MATRIX_HOME}/secrets"
_dir 700 "$MAS_UID" "${MATRIX_HOME}/secrets/mas" "${MATRIX_HOME}/secrets/mas/keys"
success "Directory tree ready."

# ─────────────────────────────────────────────────────────────────────────────
# FILE INSTALL HELPER — install only on change, remember who must restart
# ─────────────────────────────────────────────────────────────────────────────

# A container that is already running does not notice a changed config file
# (Synapse/MAS/LiveKit read it at start; single-file bind mounts even keep the
# old inode), so every changed file marks its consumer for a restart.
declare -A RESTART=()
_install() { # <src> <dest> <mode> <owner> <service-to-restart|->
  local src="$1" dest="$2" mode="$3" owner="$4" svc="$5"
  if sudo test -f "$dest" && sudo cmp -s "$src" "$dest"; then
    sudo chown "$owner:$owner" "$dest"; sudo chmod "$mode" "$dest"
    return 0
  fi
  sudo test -f "$dest" && [[ "$svc" != "-" ]] && RESTART["$svc"]=1
  sudo install -m "$mode" "$src" "$dest"
  sudo chown "$owner:$owner" "$dest"
}
_install_text() { # <text> <dest> <mode> <owner> <service>
  local tmp; tmp="$(mktemp)"
  printf '%s' "$1" > "$tmp"
  _install "$tmp" "$2" "$3" "$4" "$5"
  rm -f "$tmp"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECRETS → .env (mode 600) → secret files
# ─────────────────────────────────────────────────────────────────────────────

step "Writing secrets to ${ENV_FILE}"

_env_new="$(mktemp)"
{
  printf '# Matrix environment — KEEP THIS FILE SECURE (mode 600)\n'
  printf '# Written by tasks/setup-matrix.sh; values are reused on every re-run.\n\n'
  printf 'MATRIX_SERVER_NAME=%s\n' "$MATRIX_SERVER_NAME"
  printf 'COMPOSE_PROFILES=%s\n' "$COMPOSE_PROFILES"
  printf 'MATRIX_ADMIN_USER=%s\n' "$MATRIX_ADMIN_USER"
  printf 'MATRIX_ADMIN_PASSWORD=%s\n' "$MATRIX_ADMIN_PASSWORD"
  printf 'MATRIX_DB_PASSWORD=%s\n' "$MATRIX_DB_PASSWORD"
  printf 'MAS_DB_PASSWORD=%s\n' "$MAS_DB_PASSWORD"
  printf 'SYNAPSE_REGISTRATION_SHARED_SECRET=%s\n' "$SYNAPSE_REGISTRATION_SHARED_SECRET"
  printf 'SYNAPSE_MACAROON_SECRET=%s\n' "$SYNAPSE_MACAROON_SECRET"
  printf 'SYNAPSE_FORM_SECRET=%s\n' "$SYNAPSE_FORM_SECRET"
  printf 'MAS_SYNAPSE_SECRET=%s\n' "$MAS_SYNAPSE_SECRET"
  printf 'MAS_ENCRYPTION_SECRET=%s\n' "$MAS_ENCRYPTION_SECRET"
  printf 'LIVEKIT_KEY=%s\n' "$LIVEKIT_KEY"
  printf 'LIVEKIT_SECRET=%s\n' "$LIVEKIT_SECRET"
  printf 'LK_AS_TOKEN=%s\n' "$LK_AS_TOKEN"
  printf 'LK_HS_TOKEN=%s\n' "$LK_HS_TOKEN"
} > "$_env_new"
if sudo test -f "$ENV_FILE" && ! sudo cmp -s "$_env_new" "$ENV_FILE"; then
  warn "${ENV_FILE} changes — previous version kept as ${ENV_FILE}.bak"
  sudo install -m 600 "$ENV_FILE" "${ENV_FILE}.bak"
fi
_install "$_env_new" "$ENV_FILE" 600 root -
rm -f "$_env_new"
success "Secrets stored in ${ENV_FILE} (mode 600)."

step "Materialising secret files"
_s="${MATRIX_HOME}/synapse/secrets"
_install_text "$SYNAPSE_REGISTRATION_SHARED_SECRET" "${_s}/registration_shared_secret" 600 "$SYNAPSE_UID" synapse
_install_text "$SYNAPSE_MACAROON_SECRET"            "${_s}/macaroon_secret_key"        600 "$SYNAPSE_UID" synapse
_install_text "$SYNAPSE_FORM_SECRET"                "${_s}/form_secret"                600 "$SYNAPSE_UID" synapse
_install_text "$MAS_SYNAPSE_SECRET"                 "${_s}/mas_secret"                 600 "$SYNAPSE_UID" synapse
_m="${MATRIX_HOME}/secrets/mas"
_install_text "$MAS_SYNAPSE_SECRET"    "${_m}/mas_secret" 600 "$MAS_UID" mas
_install_text "$MAS_ENCRYPTION_SECRET" "${_m}/encryption" 600 "$MAS_UID" mas
success "Secret files up to date (mode 600)."

# ─────────────────────────────────────────────────────────────────────────────
# KEY MATERIAL — generated once, never overwritten
# ─────────────────────────────────────────────────────────────────────────────

step "Checking key material"

SIGNING_KEY="${MATRIX_HOME}/synapse/${MATRIX_SERVER_NAME}.signing.key"
if sudo test -e "$SIGNING_KEY"; then
  sudo test -s "$SIGNING_KEY" \
    || error "${SIGNING_KEY} exists but is EMPTY — restore it from a backup (it is the server's identity). Refusing to continue."
  success "Synapse signing key present — kept."
else
  info "Generating the Synapse signing key (generate_signing_key from ${SYNAPSE_IMAGE})..."
  sudo docker run --rm --entrypoint generate_signing_key \
    -v "${MATRIX_HOME}/synapse:/data" "$SYNAPSE_IMAGE" \
    -o "/data/${MATRIX_SERVER_NAME}.signing.key"
  sudo chown "$SYNAPSE_UID:$SYNAPSE_UID" "$SIGNING_KEY"
  sudo chmod 600 "$SIGNING_KEY"
  success "Signing key created: ${SIGNING_KEY}"
fi

# MAS signs its tokens with these. Losing them logs every client out.
_gen_mas_key() { # <file> <openssl genpkey args...>
  local dest="$1" tmp; shift
  if sudo test -s "$dest"; then
    return 0
  fi
  tmp="$(mktemp)"
  openssl genpkey "$@" -out "$tmp" 2>/dev/null
  sudo install -m 600 "$tmp" "$dest"
  sudo chown "$MAS_UID:$MAS_UID" "$dest"
  rm -f "$tmp"
  info "Generated MAS signing key ${dest}"
}
_gen_mas_key "${_m}/keys/rsa.pem" -algorithm RSA -pkeyopt rsa_keygen_bits:2048
_gen_mas_key "${_m}/keys/ec.pem"  -algorithm EC  -pkeyopt ec_paramgen_curve:P-256
success "MAS signing keys present."

# ─────────────────────────────────────────────────────────────────────────────
# RENDER CONFIGURATION (templates/matrix/, explicit envsubst variable lists)
# ─────────────────────────────────────────────────────────────────────────────

step "Rendering configuration"

if [[ "$MATRIX_FEDERATION" == "true" ]]; then
  SYNAPSE_LISTENER_RESOURCES="[client, federation]"
else
  # 'openid' keeps /_matrix/federation/v1/openid/userinfo for lk-jwt-service
  SYNAPSE_LISTENER_RESOURCES="[client, openid]"
fi
if [[ "$MATRIX_RTC" == "true" ]]; then
  SYNAPSE_APPSERVICE_FILES='["/data/appservices/lk-jwt.yaml"]'
else
  SYNAPSE_APPSERVICE_FILES='[]'
fi
# /.well-known/matrix/server is needed for federation AND for calls:
# lk-jwt-service validates a user's OpenID token through Matrix server
# discovery (well-known, else :8448), even on a private server.
PUBLISH_SERVER_WELLKNOWN=false
if [[ "$MATRIX_FEDERATION" == "true" || "$MATRIX_RTC" == "true" ]]; then
  PUBLISH_SERVER_WELLKNOWN=true
fi
SYNAPSE_SERVE_SERVER_WELLKNOWN=false
SYNAPSE_WELLKNOWN_RULE=""
if [[ "$MATRIX_WELLKNOWN" == "synapse" ]]; then
  SYNAPSE_SERVE_SERVER_WELLKNOWN="$PUBLISH_SERVER_WELLKNOWN"
  # shellcheck disable=SC2016  # backticks are Traefik rule syntax
  SYNAPSE_WELLKNOWN_RULE=' || PathPrefix(`/.well-known/matrix`)'
fi
# lk-jwt reaches these through this host's Traefik (no hairpin NAT); the
# apex only when it is served here
_lk_hosts=("$MATRIX_RTC_DOMAIN" "$MATRIX_DOMAIN")
[[ "$MATRIX_WELLKNOWN" != "external" ]] && _lk_hosts+=("$MATRIX_SERVER_NAME")
LK_JWT_EXTRA_HOSTS="$(printf '%s\n' "${_lk_hosts[@]}" | sort -u \
  | jq -Rnc '[inputs | . + ":host-gateway"]')"
if [[ -n "$LIVEKIT_NODE_IP" ]]; then
  LIVEKIT_USE_EXTERNAL_IP=false
else
  LIVEKIT_USE_EXTERNAL_IP=true
fi
# appservice user regex: dots escaped, backslash doubled for the YAML string
MATRIX_SERVER_NAME_REGEX="${MATRIX_SERVER_NAME//./\\\\.}"

export MATRIX_HOME PROXY_NETWORK MATRIX_SERVER_NAME MATRIX_DOMAIN MATRIX_AUTH_DOMAIN \
  MATRIX_CHAT_DOMAIN MATRIX_RTC_DOMAIN MATRIX_ADMIN_DOMAIN MATRIX_ADMIN_ALLOW_CIDRS \
  MATRIX_MAX_UPLOAD MATRIX_E2EE_DEFAULT MATRIX_URL_PREVIEWS MATRIX_METRICS \
  MATRIX_DB_IMAGE SYNAPSE_IMAGE MAS_IMAGE ELEMENT_IMAGE MATRIX_WELLKNOWN_IMAGE \
  LIVEKIT_IMAGE LK_JWT_IMAGE KETESA_IMAGE LIVEKIT_TCP_PORT LIVEKIT_UDP_PORT \
  LIVEKIT_USE_EXTERNAL_IP LIVEKIT_NODE_IP LIVEKIT_KEY SYNAPSE_LISTENER_RESOURCES \
  SYNAPSE_APPSERVICE_FILES SYNAPSE_SERVE_SERVER_WELLKNOWN SYNAPSE_WELLKNOWN_RULE \
  MATRIX_SERVER_NAME_REGEX LK_JWT_EXTRA_HOSTS

# Only these names are substituted; every other $-string in a template
# (secrets for compose, regexes, nginx variables) stays literal.
# shellcheck disable=SC2016
_LAYOUT_VARS='${MATRIX_HOME} ${PROXY_NETWORK} ${MATRIX_SERVER_NAME} ${MATRIX_DOMAIN} ${MATRIX_AUTH_DOMAIN} ${MATRIX_CHAT_DOMAIN} ${MATRIX_RTC_DOMAIN} ${MATRIX_ADMIN_DOMAIN} ${MATRIX_ADMIN_ALLOW_CIDRS} ${MATRIX_MAX_UPLOAD} ${MATRIX_E2EE_DEFAULT} ${MATRIX_URL_PREVIEWS} ${MATRIX_METRICS} ${MATRIX_DB_IMAGE} ${SYNAPSE_IMAGE} ${MAS_IMAGE} ${ELEMENT_IMAGE} ${MATRIX_WELLKNOWN_IMAGE} ${LIVEKIT_IMAGE} ${LK_JWT_IMAGE} ${KETESA_IMAGE} ${LIVEKIT_TCP_PORT} ${LIVEKIT_UDP_PORT} ${LIVEKIT_USE_EXTERNAL_IP} ${LIVEKIT_NODE_IP} ${LIVEKIT_KEY} ${SYNAPSE_LISTENER_RESOURCES} ${SYNAPSE_APPSERVICE_FILES} ${SYNAPSE_SERVE_SERVER_WELLKNOWN} ${SYNAPSE_WELLKNOWN_RULE} ${MATRIX_SERVER_NAME_REGEX} ${LK_JWT_EXTRA_HOSTS}'
_render() { envsubst "$_LAYOUT_VARS" < "${TEMPLATE_DIR}/$1"; }

_tmp="$(mktemp)"

# homeserver.yaml = base + listeners|metrics + private|federation (+ rtc)
{
  _render synapse/homeserver.base.yaml
  if [[ "$MATRIX_METRICS" == "true" ]]; then _render synapse/metrics.yaml; else _render synapse/listeners.yaml; fi
  if [[ "$MATRIX_FEDERATION" == "true" ]]; then _render synapse/federation.yaml; else _render synapse/private.yaml; fi
  if [[ "$MATRIX_RTC" == "true" ]]; then _render synapse/rtc.yaml; fi
} > "$_tmp"
_install "$_tmp" "${MATRIX_HOME}/synapse/homeserver.yaml" 644 "$SYNAPSE_UID" synapse
_install "${TEMPLATE_DIR}/synapse/log.config" "${MATRIX_HOME}/synapse/log.config" 644 "$SYNAPSE_UID" synapse

_render mas/config.yaml > "$_tmp"
_install "$_tmp" "${MATRIX_HOME}/mas/config.yaml" 644 root mas

# Element: legacy 1:1/Jitsi calls are replaced by Element Call when RTC is on
if [[ "$MATRIX_RTC" == "true" ]]; then
  _render element/config.json | jq '.element_call.use_exclusively = true' > "$_tmp"
else
  _render element/config.json | jq '.' > "$_tmp"
fi
_install "$_tmp" "${MATRIX_HOME}/element/config.json" 644 root element

# Well-known documents (served by nginx in traefik mode; printed in external mode)
if [[ "$MATRIX_RTC" == "true" ]]; then
  _render wellknown/client.rtc | jq '.' > "$_tmp"
else
  _render wellknown/client | jq '.' > "$_tmp"
fi
WELLKNOWN_CLIENT_JSON="$(cat "$_tmp")"
_install "$_tmp" "${MATRIX_HOME}/wellknown/matrix/client" 644 root -
_render wellknown/server | jq '.' > "$_tmp"
WELLKNOWN_SERVER_JSON="$(cat "$_tmp")"
if [[ "$PUBLISH_SERVER_WELLKNOWN" == "true" ]]; then
  _install "$_tmp" "${MATRIX_HOME}/wellknown/matrix/server" 644 root -
else
  sudo rm -f "${MATRIX_HOME}/wellknown/matrix/server"   # private, no calls: 404
fi
_install "${TEMPLATE_DIR}/wellknown/nginx.conf" "${MATRIX_HOME}/wellknown/conf/default.conf" 644 root wellknown

if [[ "$MATRIX_RTC" == "true" ]]; then
  _render livekit/livekit.yaml > "$_tmp"
  _install "$_tmp" "${MATRIX_HOME}/livekit/livekit.yaml" 644 root livekit
  # Secret-bearing exception (tokens inline) — rendered from .env values in a
  # private temp file, installed mode 600 for Synapse's UID.
  LK_AS_TOKEN="$LK_AS_TOKEN" LK_HS_TOKEN="$LK_HS_TOKEN" \
    envsubst "${_LAYOUT_VARS} \${LK_AS_TOKEN} \${LK_HS_TOKEN}" \
    < "${TEMPLATE_DIR}/livekit/lk-jwt-appservice.yaml" > "$_tmp"
  _install "$_tmp" "${MATRIX_HOME}/synapse/appservices/lk-jwt.yaml" 600 "$SYNAPSE_UID" synapse
fi

if [[ "$MATRIX_ADMIN_UI" == "true" ]]; then
  _render admin/config.json | jq '.' > "$_tmp"
  _install "$_tmp" "${MATRIX_HOME}/admin/config.json" 644 root admin
fi

# Compose file: validated against the .env before it replaces the old one
_render docker-compose.yml > "$_tmp"
sudo docker compose -f "$_tmp" --env-file "$ENV_FILE" --project-directory "$MATRIX_HOME" config -q \
  || error "Rendered docker-compose.yml does not validate (see above)"
_install "$_tmp" "$COMPOSE_FILE" 644 root -
rm -f "$_tmp"
success "Configuration rendered (profiles: ${COMPOSE_PROFILES:-none})."

# ─────────────────────────────────────────────────────────────────────────────
# PULL & START
# ─────────────────────────────────────────────────────────────────────────────

step "Pulling images"
_dc pull -q
success "Images ready."

step "Starting the database"
[[ "$STACK_WAS_RUNNING" == "true" ]] || STACK_CREATED_THIS_RUN=1
_dc up -d db
wait_for_healthy "$WAIT_TIMEOUT" "$(_dc ps -q db)" || error "matrix-db did not become healthy"

# MAS role + database. The password travels on stdin (never argv); it is
# re-asserted every run so the role always matches .env.
_psql() { sudo docker exec -i matrix-db psql -v ON_ERROR_STOP=1 -qtA -U synapse -d postgres "$@"; }
_psql >/dev/null <<SQL
SELECT 'CREATE ROLE mas LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mas')\gexec
ALTER ROLE mas WITH LOGIN PASSWORD '${MAS_DB_PASSWORD}';
SELECT 'CREATE DATABASE mas OWNER mas TEMPLATE template0 ENCODING ''UTF8'' LC_COLLATE ''C'' LC_CTYPE ''C'''
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'mas')\gexec
SQL
_collate="$(_psql -c "SELECT datcollate || '/' || datctype FROM pg_database WHERE datname = 'synapse'")"
[[ "$_collate" == "C/C" ]] \
  || error "Database 'synapse' has collation/ctype '${_collate}', Synapse needs C/C. It was created outside this script — recreate it with LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0."
success "Databases synapse + mas ready (C collation)."

step "Starting the Matrix stack"
# Components whose profile is now off: profiles only select what 'up' starts,
# they never stop a container that is already running.
declare -A _svc_profile=([matrix-wellknown]=wellknown [matrix-livekit]=rtc [matrix-lk-jwt]=rtc [matrix-admin]=admin)
for _c in "${!_svc_profile[@]}"; do
  if [[ ",${COMPOSE_PROFILES}," != *",${_svc_profile[$_c]},"* ]] \
     && sudo docker container inspect "$_c" &>/dev/null; then
    info "Removing ${_c} (profile '${_svc_profile[$_c]}' disabled)"
    sudo docker rm -f "$_c" >/dev/null
  fi
done

_up_args=(up -d --remove-orphans)
[[ "$FORCE" == "true" ]] && _up_args+=(--force-recreate)
_dc "${_up_args[@]}"

# Changed config files of containers 'up' left alone need an explicit restart
if [[ "$STACK_WAS_RUNNING" == "true" && "$FORCE" != "true" && ${#RESTART[@]} -gt 0 ]]; then
  mapfile -t _active < <(_dc config --services)
  _restart=()
  for _svc in "${!RESTART[@]}"; do
    printf '%s\n' "${_active[@]}" | grep -qx "$_svc" && _restart+=("$_svc")
  done
  if (( ${#_restart[@]} )); then
    info "Configuration changed — restarting: ${_restart[*]}"
    _dc restart "${_restart[@]}"
  fi
fi

mapfile -t _ids < <(_dc ps -q)
wait_for_healthy "$WAIT_TIMEOUT" "${_ids[@]}" || error "Matrix stack did not come up — see the status output above"

# ─────────────────────────────────────────────────────────────────────────────
# READINESS
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for Synapse, MAS and the Traefik routes"

_poll() { # <description> <command...>
  local desc="$1" waited=0; shift
  until "$@" &>/dev/null; do
    (( waited >= WAIT_TIMEOUT )) && error "${desc} not ready after ${WAIT_TIMEOUT}s — check: sudo docker compose -f ${COMPOSE_FILE} logs"
    sleep 5; waited=$(( waited + 5 ))
  done
  success "${desc} ready."
}
# MAS is distroless (no curl): probe it from the synapse container
_poll "Synapse /health" sudo docker exec matrix-synapse curl -fsS http://localhost:8008/health
_poll "MAS /health"     sudo docker exec matrix-synapse curl -fsS http://mas:8081/health

# Through Traefik on this host. Traefik runs with sniStrict: until ACME has
# issued a certificate for a host (DNS not pointing here yet, VM tests) the
# TLS handshake itself is refused (curl rc 35) — that is reported, not fatal.
# A reachable host answering with the wrong content (missing/misrouted
# router) is fatal. An untrusted certificate (rc 60) is retried with -k.
CERT_WAIT=90
TLS_UNVERIFIED=()
_route_check() { # <description> <host> <path> <grep -E pattern on headers+body>
  local desc="$1" host="$2" path="$3" pattern="$4" waited=0 rc out
  while :; do
    rc=0
    out="$(curl -sS --max-time 10 -D - --resolve "${host}:443:127.0.0.1" "https://${host}${path}" 2>/dev/null)" || rc=$?
    if (( rc == 60 )); then
      rc=0
      out="$(curl -sSk --max-time 10 -D - --resolve "${host}:443:127.0.0.1" "https://${host}${path}" 2>/dev/null)" || rc=$?
      (( rc == 0 )) && TLS_UNVERIFIED+=("${host} (untrusted certificate)")
    fi
    if (( rc == 0 )) && grep -qiE "$pattern" <<<"$out"; then
      success "${desc} ready."
      return 0
    fi
    if (( rc == 35 && waited >= CERT_WAIT )); then
      TLS_UNVERIFIED+=("${host} (no certificate issued yet)")
      warn "${desc}: Traefik has no certificate for ${host} yet — route not verified."
      CERT_WAIT=0   # one shared grace period, not one per host
      return 0
    fi
    (( waited >= WAIT_TIMEOUT )) && error "${desc} not ready after ${WAIT_TIMEOUT}s (curl rc=${rc}) — check: sudo docker logs traefik"
    sleep 5; waited=$(( waited + 5 ))
  done
}
_route_check "https://${MATRIX_DOMAIN}/_matrix/client/versions (via Traefik)" \
  "$MATRIX_DOMAIN" /_matrix/client/versions '"versions"'
if [[ "$MATRIX_WELLKNOWN" != "external" ]]; then
  _route_check "https://${MATRIX_SERVER_NAME}/.well-known/matrix/client (with CORS)" \
    "$MATRIX_SERVER_NAME" /.well-known/matrix/client '^access-control-allow-origin: \*'
fi
if (( ${#TLS_UNVERIFIED[@]} )); then
  warn "TLS not verified for: ${TLS_UNVERIFIED[*]}."
  warn "Expected until DNS points here and ACME succeeds — Element X refuses untrusted TLS."
fi
STACK_CREATED_THIS_RUN=0   # proven up: a later failure must not tear it down

# ─────────────────────────────────────────────────────────────────────────────
# MAS: config sync + first admin
# ─────────────────────────────────────────────────────────────────────────────

step "Configuring MAS"
_mas() { sudo docker exec matrix-mas mas-cli "$@"; }
_out="$(_mas config sync 2>&1)" || { echo "$_out"; error "mas-cli config sync failed"; }
success "mas-cli config sync done."

# list-admin-users logs to stderr, one "username=<name>" line per admin
_admins="$(_mas manage list-admin-users 2>&1)" || { echo "$_admins"; error "mas-cli manage list-admin-users failed"; }
if grep -qE "username=${MATRIX_ADMIN_USER}( |$)" <<<"$_admins"; then
  success "Admin '${MATRIX_ADMIN_USER}' exists — password not touched."
  if [[ "$ADMIN_PASSWORD_DIVERGED" == "true" ]]; then
    warn "MATRIX_ADMIN_PASSWORD differs from the stored one, but it is applied at first"
    warn "install only — the stored password in ${ENV_FILE} stays in effect. Change it with:"
    warn "  sudo docker exec -it matrix-mas mas-cli manage set-password ${MATRIX_ADMIN_USER} '<new>'"
    warn "and update MATRIX_ADMIN_PASSWORD in ${ENV_FILE} to match."
  fi
else
  # mas-cli has no stdin option for the password: it is visible in the
  # container's process list for the duration of this call only.
  _out="$(_mas manage register-user --yes --admin --password "$MATRIX_ADMIN_PASSWORD" "$MATRIX_ADMIN_USER" 2>&1)" \
    || { echo "$_out"; error "Could not create the MAS admin '${MATRIX_ADMIN_USER}' (exists as a non-admin? promote it: sudo docker exec matrix-mas mas-cli manage promote-admin ${MATRIX_ADMIN_USER})"; }
  success "Admin '${MATRIX_ADMIN_USER}' created."
fi

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL (calls only — everything else goes through Traefik on 443)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$MATRIX_RTC" == "true" ]]; then
  ufw_firewall_section "Matrix calls (LiveKit)" \
    "$LIVEKIT_TCP_PORT" tcp "matrix livekit ice/tcp" \
    "$LIVEKIT_UDP_PORT" udp "matrix livekit udp mux"
  warn "Docker-published ports bypass UFW INPUT rules — ${LIVEKIT_TCP_PORT}/tcp and"
  warn "${LIVEKIT_UDP_PORT}/udp are reachable whenever the host is."
else
  step "Skipping UFW (no calls: Traefik owns 80/443, no port 8448)"
fi

trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Matrix setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Server name${RESET}        ${MATRIX_SERVER_NAME}   (users: @name:${MATRIX_SERVER_NAME})"
echo -e "  ${BOLD}Element Web${RESET}        https://${MATRIX_CHAT_DOMAIN}"
echo -e "  ${BOLD}Homeserver${RESET}         https://${MATRIX_DOMAIN}"
echo -e "  ${BOLD}Accounts (MAS)${RESET}     https://${MATRIX_AUTH_DOMAIN}"
[[ "$MATRIX_RTC" == "true" ]]      && echo -e "  ${BOLD}Calls (LiveKit)${RESET}    https://${MATRIX_RTC_DOMAIN}  + ${LIVEKIT_TCP_PORT}/tcp, ${LIVEKIT_UDP_PORT}/udp"
[[ "$MATRIX_ADMIN_UI" == "true" ]] && echo -e "  ${BOLD}Admin UI${RESET}           https://${MATRIX_ADMIN_DOMAIN}  (allowlist: ${MATRIX_ADMIN_ALLOW_CIDRS})"
echo -e "  ${BOLD}Federation${RESET}         ${MATRIX_FEDERATION}"
echo -e "  ${BOLD}Admin user${RESET}         ${MATRIX_ADMIN_USER}"
echo -e "  ${BOLD}Admin password${RESET}     sudo grep MATRIX_ADMIN_PASSWORD ${ENV_FILE}"
echo -e "  ${BOLD}Data / secrets${RESET}     ${MATRIX_HOME}  (secrets: ${ENV_FILE}, mode 600)"
echo ""
echo -e "${YELLOW}  DNS records needed (A/AAAA → this host, or NetBird DNS for VPN-only):${RESET}"
echo -e "  ${MATRIX_DOMAIN}, ${MATRIX_AUTH_DOMAIN}, ${MATRIX_CHAT_DOMAIN}"
[[ "$MATRIX_RTC" == "true" ]]      && echo -e "  ${MATRIX_RTC_DOMAIN}"
[[ "$MATRIX_ADMIN_UI" == "true" ]] && echo -e "  ${MATRIX_ADMIN_DOMAIN}"
[[ "$MATRIX_WELLKNOWN" == "traefik" ]] && echo -e "  ${MATRIX_SERVER_NAME}  (serves /.well-known/matrix/*)"
if [[ "$MATRIX_WELLKNOWN" == "external" ]]; then
  echo ""
  echo -e "${YELLOW}  Publish on https://${MATRIX_SERVER_NAME} (MATRIX_WELLKNOWN=external):${RESET}"
  echo -e "  /.well-known/matrix/client"
  echo "${WELLKNOWN_CLIENT_JSON}"
  if [[ "$PUBLISH_SERVER_WELLKNOWN" == "true" ]]; then
    echo -e "  /.well-known/matrix/server"
    echo "${WELLKNOWN_SERVER_JSON}"
  fi
  echo -e "  Headers: Content-Type: application/json, Access-Control-Allow-Origin: *"
fi
echo ""
echo -e "${YELLOW}  Next steps:${RESET}"
echo -e "  Add a user        : sudo docker exec -it matrix-mas mas-cli manage register-user <name>"
echo -e "  Team onboarding   : README_MATRIX.md (install Element X, SAVE YOUR RECOVERY KEY)"
echo -e "  Backups           : add 'matrix' to BACKUP_SERVICES (setup-backup-client.sh --services matrix)"
echo -e "  Upgrades          : read Synapse's docs/upgrade.md and back up before bumping SYNAPSE_IMAGE"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Logs     : sudo docker compose -f ${COMPOSE_FILE} logs -f synapse mas"
echo -e "  Restart  : sudo docker compose -f ${COMPOSE_FILE} restart"
echo -e "  mas-cli  : sudo docker exec matrix-mas mas-cli manage --help"
echo ""
