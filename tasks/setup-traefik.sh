#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-traefik.sh — Install Traefik v3 reverse proxy
# =============================================================================
#
# PURPOSE: Deploy production-ready Traefik v3 on Ubuntu with Docker Compose.
# Features: TLS via Let's Encrypt, security headers, rate limiting, basic auth.
#
# KEY VARIABLES:
#   TRAEFIK_HOME=/opt/traefik     - Config directory
#   TRAEFIK_DASHBOARD=false       - Enable dashboard (requires DOMAIN)
#   SOCKET_PROXY_IMAGE=<pinned>   - docker-socket-proxy image (pinned tag+digest)
#   ACME_EMAIL=admin@example.com  - Let's Encrypt email
#   DNS_PROVIDER=                 - Cloudflare or empty for HTTP challenge
#   CF_DNS_API_TOKEN=             - Required if using DNS challenge
#
# USAGE:
#   ./tasks/setup-traefik.sh                      # Default setup
#   TRAEFIK_DASHBOARD=true ACME_EMAIL=x@y.com \
#     ./tasks/setup-traefik.sh --interactive
#   ./tasks/setup-traefik.sh --help               # Show help and exit
#
# =============================================================================

set -euo pipefail

# Determine script directory and source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/traefik"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ CONFIGURATION — defaults; override via environment variables           │
# │                                                                         │
# │   ┌──────────────┐    ┌──────────────┐                                 │
# │   │ ENV VARS     │──▶│ Script vars  │                                 │
# │   │ \(optional\)   │    │ \(with defaults\)                            │
# │   └──────────────┘    └──────────────┘                                 │
# │                                                                         │
# │   TRAEFIK_HOME=/opt/traefik    # Config directory                      │
# │   TRAEFIK_DASHBOARD=false      # Enable dashboard                       │
# │   SOCKET_PROXY_IMAGE=pinned    # docker-socket-proxy image (pinned)     │
# │   ACME_EMAIL=admin@example.com # Let's Encrypt email                    │
# │   DNS_PROVIDER=                # Cloudflare or empty for HTTP          │
# └─────────────────────────────────────────────────────────────────────────┘

TRAEFIK_HOME="${TRAEFIK_HOME:-/opt/traefik}"
TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-$(kw_image traefik)}"
# Pinned on purpose: this container fronts /var/run/docker.sock.
# Tag + digest live in versions.yml (key socket-proxy); Renovate keeps both current.
SOCKET_PROXY_IMAGE="${SOCKET_PROXY_IMAGE:-$(kw_image socket-proxy)}"
export SOCKET_PROXY_IMAGE
TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN:-traefik.example.com}"
TRAEFIK_DASHBOARD="${TRAEFIK_DASHBOARD:-false}"
ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
ACME_STAGING="${ACME_STAGING:-false}"
DNS_PROVIDER="${DNS_PROVIDER:-}"
CF_DNS_API_TOKEN="${CF_DNS_API_TOKEN:-}"
TRAEFIK_ADMIN_USER="${TRAEFIK_ADMIN_USER:-admin}"
TRAEFIK_ADMIN_PASS="${TRAEFIK_ADMIN_PASS:-}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
USE_SOCKET_PROXY="${USE_SOCKET_PROXY:-true}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ COLOURS & HELPERS (using library helpers)                              │
# └─────────────────────────────────────────────────────────────────────────┘

# Logging functions are now provided by lib/helpers.sh

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ ARGUMENT PARSING — parse command-line flags                            │
# │                                                                         │
# │   $@ arguments                                                          │
# │        │                                                                  │
# │        ▼                                                                  │
# │   ┌───────────────┐                                                     │
# │   │ for arg in \$@│                                                     │
# │   └──────┬────────┘                                                     │
# │          │                                                              │
# │     ┌────┴────┐                                                          │
# │  --interactive?                                             │
# │        │                                                                  │
# │   YES│NO                                                                   │
# │    ▼       │                                                             │
# │ INTERACTIVE= true │ Ignore unknown                                      │
# │      true     │ flags                                                   │
# └─────────────────────────────────────────────────────────────────────────┘

# Re-run policy (ticket 12): an existing stack is CONVERGED by default;
# --interactive may additionally offer tear-down/re-create ('y' is the only
# path that runs 'docker compose down').
INTERACTIVE=false

# USAGE / HELP
usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Deploys production-ready Traefik v3 reverse proxy on Ubuntu with Docker
Compose: TLS via Let's Encrypt (HTTP or DNS challenge), security headers,
rate limiting, and optional dashboard with basic auth.

${BOLD}Options:${RESET}
  --interactive   Offer tear-down/re-create of an existing stack (default:
                  converge); prompt on other risky conditions
  -h, --help      Show this help and exit

Re-running against an existing stack converges it: the config is re-rendered,
the stored credentials are reused, and 'docker compose up -d' reconciles only
what changed. Divergent static settings (mode/dashboard, ACME, ports, …) are
printed with the exact re-create command; they are never applied silently.

${BOLD}Environment variables${RESET} (all optional):
  TRAEFIK_HOME        Config directory (default: /opt/traefik)
  TRAEFIK_IMAGE       Traefik image tag (default: $(kw_image traefik))
  SOCKET_PROXY_IMAGE  Docker socket-proxy image, pinned tag+digest (default:
                      $(kw_image socket-proxy))
  TRAEFIK_DOMAIN      Traefik's own domain (default: traefik.example.com)
  TRAEFIK_DASHBOARD   Enable dashboard: true/false (default: false)
  ACME_EMAIL          Let's Encrypt email (default: admin@example.com)
  ACME_STAGING        Use Let's Encrypt staging: true/false (default: false)
  DNS_PROVIDER        Cloudflare (or empty for HTTP challenge) (default: empty)
  CF_DNS_API_TOKEN    Cloudflare API token (required for DNS challenge)
  TRAEFIK_ADMIN_USER  Dashboard basic-auth user (default: admin)
  TRAEFIK_ADMIN_PASS  Dashboard basic-auth password (auto-generated if empty)
  PROXY_NETWORK       Shared Docker network name (default: proxy)
  USE_SOCKET_PROXY    Route via docker.sock proxy: true/false (default: true)
  HTTP_PORT           HTTP entrypoint port (default: 80)
  HTTPS_PORT          HTTPS entrypoint port (default: 443)
  WAIT_TIMEOUT        Max seconds to wait for the stack to come up and become
                      healthy after 'docker compose up -d' (default: 180)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --interactive) INTERACTIVE=true ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $arg (see --help)" ;;
  esac
done

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ VALIDATION — ensure ACME_EMAIL is provided                             │
# │                                                                         │
# │     ACME_EMAIL set?                                                     │
# │          │                                                              │
# │   ┌─────┴──────┐                                                        │
# │   │            │                                                        │
# │  YES│           NO                                                       │
# │    ▼            ▼                                                        │
# │ Proceed      Check if default used                                        │
# │              │                                                            │
# │              ▼                                                            │
# │     ┌───────────────┐                                                    │
# │     │ Default email?│                                                    │
# │     └───────┬───────┘                                                    │
# │             │                                                            │
# │          YES│NO                                                          │
# │             ▼                                                            │
# │    Fail with error + instructions                                        │
# │    (exit 1)                                                              │
# └─────────────────────────────────────────────────────────────────────────┘

if [[ "$ACME_EMAIL" == "admin@example.com" ]]; then
  echo ""
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${RED}║   ERROR: ACME_EMAIL not configured!                      ║${RESET}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo "Let's Encrypt requires a valid email address for account registration."
  echo "The default 'admin@example.com' is rejected by Let's Encrypt."
  echo ""
  echo -e "${YELLOW}Please run with your real email:${RESET}"
  echo ""
  echo -e "${BOLD}  ACME_EMAIL=your@email.com ./tasks/setup-traefik.sh${RESET}"
  echo ""
  echo "Examples:"
  echo -e "  ${CYAN}ACME_EMAIL=admin@denkfabrik.space ./tasks/setup-traefik.sh${RESET}"
  echo -e "  ${CYAN}ACME_EMAIL=admin@example.com ./tasks/setup-traefik.sh${RESET}"
  echo ""
  exit 1
fi

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ PRE-FLIGHT CHECKS — verify prerequisites before proceeding             │
# │                                                                         │
# │     ┌─────────────┐                                                     │
# │     │ Docker      │ → Check installed                                   │
# │     └──────┬──────┘                                                     │
# │            ▼                                                              │
# │   ┌─────────────────┐                                                   │
# │   │ Docker daemon   │ → Check running                                   │
# │   └──────┬──────────┘                                                   │
# │          ▼                                                              │
# │   ┌─────────────────┐                                                   │
# │   │ User in docker  │ → Check group membership                          │
# │   └──────┬──────────┘                                                   │
# │          ▼                                                              │
# │   ┌─────────────────┐                                                   │
# │   │ htpasswd        │ → Install if missing                              │
# │   └─────────────────┘                                                   │
# └─────────────────────────────────────────────────────────────────────────┘
step "Running pre-flight checks"

if ! command -v docker &>/dev/null; then
  error "Docker is not installed or not in PATH. Run setup-docker.sh first."
fi
success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected."

# Daemon check via sudo: an unprivileged 'docker info' also fails when this
# shell lacks docker-group membership (stale session right after
# setup-docker), which would masquerade a group problem as a dead daemon.
if ! sudo docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi
success "Docker daemon is running."

if ! groups | grep -qw docker; then
  if getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qxF "$(id -un)"; then
    error "User is in the docker group, but this shell predates the change (stale session). Log out and back in, then re-run."
  fi
  error "Current user is not in the docker group. Fix with: sudo usermod -aG docker \$USER (then log out and back in)"
fi
success "User is in the docker group."

if ! command -v htpasswd &>/dev/null; then
  info "htpasswd not found — installing apache2-utils..."
  if ! sudo apt-get install -y apache2-utils; then
    error "Failed to install apache2-utils. Please install it manually and re-run."
  fi
fi
success "htpasswd is available."

# ── envsubst preflight ───────────────────────────────────────────────────────
if ! command -v envsubst &>/dev/null; then
  error "envsubst not installed — install with: sudo apt-get install gettext-base"
fi
success "envsubst is available."
# ── IDEMPOTENCY / RE-RUN POLICY (ticket 12) ──────────────────────────────────
# Existing stack (running, or stopped with a compose file) → CONVERGE by
# default: re-render config below, reuse stored credentials, 'up -d'
# reconciles what changed. With --interactive the operator may answer 'y' to
# tear down and re-create first; a non-interactive run never tears down and
# never exits 0 silently. Static-key divergence on a running stack is printed
# with the exact remedy (see the hash check after the compose render) + exit 0.
step "Checking for an existing Traefik installation"

COMPOSE_FILE="${TRAEFIK_HOME}/docker-compose.yml"
TRAEFIK_RUNNING=false

if docker ps --format '{{.Names}}' | grep -qx 'traefik' 2>/dev/null; then
  TRAEFIK_RUNNING=true
fi

# Re-run policy (ticket 12): an existing stack is CONVERGED — the config is
# re-rendered below and 'docker compose up -d' reconciles only what changed.
# Tear-down is never part of a normal (non-interactive) run; with
# --interactive the operator may confirm a re-create (the letsencrypt data,
# i.e. the ACME account and certificates, is preserved either way).
RECREATE=false
if [[ "$TRAEFIK_RUNNING" == "true" || -f "$COMPOSE_FILE" ]]; then
  if [[ "$TRAEFIK_RUNNING" == "true" ]]; then
    warn "Existing Traefik stack is running — it will be converged (no tear-down)."
  else
    warn "Existing ${COMPOSE_FILE} found (no container running) — it will be converged (no tear-down)."
  fi
  if [[ "$INTERACTIVE" == "true" ]]; then
    CONTAINER_INFO=$(docker ps --filter name='^traefik$' --format 'Image: {{.Image}} | Status: {{.Status}}' 2>/dev/null || true)
    info "Existing Traefik container found: ${CONTAINER_INFO}"
    read -rp "    Stack exists. Converge (default) or tear down and re-create? [c/N] " _answer
    if [[ "${_answer,,}" == "y" ]]; then
      RECREATE=true
    fi
  fi
  if [[ "$RECREATE" == "true" ]]; then
    info "Stopping and removing existing stack..."
    docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
    success "Existing stack removed."
  fi
fi

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ SHARED DOCKER NETWORK — create the proxy network                       │
# │                                                                         │
# │     docker network create                                               │
# │          │                                                              │
# │   ┌─────┴──────┐                                                        │
# │   │            │                                                        │
# │ EXISTS│       CREATED                                                   │
# │    ▼         │                                                          │
# │  Skip      Success                                                      │
# └─────────────────────────────────────────────────────────────────────────┘
step "Creating shared Docker network '${PROXY_NETWORK}'"

if _net_err=$(docker network create "${PROXY_NETWORK}" 2>&1); then
  success "Docker network '${PROXY_NETWORK}' created."
else
  if echo "${_net_err}" | grep -qi 'already exists'; then
    warn "Network '${PROXY_NETWORK}' already exists — skipping."
  else
    error "Failed to create Docker network '${PROXY_NETWORK}': ${_net_err}"
  fi
fi

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ DIRECTORY STRUCTURE — create Traefik configuration directories         │
# │                                                                         │
# │     /opt/traefik/                                                       │
# │     ├── dynamic/                                                        │
# │     │   ├── middlewares.yml                                             │
# │     │   ├── tls.yml                                                     │
# │     │   └── host-services.yml.example                                   │
# │     ├── letsencrypt/                                                    │
# │     │   └── acme.json \(chmod 600\)                                       │
# │     ├── auth/                                                           │
# │     │   └── .htpasswd                                                   │
# │     ├── traefik.yml                                                     │
# │     └── docker-compose.yml                                              │
# │                                                                         │
# │   Permission checks and corrections applied                             │
# └─────────────────────────────────────────────────────────────────────────┘
step "Creating directory structure under ${TRAEFIK_HOME}"

sudo mkdir -p "${TRAEFIK_HOME}/dynamic" \
              "${TRAEFIK_HOME}/letsencrypt" \
              "${TRAEFIK_HOME}/auth"

ACME_JSON="${TRAEFIK_HOME}/letsencrypt/acme.json"
if [[ ! -f "${ACME_JSON}" ]]; then
  sudo touch "${ACME_JSON}"
  sudo chmod 600 "${ACME_JSON}"
  success "Created ${ACME_JSON} (chmod 600)."
else
  # Verify and correct permissions if needed
  _perms=$(stat -c '%a' "${ACME_JSON}" 2>/dev/null || stat -f '%A' "${ACME_JSON}" 2>/dev/null || echo "unknown")
  if [[ "${_perms}" != "600" ]]; then
    sudo chmod 600 "${ACME_JSON}"
    warn "Corrected permissions on ${ACME_JSON} (was ${_perms}, now 600)."
  else
    success "${ACME_JSON} already exists with correct permissions (600)."
  fi
fi

success "Directory structure ready."

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ CREDENTIAL GENERATION — generate BCrypt-hashed password                │
# │                                                                         │
# │     TRAEFIK_ADMIN_PASS set?                                             │
# │          │                                                              │
# │   ┌─────┴──────┐                                                        │
# │   │            │                                                        │
# │  YES│           NO                                                       │
# │    ▼            ▼                                                        │
# │ Use provided  Generate random                                          │
# │ password      \(openssl/rand\)                                           │
# │               │                                                          │
# │               ▼                                                          │
# │          ┌───────────────┐                                              │
# │          │ htpasswd -nbB │                                              │
# │          │ -C 12         │                                              │
# │          └───────┬───────┘                                              │
# │                  ▼                                                       │
# │          Write to auth/.htpasswd                                        │
# │          \(chmod 600\)                                                    │
# └─────────────────────────────────────────────────────────────────────────┘
step "Generating dashboard credentials"

PASS_GENERATED=false
if [[ -z "${TRAEFIK_ADMIN_PASS}" && -f "${TRAEFIK_HOME}/.credentials" ]]; then
  # Re-run policy (ticket 12): reuse the previously generated dashboard
  # password so a re-run never rotates the dashboard login.
  TRAEFIK_ADMIN_PASS="$(grep -m1 '^Admin password: ' "${TRAEFIK_HOME}/.credentials" | cut -d' ' -f3- || true)"
  if [[ -n "${TRAEFIK_ADMIN_PASS}" ]]; then
    info "Reusing existing dashboard password from ${TRAEFIK_HOME}/.credentials."
  fi
fi
if [[ -z "${TRAEFIK_ADMIN_PASS}" ]]; then
  PASS_GENERATED=true
  if command -v openssl &>/dev/null; then
    TRAEFIK_ADMIN_PASS="$(openssl rand -base64 18)"
  else
    TRAEFIK_ADMIN_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
  fi
fi

HTPASSWD_HASH="$(htpasswd -nbB -C 12 "${TRAEFIK_ADMIN_USER}" "${TRAEFIK_ADMIN_PASS}")"

_htpasswd_tmp="$(mktemp)"
echo "${HTPASSWD_HASH}" > "${_htpasswd_tmp}"
sudo mv "${_htpasswd_tmp}" "${TRAEFIK_HOME}/auth/.htpasswd"
sudo chmod 600 "${TRAEFIK_HOME}/auth/.htpasswd"

success "Credentials generated and written to ${TRAEFIK_HOME}/auth/.htpasswd"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ CONFIGURATION FILE GENERATION — generate all Traefik config files     │
# │                                                                         │
# │     ┌─────────────────────────────────────────────────────────────┐    │
# │     │ .env \(environment variables\)                                │    │
# │     │   - DOMAIN                                                  │    │
# │     │   - ACME_EMAIL                                              │    │
# │     │   - CF_DNS_API_TOKEN                                        │    │
# │     └─────────────┬───────────────────────────────────────────────┘    │
# │                   ▼                                                     │
# │     ┌─────────────────────────────────────────────────────────────┐    │
# │     │ traefik.yml \(Static Config\)                                 │    │
# │     │   - API/Dashboard settings                                  │    │
# │     │   - Entry points: web → websecure                           │    │
# │     │   - Providers: docker + file                                │    │
# │     │   - CertificatesResolvers: letsencrypt                      │    │
# │     └─────────────┬───────────────────────────────────────────────┘    │
# │                   ▼                                                     │
# │     ┌─────────────────────────────────────────────────────────────┐    │
# │     │ dynamic/middlewares.yml                                     │    │
# │     │   - security-headers                                        │    │
# │     │   - rate-limit                                              │    │
# │     │   - auth-basic                                              │    │
# │     │   - ip-allowlist-private                                    │    │
# │     │   - dashboard-security \(chain\)                              │    │
# │     └─────────────┬───────────────────────────────────────────────┘    │
# │                   ▼                                                     │
# │     ┌─────────────────────────────────────────────────────────────┐    │
# │     │ dynamic/tls.yml                                             │    │
# │     │   - minVersion: TLS12                                       │    │
# │     │   - sniStrict: true                                         │    │
# │     │   - cipherSuites \(ECDSA + RSA\)                              │    │
# │     └─────────────┬───────────────────────────────────────────────┘    │
# │                   ▼                                                     │
# │     ┌─────────────────────────────────────────────────────────────┐    │
# │     │ dynamic/host-services.yml.example                           │    │
# │     │   \(Reference file only\)                                     │    │
# │     └─────────────────────────────────────────────────────────────┘    │
# └─────────────────────────────────────────────────────────────────────────┘
step "Generating configuration files"

# ── .env ─────────────────────────────────────────────────────────────────────
# Re-run policy (ticket 12): a Cloudflare token that is not set explicitly is
# read back from the existing .env so a re-run never drops the credential the
# already-issued ACME account depends on (explicit env always wins).
if [[ -z "${CF_DNS_API_TOKEN}" && -f "${TRAEFIK_HOME}/.env" ]]; then
  CF_DNS_API_TOKEN="$(env_file_get "${TRAEFIK_HOME}/.env" CF_DNS_API_TOKEN || true)"
fi

info "Writing ${TRAEFIK_HOME}/.env ..."
_env_tmp="$(mktemp)"
{
  echo "DOMAIN=${TRAEFIK_DOMAIN}"
  echo "ACME_EMAIL=${ACME_EMAIL}"
  if [[ "${DNS_PROVIDER}" == "cloudflare" && -n "${CF_DNS_API_TOKEN}" ]]; then
    echo "CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}"
  fi
} > "${_env_tmp}"
sudo mv "${_env_tmp}" "${TRAEFIK_HOME}/.env"
sudo chmod 600 "${TRAEFIK_HOME}/.env"
success ".env written."

# ── traefik.yml \(Static Configuration\) ───────────────────────────────────────
info "Writing ${TRAEFIK_HOME}/traefik.yml ..."
_traefik_yml_tmp="$(mktemp)"

# Build Docker provider endpoint
if [[ "${USE_SOCKET_PROXY}" == "true" ]]; then
  _docker_endpoint="tcp://socket-proxy:2375"
else
  _docker_endpoint="unix:///var/run/docker.sock"
fi

# Build dashboard flag
if [[ "${TRAEFIK_DASHBOARD}" == "true" ]]; then
  _api_dashboard="true"
else
  _api_dashboard="false"
fi

# Select template: challenge type (DNS provider set?) x ACME environment
if [[ -n "${DNS_PROVIDER}" ]]; then
  _acme_variant="dns"
else
  _acme_variant="http"
fi
if [[ "${ACME_STAGING}" == "true" ]]; then
  _acme_env="staging"
else
  _acme_env="prod"
fi
_traefik_template="${TEMPLATE_DIR}/traefik.${_acme_env}.${_acme_variant}.yml"

# Export variables for envsubst (envsubst reads the environment, not the shell
# — every listed variable must be exported or it renders empty; the VM-verified
# symptom of a missing export is entryPoints.address: ":", i.e. a random port)
export _api_dashboard _docker_endpoint DNS_PROVIDER HTTP_PORT HTTPS_PORT PROXY_NETWORK ACME_EMAIL
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${_api_dashboard} ${_docker_endpoint} ${DNS_PROVIDER} ${HTTP_PORT} ${HTTPS_PORT} ${PROXY_NETWORK} ${ACME_EMAIL}' \
  < "${_traefik_template}" > "${_traefik_yml_tmp}"

sudo mv "${_traefik_yml_tmp}" "${TRAEFIK_HOME}/traefik.yml"
success "traefik.yml written."

# ── dynamic/middlewares.yml ───────────────────────────────────────────────────
info "Writing ${TRAEFIK_HOME}/dynamic/middlewares.yml ..."
sudo cp "${TEMPLATE_DIR}/middlewares.yml" "${TRAEFIK_HOME}/dynamic/middlewares.yml"
success "dynamic/middlewares.yml written."

# ── dynamic/tls.yml ───────────────────────────────────────────────────────────
info "Writing ${TRAEFIK_HOME}/dynamic/tls.yml ..."
sudo cp "${TEMPLATE_DIR}/tls-options.yml" "${TRAEFIK_HOME}/dynamic/tls.yml"
success "dynamic/tls.yml written."

# ── dynamic/host-services.yml.example ────────────────────────────────────────
info "Writing ${TRAEFIK_HOME}/dynamic/host-services.yml.example ..."
sudo cp "${TEMPLATE_DIR}/host-services.yml" "${TRAEFIK_HOME}/dynamic/host-services.yml.example"
success "dynamic/host-services.yml.example written."

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ DOCKER COMPOSE FILE — generate docker-compose.yml                      │
# │                                                                         │
# │     TRAEFIK_DASHBOARD enabled?                                          │
# │          │                                                              │
# │   ┌─────┴──────┐                                                        │
# │   │            │                                                        │
# │  YES│           NO                                                       │
# │    ▼            │                                                        │
# │ Warn about      Proceed                                                  │
# │ default domain  with validation                                          │
# └──────────────────────────┬───────────────────────────────────────────────┘
#                            │
#                            ▼
# │   USE_SOCKET_PROXY?                                                    │
# │          │                                                              │
# │   ┌─────┴──────┐                                                        │
# │   │            │                                                        │
# │  YES│           NO                                                       │
# │    ▼            │                                                        │
# │ Write socket-proxy│ Write without                                       │
# │ service           │ socket-proxy                                         │
# │                   │                                                       │
# └───────────┬───────┴───────────────────────────────────────────────────────┘
#             │
#             ▼
# ┌─────────────────────────────────────────────────────────────────────────┐
# │                    TRAEFIK SERVICE DEFINITION                           │
# │                                                                         │
# │   image: []                                               │
# │   container_name: traefik                                               │
# │   restart: unless-stopped                                               │
# │   security_opt: [no-new-privileges:true]                                │
# │                                                                         │
# │   depends_on:                                                           │
# │     socket-proxy [conditional on USE_SOCKET_PROXY=true]                 │
# │                                                                         │
# │   ports:                                                                │
# │     - target: [] \(80\)//, published, mode:host                   │
# │     - target: [] \(443\)//, published, mode:host                 │
# │                                                                         │
# │   extra_hosts:                                                          │
# │     - "host.docker.internal:host-gateway"                               │
# │                                                                         │
# │   volumes:                                                              │
# │     - traefik.yml:/etc/traefik/traefik.yml:ro                           │
# │     - dynamic/:/etc/traefik/dynamic:ro                                  │
# │     - letsencrypt/:/letsencrypt                                         │
# │     - auth/:/etc/traefik/auth:ro                                        │
# │                                                                         │
# │   env_file: .env [if DNS challenge]                                     │
# │                                                                         │
# │   networks:                                                             │
# │     - socket-net [if USE_SOCKET_PROXY=true]                             │
# │     - []                                                  │
# │                                                                         │
# │   labels:                                                               │
# │     traefik.enable=true                                                 │
# │     traefik.docker.network=[]                             │
# │     [dashboard labels if enabled]                                       │
# └─────────────────────────────────────────────────────────────────────────┘
#             │
#             ▼
# ┌─────────────────────────────────────────────────────────────────────────┐
# │                      NETWORKS SECTION                                   │
# │                                                                         │
# │   socket-net:                                                           │
# │     internal: true                                                      │
# │   []:                                                       │
# │     external: true                                                      │
# └─────────────────────────────────────────────────────────────────────────┘

step "Generating ${COMPOSE_FILE}"

# Warn if dashboard is enabled but domain is still the default
if [[ "${TRAEFIK_DASHBOARD}" == "true" && "${TRAEFIK_DOMAIN}" == "traefik.example.com" ]]; then
  warn "TRAEFIK_DASHBOARD is enabled but TRAEFIK_DOMAIN is still the default 'traefik.example.com'."
  warn "Set TRAEFIK_DOMAIN to a real hostname before using in production!"
fi

_compose_tmp="$(mktemp)"

# ── Select compose variant ────────────────────────────────────────────────────
if [[ "${USE_SOCKET_PROXY}" == "true" ]]; then
  _compose_variant="socket"
else
  _compose_variant="nosocket"
fi

if [[ "${TRAEFIK_DASHBOARD}" == "true" ]]; then
  _compose_variant="${_compose_variant}.dash"
else
  _compose_variant="${_compose_variant}.plain"
fi

if [[ -n "${DNS_PROVIDER}" && -n "${CF_DNS_API_TOKEN}" ]]; then
  _compose_variant="${_compose_variant}.dns"
else
  _compose_variant="${_compose_variant}.nodns"
fi

COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.${_compose_variant}.yml"

# Export variables for envsubst
export TRAEFIK_IMAGE SOCKET_PROXY_IMAGE HTTP_PORT HTTPS_PORT TRAEFIK_HOME PROXY_NETWORK TRAEFIK_DOMAIN
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${TRAEFIK_IMAGE} ${SOCKET_PROXY_IMAGE} ${HTTP_PORT} ${HTTPS_PORT} ${TRAEFIK_HOME} ${PROXY_NETWORK} ${TRAEFIK_DOMAIN}' \
  < "${COMPOSE_TEMPLATE}" > "${_compose_tmp}"

sudo mv "${_compose_tmp}" "${COMPOSE_FILE}"
success "docker-compose.yml written to ${COMPOSE_FILE}"

# ── Re-run policy (ticket 12): static keys cannot converge a running stack ──
# The rendered config (compose + traefik.yml + .env) is hashed and compared
# with what the running stack was last created from. A difference means a
# static compose arg or traefik.yml key changed (mode/dashboard, ACME
# settings, DNS_PROVIDER, USE_SOCKET_PROXY, ports): a plain 'up -d' would not
# apply it correctly (the ACME account in ${TRAEFIK_HOME}/letsencrypt is
# already issued, mounted config is only re-read on (re)create) — so print the
# exact remedy and exit 0. A missing stored hash (pre-ticket install) is
# treated as unknown: 'up -d' reconciles and the hash is recorded after.
CONVERGE_HASH_FILE="${TRAEFIK_HOME}/.converge-hash"
_render_hash="$(cat "${COMPOSE_FILE}" "${TRAEFIK_HOME}/traefik.yml" "${TRAEFIK_HOME}/.env" | sed '/^# Generated/d' | sha256sum | awk '{print $1}')"
if [[ "$TRAEFIK_RUNNING" == "true" && "$RECREATE" != "true" ]]; then
  _stored_hash="$(sudo cat "${CONVERGE_HASH_FILE}" 2>/dev/null || true)"
  if [[ -n "${_stored_hash}" && "${_stored_hash}" != "${_render_hash}" ]]; then
    warn "Rendered Traefik config differs from what the running stack was created from."
    warn "Static compose args and traefik.yml settings (mode/dashboard, ACME settings,"
    warn "DNS_PROVIDER, USE_SOCKET_PROXY, ports) cannot be applied to a running stack —"
    warn "the ACME account in ${TRAEFIK_HOME}/letsencrypt is already issued."
    warn "Converge now:"
    warn "  docker compose -f ${COMPOSE_FILE} up -d --force-recreate traefik"
    warn "Or tear down and re-create interactively:"
    warn "  $0 --interactive"
    exit 0
  fi
fi

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ STACK STARTUP — pull, start, and wait for health                       │
# │                                                                         │
# │     docker compose pull                                                 │
# │          │                                                              │
# │          ▼                                                              │
# │     docker compose up -d                                                │
# │          │                                                              │
# │          ▼                                                              │
# │   ┌───────────────────┐         ┌─────────────────────────────┐       │
# │   │ Wait for health   │◀───────▶│ Check: Container healthy?   │       │
# │   │ check \(60s max\)   │         └──────────────┬──────────────┘       │
# │   └───────────────────┘                       │ YES                   │
# │          ▲                                  │                         │
# │          │ NO                              ▼                         │
# │          └──────────────────────────────▶│  SUCCESS │                 │
# └─────────────────────────────────────────────────────────────────────────┘
step "Pulling Docker images"
if ! docker compose -f "${COMPOSE_FILE}" pull; then
  error "Failed to pull Docker images. Check the error output above."
fi
success "Images pulled."

step "Starting Traefik stack (detached)"
if ! docker compose -f "${COMPOSE_FILE}" up -d; then
  error "Failed to start Traefik stack. Check the error output above."
fi

# Health gate: prove the containers (traefik + optional socket proxy) are
# actually up before reporting success.
mapfile -t _ids < <(docker compose -f "${COMPOSE_FILE}" ps -q)
wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
  || error "Traefik stack did not come up — see the status output above"

# Re-run policy (ticket 12): record what the stack is now created from, so
# the next run can detect divergent static config (see hash check above).
printf '%s\n' "${_render_hash}" | sudo tee "${CONVERGE_HASH_FILE}" >/dev/null

step "Waiting for Traefik container to become healthy (up to 60s)"
MAX_WAIT=60
INTERVAL=5
ELAPSED=0
HEALTH_OK=false

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  _status="$(docker ps --filter 'name=^traefik$' --format '{{.Status}}' 2>/dev/null || true)"
  if [[ -n "${_status}" ]]; then
    HEALTH_OK=true
    break
  fi
  echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s ..."
  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo ""

if [[ "${HEALTH_OK}" == "true" ]]; then
  success "Traefik is up and running!"
else
  warn "Traefik container did not appear within ${MAX_WAIT}s."
  warn "It may still be starting. Check logs with:"
  warn "  docker compose -f ${COMPOSE_FILE} logs -f traefik"
fi

# ┌─────────────────────────────────────────────────────────────────────────┐
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ UFW FIREWALL — open ports if UFW is active                             │
# └─────────────────────────────────────────────────────────────────────────┘
step "Configuring UFW firewall"

if ufw_available && ufw_active; then
  info "UFW is active — opening ports ${HTTP_PORT}/tcp and ${HTTPS_PORT}/tcp ..."
  ufw_add_rule "${HTTP_PORT}" "tcp" "HTTP"
  ufw_add_rule "${HTTPS_PORT}" "tcp" "HTTPS"
else
  warn "UFW is not installed or not active — skipping firewall configuration."
  warn "Make sure ports ${HTTP_PORT} and ${HTTPS_PORT} are open in your firewall."
fi

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ SUMMARY — display all credentials and quick references                  │
# │                                                                         │
# │     ┌─────────────────────────────────────────────────────────────┐    │
# │     │ IMAGE:         [TRAEFIK_IMAGE]                                │    │
# │     │ CONFIG DIR:    []]                                 │    │
# │     │ COMPOSE FILE:  []]                                 │    │
# │     │ PROXY NETWORK: [PROXY_NETWORK]                                  │    │
# │     │ ACME MODE:     Production / Staging                            │    │
# │     │ ACME CHALLENGE: HTTP or DNS                                    │    │
# │     │ ACME EMAIL:    []]                                   │    │
# │     └─────────────────────────────────────────────────────────────┘    │
# │                                                                         │
# │   IF DASHBOARD ENABLED:                                                 │
# │     ┌─────────────────────────────────────────────────────────────┐    │
# │     │ Dashboard URL: https://[]]/dashboard/            │    │
# │     │ Admin user:    []]                           │    │
# │     │ Admin password: []] \(if generated!\)          │    │
# │     └─────────────────────────────────────────────────────────────┘    │
# │                                                                         │
# │   QUICK REFERENCE: ADDING AN APP                                        │
# │     1. Add app container to '[PROXY_NETWORK]' network                  │
# │     2. Add labels:                                                      │
# │        traefik.enable=true                                                │
# │        traefik.docker.network=[]                            │
# │        traefik.http.routers.myapp.rule=Host(                              │
# │        traefik.http.routers.myapp.entrypoints=websecure                   │
# │        traefik.http.routers.myapp.tls.certresolver=letsencrypt            │
# │        traefik.http.services.myapp.loadbalancer.server.port=8080          │
# └─────────────────────────────────────────────────────────────────────────┘

# Determine ACME mode and challenge type
if [[ "${ACME_STAGING}" == "true" ]]; then
  _acme_mode="Staging (untrusted certs — for testing)"
else
  _acme_mode="Production"
fi

if [[ -n "${DNS_PROVIDER}" ]]; then
  _acme_challenge_type="DNS challenge (provider: ${DNS_PROVIDER})"
else
  _acme_challenge_type="HTTP challenge"
fi

echo ""
if [[ "${HEALTH_OK}" == "false" ]]; then
  echo -e "${YELLOW}⚠  Health check timed out — Traefik may still be starting. Run:${RESET}"
  echo -e "${YELLOW}   docker compose -f ${COMPOSE_FILE} logs -f traefik${RESET}"
  echo ""
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Traefik v3 setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Image${RESET}           ${TRAEFIK_IMAGE}"
echo -e "  ${BOLD}Config dir${RESET}      ${TRAEFIK_HOME}"
echo -e "  ${BOLD}Compose file${RESET}    ${COMPOSE_FILE}"
echo -e "  ${BOLD}Proxy network${RESET}   ${PROXY_NETWORK}"
echo -e "  ${BOLD}ACME mode${RESET}       ${_acme_mode}"
echo -e "  ${BOLD}ACME challenge${RESET}  ${_acme_challenge_type}"
echo -e "  ${BOLD}ACME email${RESET}      ${ACME_EMAIL}"
echo ""

if [[ "${TRAEFIK_DASHBOARD}" == "true" ]]; then
  echo -e "  ${BOLD}Dashboard URL${RESET}   https://${TRAEFIK_DOMAIN}/dashboard/"
  echo -e "  ${BOLD}Admin user${RESET}      ${TRAEFIK_ADMIN_USER}"
  if [[ "${PASS_GENERATED}" == "true" ]]; then
    # Save password to a secure file instead of printing to stdout
    # NOTE: Credentials kept inline (5-line heredoc) — splitting to template
    # would be silly for this small file; date computed via $(date -I).
    CREDENTIALS_FILE="${TRAEFIK_HOME}/.credentials"
    cat > "${CREDENTIALS_FILE}" <<CREDS
# Traefik Dashboard Credentials
# Generated by setup-traefik.sh — $(date -I)
# WARNING: Keep this file secure and delete after saving credentials elsewhere

Admin user: ${TRAEFIK_ADMIN_USER}
Admin password: ${TRAEFIK_ADMIN_PASS}
CREDS
    chmod 600 "${CREDENTIALS_FILE}"
    echo -e "  ${BOLD}Admin password${RESET}  ${YELLOW}saved to ${CREDENTIALS_FILE} (chmod 600)${RESET}"
  else
    echo -e "  ${BOLD}Admin password${RESET}  (as provided via TRAEFIK_ADMIN_PASS env var)"
  fi
  echo ""
fi

echo -e "${BOLD}Quick-reference — adding an app to Traefik:${RESET}"
echo -e "  1. Add your app's container to the '${PROXY_NETWORK}' Docker network."
echo -e "  2. Add these labels to your app service:"
echo -e "     ${CYAN}traefik.enable=true${RESET}"
echo -e "     ${CYAN}traefik.docker.network=${PROXY_NETWORK}${RESET}"
echo -e "     ${CYAN}traefik.http.routers.myapp.rule=Host(\`app.example.com\`)${RESET}"
echo -e "     ${CYAN}traefik.http.routers.myapp.entrypoints=websecure${RESET}"
echo -e "     ${CYAN}traefik.http.routers.myapp.tls.certresolver=letsencrypt${RESET}"
echo -e "     ${CYAN}traefik.http.services.myapp.loadbalancer.server.port=8080${RESET}"
echo ""
echo -e "${BOLD}Quick-reference — applying basic auth middleware:${RESET}"
echo -e "  Add label: ${CYAN}traefik.http.routers.myapp.middlewares=auth-basic@file${RESET}"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Follow logs    : docker compose -f ${COMPOSE_FILE} logs -f traefik"
echo -e "  Stop stack     : docker compose -f ${COMPOSE_FILE} down"
echo -e "  Start stack    : docker compose -f ${COMPOSE_FILE} up -d"
echo -e "  Restart stack  : docker compose -f ${COMPOSE_FILE} restart"
echo -e "  Shell into app : docker exec -it traefik sh"
echo ""
