#!/usr/bin/env bash
# =============================================================================
# NetBird Docker Setup Script
# =============================================================================
#
# DESCRIPTION:
#   Deploys self-hosted NetBird — a WireGuard-based mesh VPN — as Docker
#   containers: the combined server image (management + signal + relay +
#   embedded STUN + embedded IdP) and the NetBird dashboard. An optional
#   routing-peer client container (profile "client") can be started for
#   LAN exposure.
#
#   The stack is always routed through the Traefik reverse proxy on
#   ${PROXY_NETWORK} (no web host ports; gRPC over h2c). If Traefik is not set
#   up yet, it is installed first via tasks/setup-traefik.sh.
#   STUN (UDP ${STUN_PORT}) is published directly on the host.
#
# KEY ACTIONS:
#   1. Pre-flight checks: Docker, Compose v2, domain; installs Traefik
#      (setup-traefik.sh) when it is not running
#   2. Creates the persistent data directory ${NETBIRD_HOME}
#   3. Generates ${NETBIRD_HOME}/.env once (generated secrets + runtime vars, mode 600)
#   4. Copies the compose template if missing
#   5. Renders ${NETBIRD_HOME}/config.yaml from template (only if missing)
#   6. Pulls images and starts the stack (docker compose up -d)
#   7. Optionally starts the netbird-client routing peer (host IP forwarding)
#   8. Adds the UFW rule for STUN
#   9. Waits for readiness and prints access info / first-time steps
#
# IMPORTANT VARIABLES:
#   NETBIRD_HOME           - Host directory for config/data (default: /srv/netbird)
#   NETBIRD_SERVER_IMAGE   - Combined server image (default: netbirdio/netbird-server)
#   NETBIRD_SERVER_TAG     - Combined server tag (default: 0.77.1)
#   NETBIRD_DASHBOARD_IMAGE- Dashboard image (default: netbirdio/dashboard)
#   NETBIRD_DASHBOARD_TAG  - Dashboard tag (default: v2.91.1)
#   NETBIRD_CLIENT_IMAGE   - Client image for routing peer (default: netbirdio/netbird)
#   NETBIRD_CLIENT_TAG     - Client tag (default: 0.77.1)
#   NETBIRD_DOMAIN         - Public domain routed by Traefik (required)
#   STUN_PORT              - UDP STUN port published on the host (default: 3478)
#   PROXY_NETWORK          - Traefik's external Docker network (default: proxy)
#   NETBIRD_ADMIN_EMAIL    - Optional bootstrap owner user (with NETBIRD_ADMIN_PASSWORD)
#   NETBIRD_ADMIN_PASSWORD - Optional bootstrap owner password
#   NETBIRD_CLIENT_ENABLED - "true" to start the routing-peer client (default: false)
#   NETBIRD_SETUP_KEY      - Required when NETBIRD_CLIENT_ENABLED=true
#   NETBIRD_CLIENT_HOSTNAME - Client container hostname (default: netbird-peer)
#   NETBIRD_LOG_LEVEL      - Server log level (default: info)
#
# DEPENDENCIES:
#   - Docker: must be installed and daemon must be running
#   - Docker Compose v2: required for orchestration
#   - openssl: used to generate the auth/store secrets
#   - curl: used for readiness polling
#   - Traefik: installed via setup-traefik.sh when not running (that script
#     needs ACME_EMAIL; its environment variables are passed through)
#
# OUTPUTS:
#   - ${NETBIRD_HOME}/.env               - Generated secrets + runtime vars (mode 600)
#   - ${NETBIRD_HOME}/docker-compose.yml - Copied from the compose template
#   - ${NETBIRD_HOME}/config.yaml        - Rendered server config (mode 600)
#   - Docker containers: netbird-server, netbird-dashboard (+ netbird-client)
#   - Docker volumes: netbird-data, netbird-client
#
# USAGE:
#   NETBIRD_DOMAIN=netbird.example.com ./tasks/setup-netbird.sh
#
#   # First run on a host without Traefik (Traefik is installed first):
#   ACME_EMAIL=you@example.com NETBIRD_DOMAIN=netbird.example.com ./tasks/setup-netbird.sh
#
#   # Start the routing peer after creating a setup key in the dashboard:
#   NETBIRD_DOMAIN=netbird.example.com NETBIRD_CLIENT_ENABLED=true \
#     NETBIRD_SETUP_KEY=<KEY> ./tasks/setup-netbird.sh
#
#   # Upgrade: change NETBIRD_SERVER_TAG / NETBIRD_DASHBOARD_TAG and re-run.
#   # Delete ${NETBIRD_HOME}/.env and docker-compose.yml first only if you
#   # want the new values re-persisted into them.
#
#   # Show help:
#   ./tasks/setup-netbird.sh --help
#
# REFERENCE:
#   https://docs.netbird.io/selfhosted/selfhosted-quickstart
#   https://docs.netbird.io/selfhosted/external-reverse-proxy
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — all env vars with defaults
# ─────────────────────────────────────────────────────────────────────────────

NETBIRD_HOME="${NETBIRD_HOME:-/srv/netbird}"
NETBIRD_SERVER_IMAGE="${NETBIRD_SERVER_IMAGE:-netbirdio/netbird-server}"
NETBIRD_SERVER_TAG="${NETBIRD_SERVER_TAG:-0.77.1}"
NETBIRD_DASHBOARD_IMAGE="${NETBIRD_DASHBOARD_IMAGE:-netbirdio/dashboard}"
NETBIRD_DASHBOARD_TAG="${NETBIRD_DASHBOARD_TAG:-v2.91.1}"
NETBIRD_CLIENT_IMAGE="${NETBIRD_CLIENT_IMAGE:-netbirdio/netbird}"
NETBIRD_CLIENT_TAG="${NETBIRD_CLIENT_TAG:-0.77.1}"
NETBIRD_DOMAIN="${NETBIRD_DOMAIN:-}"              # required
STUN_PORT="${STUN_PORT:-3478}"                    # UDP, published on the host
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
NETBIRD_ADMIN_EMAIL="${NETBIRD_ADMIN_EMAIL:-}"    # optional bootstrap owner user
NETBIRD_ADMIN_PASSWORD="${NETBIRD_ADMIN_PASSWORD:-}"
NETBIRD_CLIENT_ENABLED="${NETBIRD_CLIENT_ENABLED:-false}"  # optional routing-peer client
NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"       # required if NETBIRD_CLIENT_ENABLED=true
NETBIRD_CLIENT_HOSTNAME="${NETBIRD_CLIENT_HOSTNAME:-netbird-peer}"
NETBIRD_LOG_LEVEL="${NETBIRD_LOG_LEVEL:-info}"

# ─────────────────────────────────────────────────────────────────────────────
# LOAD HELPERS
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/helpers.sh"

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} NETBIRD_DOMAIN=<domain> $0 [OPTIONS]

Deploys self-hosted NetBird (WireGuard-based mesh VPN) as Docker containers:
combined server (management + signal + relay + STUN + IdP) and dashboard,
routed through the Traefik reverse proxy. Optional routing-peer client
container for LAN exposure.

Traefik is a prerequisite: when no 'traefik' container is running, it is
installed first via tasks/setup-traefik.sh. That script's environment
variables (ACME_EMAIL is required; see its --help) are passed through.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional except NETBIRD_DOMAIN):
  NETBIRD_DOMAIN           Public domain routed by Traefik (required)
  NETBIRD_HOME             Host directory for config/data (default: /srv/netbird)
  NETBIRD_SERVER_IMAGE     Combined server image (default: netbirdio/netbird-server)
  NETBIRD_SERVER_TAG       Combined server tag (default: 0.77.1)
  NETBIRD_DASHBOARD_IMAGE  Dashboard image (default: netbirdio/dashboard)
  NETBIRD_DASHBOARD_TAG    Dashboard tag (default: v2.91.1)
  NETBIRD_CLIENT_IMAGE     Client image for routing peer (default: netbirdio/netbird)
  NETBIRD_CLIENT_TAG       Client tag (default: 0.77.1)
  STUN_PORT                UDP STUN port published on the host (default: 3478)
  PROXY_NETWORK            Traefik's external Docker network (default: proxy)
  NETBIRD_ADMIN_EMAIL      Optional bootstrap owner user (with NETBIRD_ADMIN_PASSWORD)
  NETBIRD_ADMIN_PASSWORD   Optional bootstrap owner password
  NETBIRD_CLIENT_ENABLED   "true" to start the routing-peer client (default: false)
  NETBIRD_SETUP_KEY        Required when NETBIRD_CLIENT_ENABLED=true
  NETBIRD_CLIENT_HOSTNAME  Client container hostname (default: netbird-peer)
  NETBIRD_LOG_LEVEL        Server log level (default: info)
  WAIT_TIMEOUT             Max seconds to wait for the stack to come up and
                           become healthy after 'docker compose up -d'
                           (default: 180)

${BOLD}Re-run policy${RESET} (converge by default): re-running an existing stack
converges it — the generated files are left unchanged, images are pulled, and
'docker compose up -d' reconciles only what changed (no tear-down, no silent
skip). See specification/project/conventions.md.
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

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"
run_preflight_checks
success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

if docker compose version &>/dev/null; then
  COMPOSE_SHORT="$(docker compose version --short 2>/dev/null || true)"
  success "Docker Compose ${COMPOSE_SHORT} detected."
  if [[ "$COMPOSE_SHORT" != 2.* && "$COMPOSE_SHORT" != v2.* ]]; then
    warn "Docker Compose version '${COMPOSE_SHORT}' looks older than v2 — the stack requires Compose v2."
  fi
else
  warn "Docker Compose v2 (docker compose) not detected — the stack cannot start without it."
fi

if [[ -z "$NETBIRD_DOMAIN" ]]; then
  error "NETBIRD_DOMAIN must be set (NetBird is always routed through Traefik)."
fi

if [[ "$NETBIRD_CLIENT_ENABLED" == "true" ]]; then
  if [[ -z "$NETBIRD_SETUP_KEY" ]]; then
    error "NETBIRD_SETUP_KEY must be set when NETBIRD_CLIENT_ENABLED=true."
  fi
fi

# Traefik is a prerequisite: install it via setup-traefik.sh when it is not set up.
if docker ps --format '{{.Names}}' | grep -qx 'traefik' \
  && docker network ls --format '{{.Name}}' | grep -qx "${PROXY_NETWORK}"; then
  success "Traefik container is running and Docker network '${PROXY_NETWORK}' exists."
else
  warn "Traefik is not set up (no running 'traefik' container or no '${PROXY_NETWORK}' network) — installing it first via setup-traefik.sh."
  PROXY_NETWORK="$PROXY_NETWORK" bash "${SCRIPT_DIR}/setup-traefik.sh" \
    || error "Traefik prerequisite setup failed — fix the error above (first install needs ACME_EMAIL=<your email>) and re-run."
  ensure_traefik_running
  ensure_proxy_network
fi

# ─────────────────────────────────────────────────────────────────────────────
# COMPUTE DERIVED VALUES
# ─────────────────────────────────────────────────────────────────────────────

NETBIRD_MGMT_URL="https://${NETBIRD_DOMAIN}"
NETBIRD_ISSUER="${NETBIRD_MGMT_URL}/oauth2"
NETBIRD_DASHBOARD_REDIRECT="${NETBIRD_MGMT_URL}/nb-auth"
NETBIRD_SILENT_REDIRECT="${NETBIRD_MGMT_URL}/nb-silent-auth"

NETBIRD_OWNER_BLOCK=""
if [[ -n "$NETBIRD_ADMIN_EMAIL" && -n "$NETBIRD_ADMIN_PASSWORD" ]]; then
  NETBIRD_OWNER_BLOCK="$(printf '    owner:\n      email: "%s"\n      password: "%s"' \
    "$NETBIRD_ADMIN_EMAIL" "$NETBIRD_ADMIN_PASSWORD")"
  info "Bootstrap owner '${NETBIRD_ADMIN_EMAIL}' will be configured in config.yaml (first render only)."
fi
export NETBIRD_MGMT_URL NETBIRD_ISSUER NETBIRD_DASHBOARD_REDIRECT NETBIRD_SILENT_REDIRECT
export NETBIRD_OWNER_BLOCK

# ─────────────────────────────────────────────────────────────────────────────
# CREATE PERSISTENT DIRECTORY
# ─────────────────────────────────────────────────────────────────────────────

step "Creating persistent directory under ${NETBIRD_HOME}"
sudo mkdir -p "${NETBIRD_HOME}"
sudo chown -R "$(id -un):$(id -gn)" "${NETBIRD_HOME}"
success "Directory ready: ${NETBIRD_HOME}"

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE .env (create once — never overwritten)
# ─────────────────────────────────────────────────────────────────────────────

step "Generating environment file"

ENV_FILE="${NETBIRD_HOME}/.env"

if [[ -f "$ENV_FILE" ]]; then
  info "Existing .env found at ${ENV_FILE} — leaving it unchanged."
else
  NETBIRD_AUTH_SECRET="$(openssl rand -hex 32)"
  NETBIRD_STORE_ENCRYPTION_KEY="$(openssl rand -base64 32)"

  ENV_TMP="$(mktemp)"
  cat > "$ENV_TMP" <<EOF
# Auto-generated by tasks/setup-netbird.sh on $(date '+%Y-%m-%d %H:%M:%S') — do not commit
NETBIRD_AUTH_SECRET=${NETBIRD_AUTH_SECRET}
NETBIRD_STORE_ENCRYPTION_KEY=${NETBIRD_STORE_ENCRYPTION_KEY}
NETBIRD_SERVER_IMAGE=${NETBIRD_SERVER_IMAGE}
NETBIRD_SERVER_TAG=${NETBIRD_SERVER_TAG}
NETBIRD_DASHBOARD_IMAGE=${NETBIRD_DASHBOARD_IMAGE}
NETBIRD_DASHBOARD_TAG=${NETBIRD_DASHBOARD_TAG}
NETBIRD_CLIENT_IMAGE=${NETBIRD_CLIENT_IMAGE}
NETBIRD_CLIENT_TAG=${NETBIRD_CLIENT_TAG}
NETBIRD_MGMT_URL=${NETBIRD_MGMT_URL}
NETBIRD_ISSUER=${NETBIRD_ISSUER}
NETBIRD_DOMAIN=${NETBIRD_DOMAIN}
STUN_PORT=${STUN_PORT}
PROXY_NETWORK=${PROXY_NETWORK}
NETBIRD_SETUP_KEY=${NETBIRD_SETUP_KEY}
NETBIRD_CLIENT_HOSTNAME=${NETBIRD_CLIENT_HOSTNAME}
EOF
  cp "$ENV_TMP" "$ENV_FILE" 2>/dev/null || sudo cp "$ENV_TMP" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || sudo chmod 600 "$ENV_FILE"
  rm -f "$ENV_TMP"
  success ".env created at ${ENV_FILE} (mode 600, secrets generated once)."
fi

# Reload the persisted secrets — .env is authoritative (created once).
# Export everything used by the config template (envsubst only sees exported vars).
NETBIRD_AUTH_SECRET="$(grep -E '^NETBIRD_AUTH_SECRET=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2-)" \
  || error "Could not read NETBIRD_AUTH_SECRET from ${ENV_FILE} (permissions?)"
NETBIRD_STORE_ENCRYPTION_KEY="$(grep -E '^NETBIRD_STORE_ENCRYPTION_KEY=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2-)" \
  || error "Could not read NETBIRD_STORE_ENCRYPTION_KEY from ${ENV_FILE} (permissions?)"
[[ -n "$NETBIRD_AUTH_SECRET" ]] || error "NETBIRD_AUTH_SECRET is missing or empty in ${ENV_FILE}"
[[ -n "$NETBIRD_STORE_ENCRYPTION_KEY" ]] || error "NETBIRD_STORE_ENCRYPTION_KEY is missing or empty in ${ENV_FILE}"
export NETBIRD_AUTH_SECRET NETBIRD_STORE_ENCRYPTION_KEY STUN_PORT NETBIRD_LOG_LEVEL

# Warn on drift: compose resolves ${...} from the process env (precedence over
# .env), so a re-run with changed values would partially update the frozen stack.
PERSISTED_MGMT_URL="$(grep -E '^NETBIRD_MGMT_URL=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2- || true)"
PERSISTED_STUN_PORT="$(grep -E '^STUN_PORT=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2- || true)"
if [[ -n "$PERSISTED_MGMT_URL" && "$PERSISTED_MGMT_URL" != "$NETBIRD_MGMT_URL" ]]; then
  warn "NETBIRD_MGMT_URL is '${NETBIRD_MGMT_URL}' but the frozen .env/config.yaml use '${PERSISTED_MGMT_URL}' — issuer/redirects may desync. Delete ${ENV_FILE} and ${NETBIRD_HOME}/config.yaml and re-run to fully re-apply the new values."
fi
if [[ -n "$PERSISTED_STUN_PORT" && "$PERSISTED_STUN_PORT" != "$STUN_PORT" ]]; then
  warn "STUN_PORT is '${STUN_PORT}' but the frozen .env/config.yaml use '${PERSISTED_STUN_PORT}' — delete ${ENV_FILE} and ${NETBIRD_HOME}/config.yaml and re-run to fully re-apply the new values."
fi

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE DOCKER COMPOSE FILE FROM TEMPLATE
# ─────────────────────────────────────────────────────────────────────────────

step "Generating ${NETBIRD_HOME}/docker-compose.yml"

COMPOSE_FILE="${NETBIRD_HOME}/docker-compose.yml"

if [[ -f "$COMPOSE_FILE" ]]; then
  info "Existing docker-compose.yml found at ${COMPOSE_FILE} — leaving it unchanged."
  warn "To re-apply the template: delete ${COMPOSE_FILE} and re-run this script."
else
  COMPOSE_TEMPLATE="${SCRIPT_DIR}/../templates/netbird/docker-compose.traefik.yml"
  [[ -f "$COMPOSE_TEMPLATE" ]] || error "Compose template not found at ${COMPOSE_TEMPLATE}"
  cp "$COMPOSE_TEMPLATE" "$COMPOSE_FILE" 2>/dev/null || sudo cp "$COMPOSE_TEMPLATE" "$COMPOSE_FILE"
  success "docker-compose.yml written to ${COMPOSE_FILE}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# RENDER config.yaml (only if missing — manual edits are preserved)
# ─────────────────────────────────────────────────────────────────────────────

step "Rendering ${NETBIRD_HOME}/config.yaml"

CONFIG_FILE="${NETBIRD_HOME}/config.yaml"

if [[ -f "$CONFIG_FILE" ]]; then
  info "Existing config.yaml found — preserving it (manual edits kept)."
else
  CONFIG_TEMPLATE="${SCRIPT_DIR}/../templates/netbird/config.yaml.template"
  [[ -f "$CONFIG_TEMPLATE" ]] || error "Config template not found at ${CONFIG_TEMPLATE}"
  CONFIG_TMP="$(mktemp)"
  # shellcheck disable=SC2016  # envsubst variable list must not be expanded by bash
  envsubst '${NETBIRD_MGMT_URL} ${STUN_PORT} ${NETBIRD_LOG_LEVEL} ${NETBIRD_AUTH_SECRET} ${NETBIRD_ISSUER} ${NETBIRD_DASHBOARD_REDIRECT} ${NETBIRD_SILENT_REDIRECT} ${NETBIRD_OWNER_BLOCK} ${NETBIRD_STORE_ENCRYPTION_KEY}' \
    < "$CONFIG_TEMPLATE" > "$CONFIG_TMP"
  cp "$CONFIG_TMP" "$CONFIG_FILE" 2>/dev/null || sudo cp "$CONFIG_TMP" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || sudo chmod 600 "$CONFIG_FILE"
  rm -f "$CONFIG_TMP"
  success "config.yaml rendered at ${CONFIG_FILE} (mode 600)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# PULL IMAGES
# ─────────────────────────────────────────────────────────────────────────────

step "Pulling Docker images"
docker compose -f "$COMPOSE_FILE" pull
success "Images pulled."

# ─────────────────────────────────────────────────────────────────────────────
# START THE STACK
# ─────────────────────────────────────────────────────────────────────────────

step "Starting NetBird stack (detached)"
docker compose -f "$COMPOSE_FILE" up -d

# Health gate: prove the containers are actually up before reporting success.
mapfile -t _ids < <(docker compose -f "$COMPOSE_FILE" ps -q)
wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
  || error "NetBird stack did not come up — see the status output above"

# Optional routing-peer client
if [[ "$NETBIRD_CLIENT_ENABLED" == "true" ]]; then
  step "Starting netbird-client routing peer"
  echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-netbird.conf > /dev/null
  sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
  docker compose -f "$COMPOSE_FILE" --profile client up -d netbird-client
  # Health gate for the client (the project-wide list now includes it).
  mapfile -t _ids < <(docker compose -f "$COMPOSE_FILE" --profile client ps -q)
  wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
    || error "netbird-client did not come up — see the status output above"
fi

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL (UFW)
# ─────────────────────────────────────────────────────────────────────────────

ufw_firewall_section "NetBird" "${STUN_PORT}" udp "NetBird STUN"

# ─────────────────────────────────────────────────────────────────────────────
# WAIT FOR READY
# ─────────────────────────────────────────────────────────────────────────────

step "Verifying NetBird is reachable via Traefik (best effort)"
TRAEFIK_OK=false
for _attempt in 1 2 3 4 5; do
  if curl -fsSk "https://${NETBIRD_DOMAIN}/oauth2/.well-known/openid-configuration" > /dev/null 2>&1; then
    TRAEFIK_OK=true
    break
  fi
  sleep 5
done
if [[ "$TRAEFIK_OK" == "true" ]]; then
  success "NetBird is reachable at https://${NETBIRD_DOMAIN}."
else
  warn "Could not reach https://${NETBIRD_DOMAIN}/oauth2/.well-known/openid-configuration"
  warn "Verify DNS and Let's Encrypt certificate (it may still be provisioning)."
  warn "Check logs with: docker compose -f ${COMPOSE_FILE} logs -f"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  NetBird setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
DASHBOARD_URL="https://${NETBIRD_DOMAIN}"
echo -e "  ${BOLD}Dashboard${RESET}        ${DASHBOARD_URL}"
echo -e "  ${BOLD}Management URL${RESET}   ${NETBIRD_MGMT_URL}"
echo -e "  ${BOLD}STUN${RESET}             udp/${STUN_PORT} (published on the host)"
echo -e "  ${BOLD}Data directory${RESET}   ${NETBIRD_HOME}"
echo -e "  ${BOLD}Compose file${RESET}     ${COMPOSE_FILE}"
echo -e "  ${BOLD}Environment file${RESET} ${ENV_FILE}"
echo ""
echo -e "${YELLOW}  First-time steps:${RESET}"
if [[ -n "$NETBIRD_ADMIN_EMAIL" && -n "$NETBIRD_ADMIN_PASSWORD" ]]; then
  echo -e "  1. Log in to the dashboard with the bootstrap owner (${NETBIRD_ADMIN_EMAIL})."
else
  echo -e "  1. Open ${DASHBOARD_URL}/setup and create the owner account"
  echo -e "     (the /setup page is only live until the first account exists)."
fi
echo -e "  2. Create a setup key (Settings → Setup Keys)."
echo -e "  3. Join clients: netbird up --setup-key <KEY>  (or set management URL ${NETBIRD_MGMT_URL} in the app)."
echo -e "  4. Routing peer: re-run with NETBIRD_DOMAIN=${NETBIRD_DOMAIN} NETBIRD_CLIENT_ENABLED=true NETBIRD_SETUP_KEY=<KEY>"
echo -e "     and configure the LAN Network/route in the dashboard."
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Follow logs    :  docker compose -f ${COMPOSE_FILE} logs -f"
echo -e "  Stop stack     :  docker compose -f ${COMPOSE_FILE} down"
echo -e "  Start stack    :  docker compose -f ${COMPOSE_FILE} up -d"
echo -e "  Restart stack  :  docker compose -f ${COMPOSE_FILE} restart"
echo -e "  Backup state   :  back up the netbird-data volume + ${CONFIG_FILE} + ${ENV_FILE}"
echo ""
