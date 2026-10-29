#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-monitoring.sh — Deploy Monitoring Stack (Prometheus + Grafana + Node Exporter + cAdvisor)
# =============================================================================
#
# DESCRIPTION:
#   Deploys a containerized observability stack comprising Prometheus, Grafana,
#   and Node Exporter via Docker Compose. Prometheus scrapes itself and uses
#   Docker service discovery (docker_sd_configs) to automatically scrape
#   containers carrying the `prometheus.scrape=true` label. Lifecycle API is
#   enabled so the config can be hot-reloaded without a restart. cAdvisor
#   provides per-container CPU/memory/disk/network metrics. Grafana is
#   pre-provisioned with a Node Exporter and a cAdvisor dashboard (no manual
#   import).
#
#   Exposure modes:
#     - direct (default): Grafana published on GRAFANA_BIND_ADDRESS
#       (default: 0.0.0.0 = reachable from the local network) and the
#       Prometheus UI on PROMETHEUS_BIND_ADDRESS (default: 127.0.0.1 =
#       loopback only, since the Prometheus UI has no authentication)
#     - Traefik (GRAFANA_TRAEFIK=true): Grafana routed via the shared proxy
#       network at https://GRAFANA_DOMAIN; Prometheus stays internal
#
# KEY ACTIONS:
#   1. Pre-flight: Docker + daemon, Compose v2, free host ports (direct mode)
#      or GRAFANA_DOMAIN + proxy network (Traefik mode)
#   2. Idempotent re-run handling (never `down -v`, data preserved)
#   3. Create data directories with correct UID/GID ownership (guarded)
#   4. Generate/reuse Grafana admin credentials in a mode-600 .env
#   5. Render templates (envsubst) into /srv/monitoring/{prometheus,grafana}
#   6. Pull images and start the stack (detached)
#   7. Health-check Prometheus and Grafana with a bounded timeout
#   8. Add a UFW allow rule for the Grafana port (direct mode only)
#   9. Summary with access URL, credentials location, management commands
#
# IMPORTANT VARIABLES:
#   MONITORING_HOME          - Base data directory (default: /srv)
#   MONITORING_DOCKER_NETWORK- Internal monitoring network (default: monitoring-net)
#   PROXY_NETWORK            - Traefik external network (default: proxy)
#   GRAFANA_TRAEFIK          - Set to "true" to route Grafana via Traefik (default: false)
#   GRAFANA_PORT             - Host port for Grafana in direct mode (default: 3100)
#   PROMETHEUS_PORT          - Host port for Prometheus UI in direct mode (default: 9090)
#   GRAFANA_BIND_ADDRESS     - Interface to publish the Grafana port on (direct mode,
#                              default: 0.0.0.0 = LAN access)
#   PROMETHEUS_BIND_ADDRESS  - Interface to publish the Prometheus UI port on (direct mode,
#                              default: 127.0.0.1 = loopback only; the UI has no authentication)
#   GRAFANA_DOMAIN           - Domain for Traefik routing (required when GRAFANA_TRAEFIK=true)
#   GRAFANA_ADMIN_USER       - Grafana admin username (default: admin)
#   GRAFANA_ADMIN_PASSWORD   - Auto-generated via openssl rand if unset
#   PROMETHEUS_IMAGE_VERSION - Prometheus image (default: versions.yml, key prometheus)
#   GRAFANA_IMAGE_VERSION    - Grafana image (default: versions.yml, key grafana)
#   NODE_EXPORTER_IMAGE_VERSION - Node Exporter image (default: versions.yml, key node-exporter)
#   CADVISOR_IMAGE_VERSION     - cAdvisor image (default: versions.yml, key cadvisor)
#   MONITORING_FORCE         - Set to "true" to re-create an existing stack
#
# FIREWALL:
#   In direct mode, a UFW allow rule is added for GRAFANA_PORT only (idempotent
#   via lib/helpers.sh ufw_add_rule). No rule is added for PROMETHEUS_PORT;
#   if you publish the unauthenticated Prometheus UI beyond loopback, restrict
#   it manually (e.g. 'ufw allow from <subnet> to any port 9090 proto tcp').
#   In Traefik mode no direct ports are published, so no rules are added.
#
# DEPENDENCIES:
#   - Docker + daemon, Docker Compose v2+, openssl, curl, envsubst (gettext)
#   - Traefik stack with the shared proxy network (setup-traefik.sh)
#
# OUTPUTS:
#   - ${MONITORING_HOME}/monitoring/prometheus/{config,data}  - Prometheus config + TSDB
#   - ${MONITORING_HOME}/monitoring/grafana/{data,provisioning,dashboards} - Grafana state + provisioning
#   - ${MONITORING_HOME}/monitoring/docker-compose.yml - Generated compose config
#   - ${MONITORING_HOME}/monitoring/grafana/.env - Grafana admin credentials (mode 600)
#
# USAGE:
#   ./tasks/setup-monitoring.sh   # direct mode (default): Grafana on 0.0.0.0, Prometheus on 127.0.0.1
#   GRAFANA_TRAEFIK=true GRAFANA_DOMAIN=grafana.example.com ./tasks/setup-monitoring.sh
#   ./tasks/setup-monitoring.sh --help
#
# =============================================================================

set -euo pipefail

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
  if [[ -f "${COMPOSE_FILE:-}" ]] && docker compose -f "$COMPOSE_FILE" ps &>/dev/null; then
    if [[ -n "$(docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null || true)" ]]; then
      docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
      info "Removed partially created stack."
    else
      info "Stack from this run is already stopped — data in ${PROMETHEUS_HOME} and ${GRAFANA_HOME} is preserved."
    fi
  fi
}

trap cleanup_on_failure EXIT

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — defaults; override via environment variables
# ─────────────────────────────────────────────────────────────────────────────

MONITORING_HOME="${MONITORING_HOME:-/srv}"
MONITORING_DOCKER_NETWORK="${MONITORING_DOCKER_NETWORK:-monitoring-net}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
GRAFANA_TRAEFIK="${GRAFANA_TRAEFIK:-false}"
GRAFANA_PORT="${GRAFANA_PORT:-3100}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_BIND_ADDRESS="${GRAFANA_BIND_ADDRESS:-0.0.0.0}"
PROMETHEUS_BIND_ADDRESS="${PROMETHEUS_BIND_ADDRESS:-127.0.0.1}"
GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
MONITORING_FORCE="${MONITORING_FORCE:-false}"

MONITORING_COMPOSE_DIR="${MONITORING_HOME}/monitoring"
PROMETHEUS_HOME="${MONITORING_COMPOSE_DIR}/prometheus"
GRAFANA_HOME="${MONITORING_COMPOSE_DIR}/grafana"
COMPOSE_FILE="${MONITORING_COMPOSE_DIR}/docker-compose.yml"
GRAFANA_ENV_FILE="${GRAFANA_HOME}/.env"

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE SHARED LIBRARY + LOCATE TEMPLATES
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# Version defaults: versions.yml, read with kw_* (lib/helpers.sh)
PROMETHEUS_IMAGE_VERSION="${PROMETHEUS_IMAGE_VERSION:-$(kw_image prometheus)}"
GRAFANA_IMAGE_VERSION="${GRAFANA_IMAGE_VERSION:-$(kw_image grafana)}"
NODE_EXPORTER_IMAGE_VERSION="${NODE_EXPORTER_IMAGE_VERSION:-$(kw_image node-exporter)}"
CADVISOR_IMAGE_VERSION="${CADVISOR_IMAGE_VERSION:-$(kw_image cadvisor)}"

TEMPLATES_DIR="$(realpath "${SCRIPT_DIR}/../templates/monitoring")"

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Deploys a containerized monitoring stack (Prometheus + Grafana + Node
Exporter + cAdvisor) via Docker Compose. Prometheus auto-discovers containers
labeled prometheus.scrape=true. Grafana is pre-provisioned with Node Exporter
and cAdvisor dashboards. Re-runs are idempotent (data is never wiped).

${BOLD}Options:${RESET}
  --interactive   Offer tear-down/re-create of an existing stack (default:
                  converge); MONITORING_FORCE=true still re-creates
  -h, --help      Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  MONITORING_HOME            Base data directory (default: /srv)
  MONITORING_DOCKER_NETWORK  Internal monitoring network (default: monitoring-net)
  PROXY_NETWORK              Traefik external network (default: proxy)
  GRAFANA_TRAEFIK            Set to "true" to route Grafana via Traefik (default: false)
  GRAFANA_PORT               Grafana host port in direct mode (default: 3100)
  PROMETHEUS_PORT            Prometheus UI host port in direct mode (default: 9090)
  GRAFANA_BIND_ADDRESS       Grafana publish interface, direct mode (default: 0.0.0.0)
  PROMETHEUS_BIND_ADDRESS    Prometheus UI publish interface, direct mode (default: 127.0.0.1)
  GRAFANA_DOMAIN             Domain for Traefik routing (required when GRAFANA_TRAEFIK=true)
  GRAFANA_ADMIN_USER         Grafana admin username (default: admin)
  GRAFANA_ADMIN_PASSWORD     Grafana admin password (auto-generated if unset)
  PROMETHEUS_IMAGE_VERSION   Prometheus image tag (default: $(kw_image prometheus))
  GRAFANA_IMAGE_VERSION      Grafana image tag (default: $(kw_image grafana))
  NODE_EXPORTER_IMAGE_VERSION  Node Exporter image tag (default: $(kw_image node-exporter))
  CADVISOR_IMAGE_VERSION     cAdvisor image tag (default: $(kw_image cadvisor))
  MONITORING_FORCE           Set to "true" to re-create an existing stack (default: false)
  WAIT_TIMEOUT               Max seconds to wait for the stack to come up and
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
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# container_healthy <name> <port> <path>
#   Returns 0 if the container's HTTP endpoint returns 200 (via its network IP).
container_healthy() {
  local cname="$1"
  local port="$2"
  local path="$3"
  local ip
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cname" 2>/dev/null | awk '{print $1}')"
  [[ -z "$ip" ]] && return 1
  curl -sf --connect-timeout 3 --max-time 5 "http://${ip}:${port}${path}" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

run_preflight_checks

if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Install gettext-base (e.g. apt-get install gettext-base)."
fi

COMPOSE_VERSION="$(docker compose version --short 2>/dev/null || echo "0.0.0")"
COMPOSE_MAJOR="$(echo "$COMPOSE_VERSION" | cut -d'.' -f1)"
if [[ "$COMPOSE_MAJOR" -lt 2 ]]; then
  error "Docker Compose v2+ is required (found ${COMPOSE_VERSION}). Run setup-docker.sh to install docker-compose-plugin."
fi
success "Docker Compose ${COMPOSE_VERSION} detected."

if [[ "$GRAFANA_TRAEFIK" == "true" ]]; then
  if [[ -z "$GRAFANA_DOMAIN" ]]; then
    error "GRAFANA_DOMAIN must be set when GRAFANA_TRAEFIK=true (e.g. grafana.example.com)."
  fi
  success "Grafana will be exposed at https://${GRAFANA_DOMAIN}"

  ensure_proxy_network

  if ! docker ps --format '{{.Names}}' | grep -qx 'traefik' 2>/dev/null; then
    warn "Traefik container is not running. Grafana will not be reachable until Traefik is started."
  fi
else
  # Direct mode: the host port conflict check runs AFTER the idempotency
  # section below — a re-create (MONITORING_FORCE / --interactive) must first
  # tear down the existing stack that still holds the ports.
  success "Grafana will be exposed at http://${GRAFANA_BIND_ADDRESS}:${GRAFANA_PORT}"
  success "Prometheus UI will be exposed at http://${PROMETHEUS_BIND_ADDRESS}:${PROMETHEUS_PORT}"
  if [[ "$PROMETHEUS_BIND_ADDRESS" != "127.0.0.1" && "$PROMETHEUS_BIND_ADDRESS" != "localhost" ]]; then
    warn "The Prometheus UI is published beyond loopback and has NO authentication —"
    warn "restrict access with UFW (e.g. 'ufw allow from <subnet> to any port ${PROMETHEUS_PORT} proto tcp')."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# DOCKER SOCKET ACCESS — Prometheus runs as UID 65534 (nobody)
# ─────────────────────────────────────────────────────────────────────────────

step "Checking Docker socket access for Prometheus"

SOCKET_PATH="/var/run/docker.sock"
DOCKER_GROUP_GID=""
if command -v getent &>/dev/null; then
  DOCKER_GROUP_GID="$(getent group docker | cut -d: -f3)"
fi

SOCKET_MODE="$(stat -c '%a' "$SOCKET_PATH" 2>/dev/null || stat -f '%Lp' "$SOCKET_PATH" 2>/dev/null || echo "unknown")"
info "Docker socket at ${SOCKET_PATH} (mode ${SOCKET_MODE})."

if [[ -n "$DOCKER_GROUP_GID" ]]; then
  DOCKER_GROUP_GID_LIST="[\"${DOCKER_GROUP_GID}\"]"
  success "Prometheus will join the docker group (GID ${DOCKER_GROUP_GID}) for socket access."
else
  DOCKER_GROUP_GID_LIST="[]"
  warn "Could not detect the docker group GID. Prometheus may fail to query Docker service discovery."
  warn "Ensure /var/run/docker.sock is readable by UID 65534, or set the docker group GID."
fi
export DOCKER_GROUP_GID_LIST

# ─────────────────────────────────────────────────────────────────────────────
# IDEMPOTENCY — handle an existing compose stack
# ─────────────────────────────────────────────────────────────────────────────

if [[ -f "$COMPOSE_FILE" ]]; then
  warn "Existing compose file found at ${COMPOSE_FILE}."
  recreate=false

  if [[ "${MONITORING_FORCE}" == "true" ]]; then
    # MONITORING_FORCE is the non-interactive re-create escape hatch — it wins
    # over INTERACTIVE (re-run policy, ticket 12).
    info "MONITORING_FORCE=true — re-creating the stack (data preserved)."
    recreate=true
  elif [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Stack exists. Converge (default) or tear down and re-create? [c/N] " _answer
    if [[ "${_answer,,}" == "y" ]]; then
      recreate=true
    fi
  fi

  if [[ "$recreate" == "true" ]]; then
    info "Stopping the existing stack (data preserved)."
    # The operator explicitly accepted the re-create (MONITORING_FORCE or the
    # interactive confirm above): the cleanup trap must cover this re-create,
    # so a failure before 'up -d' or a half-created re-create is still cleaned
    # up — and the trap must not claim "nothing torn down".
    STACK_CREATED_THIS_RUN=1
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
  else
    # Re-run policy (ticket 12): CONVERGE — the config is re-rendered below
    # and 'docker compose up -d' reconciles only what changed (data preserved).
    info "Re-running will converge the existing stack (no tear-down; data preserved)."
  fi
fi

if [[ "$GRAFANA_TRAEFIK" != "true" ]]; then
  # Direct mode: verify the host ports to be published (loopback) are free —
  # now that any existing monitoring stack has been torn down (re-create path).
  # Ports already published by the running monitoring stack are fine: a
  # converge re-run must not fail on the stack's own listeners.
  local_listening_ports="$(ss -tln 2>/dev/null | awk 'NR > 1 {print $4}' | sed 's/.*[:.]//')"
  for port in "$GRAFANA_PORT" "$PROMETHEUS_PORT"; do
    if grep -qx "$port" <<< "$local_listening_ports"; then
      if docker compose -f "$COMPOSE_FILE" ps --format '{{.Ports}}' 2>/dev/null | grep -Eq "[:.]${port}->"; then
        continue
      fi
      error "Port ${port} is already in use. Choose a different GRAFANA_PORT/PROMETHEUS_PORT."
    fi
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# CREATE PERSISTENT DIRECTORIES + OWNERSHIP (guarded, never recursive chown)
# ─────────────────────────────────────────────────────────────────────────────

step "Creating persistent directories under ${MONITORING_HOME}"

# Prometheus data + config owned by UID/GID 65534 (nobody)
sudo install -d -o 65534 -g 65534 "${PROMETHEUS_HOME}/data" "${PROMETHEUS_HOME}/config"

# Grafana data, provisioning (datasources + dashboards providers), dashboards.
# The grafana image runs as UID/GID 472; chown with numeric ids on purpose —
# no host user 472 exists on a fresh system, and 'install -o 472' rejects
# unknown ids. After the first container run the ownership is already
# 472:472, so this is a no-op on re-runs.
sudo mkdir -p \
  "${GRAFANA_HOME}/data" \
  "${GRAFANA_HOME}/provisioning/datasources" \
  "${GRAFANA_HOME}/provisioning/dashboards" \
  "${GRAFANA_HOME}/dashboards"
sudo chown -R 472:472 \
  "${GRAFANA_HOME}/data" \
  "${GRAFANA_HOME}/provisioning" \
  "${GRAFANA_HOME}/dashboards"

sudo mkdir -p "${MONITORING_COMPOSE_DIR}"

success "Directories ready."

# ─────────────────────────────────────────────────────────────────────────────
# GRAFANA ADMIN CREDENTIALS — generate or reuse (idempotent)
# ─────────────────────────────────────────────────────────────────────────────

step "Ensuring Grafana admin credentials"

if [[ -f "$GRAFANA_ENV_FILE" ]]; then
  info "Existing ${GRAFANA_ENV_FILE} found — reusing stored admin credentials."
  GRAFANA_ADMIN_USER="$(grep '^GF_SECURITY_ADMIN_USER=' "$GRAFANA_ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
  GRAFANA_ADMIN_PASSWORD="$(grep '^GF_SECURITY_ADMIN_PASSWORD=' "$GRAFANA_ENV_FILE" | head -n1 | cut -d= -f2- || true)"
else
  if [[ -z "$GRAFANA_ADMIN_PASSWORD" ]]; then
    GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    success "Generated a new random Grafana admin password."
  else
    info "Using GRAFANA_ADMIN_PASSWORD from the environment."
  fi

  tmp_env="$(mktemp)"
  cat > "$tmp_env" <<EOF
# Grafana admin credentials — generated by tasks/setup-monitoring.sh
# Keep this file secure (mode 600).
GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER}
GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
EOF
  sudo mv "$tmp_env" "$GRAFANA_ENV_FILE"
  sudo chmod 600 "$GRAFANA_ENV_FILE"
  success "Credentials stored in ${GRAFANA_ENV_FILE} (mode 600)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# RENDER TEMPLATES (envsubst)
# ─────────────────────────────────────────────────────────────────────────────

step "Rendering configuration templates"

# Select compose template based on exposure mode (direct vs Traefik)
if [[ "$GRAFANA_TRAEFIK" == "true" ]]; then
  COMPOSE_TEMPLATE="${TEMPLATES_DIR}/docker-compose-traefik.yml"
else
  COMPOSE_TEMPLATE="${TEMPLATES_DIR}/docker-compose-direct.yml"
fi

export MONITORING_HOME
export PROMETHEUS_HOME
export GRAFANA_HOME
export MONITORING_DOCKER_NETWORK
export PROXY_NETWORK
export GRAFANA_DOMAIN
export GRAFANA_PORT
export PROMETHEUS_PORT
export GRAFANA_BIND_ADDRESS
export PROMETHEUS_BIND_ADDRESS
export GRAFANA_ENV_FILE
export PROMETHEUS_IMAGE_VERSION
export GRAFANA_IMAGE_VERSION
export NODE_EXPORTER_IMAGE_VERSION
export CADVISOR_IMAGE_VERSION

# Prometheus config
# Note: mktemp files are mode 600 — normalize to 644 before moving, since the
# prometheus container (UID 65534) must be able to read the mounted config.
tmp_prom="$(mktemp)"
envsubst < "${TEMPLATES_DIR}/prometheus.yml" > "$tmp_prom"
chmod 644 "$tmp_prom"
sudo mv "$tmp_prom" "${PROMETHEUS_HOME}/config/prometheus.yml"

# Grafana datasource + dashboard provider (no substitution needed — copy)
sudo cp "${TEMPLATES_DIR}/grafana-datasource.yml" "${GRAFANA_HOME}/provisioning/datasources/datasources.yml"
sudo cp "${TEMPLATES_DIR}/grafana-provisioning.yml" "${GRAFANA_HOME}/provisioning/dashboards/dashboards.yml"
sudo cp "${TEMPLATES_DIR}/grafana-dashboard.json" "${GRAFANA_HOME}/dashboards/node-exporter-host.json"
sudo cp "${TEMPLATES_DIR}/grafana-cadvisor.json" "${GRAFANA_HOME}/dashboards/cadvisor-container-insights.json"

# Docker Compose (mode 644 — see note above; no secrets in this file, admin
# credentials live in the mode-600 ${GRAFANA_ENV_FILE})
tmp_compose="$(mktemp)"
envsubst < "$COMPOSE_TEMPLATE" > "$tmp_compose"
chmod 644 "$tmp_compose"
sudo mv "$tmp_compose" "$COMPOSE_FILE"

success "Templates rendered into ${MONITORING_HOME}."

# ─────────────────────────────────────────────────────────────────────────────
# PULL IMAGES
# ─────────────────────────────────────────────────────────────────────────────

step "Pulling Docker images"
docker compose -f "$COMPOSE_FILE" pull
success "Images pulled."

# ─────────────────────────────────────────────────────────────────────────────
# START THE STACK
# ─────────────────────────────────────────────────────────────────────────────

step "Starting monitoring stack (detached)"
STACK_CREATED_THIS_RUN=1
docker compose -f "$COMPOSE_FILE" up -d

# Health gate: prove the containers are actually up before reporting success.
mapfile -t _ids < <(docker compose -f "$COMPOSE_FILE" ps -q)
wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
  || error "Monitoring stack did not come up — see the status output above"
STACK_CREATED_THIS_RUN=0     # proven healthy -> a later failure must not tear it down

# ─────────────────────────────────────────────────────────────────────────────
# HEALTH CHECK
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for Prometheus and Grafana to become healthy"

MAX_WAIT=120
INTERVAL=5
ELAPSED=0
PROM_READY=false
GRAFANA_READY=false

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  if [[ "$PROM_READY" == "false" ]] && container_healthy prometheus 9090 "/-/healthy"; then
    PROM_READY=true
    success "Prometheus is healthy."
  fi
  if [[ "$GRAFANA_READY" == "false" ]] && container_healthy grafana 3000 "/api/health"; then
    GRAFANA_READY=true
    success "Grafana is healthy."
  fi
  if [[ "$PROM_READY" == "true" && "$GRAFANA_READY" == "true" ]]; then
    break
  fi
  echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s ..."
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo ""

if [[ "$PROM_READY" == "true" && "$GRAFANA_READY" == "true" ]]; then
  success "Monitoring stack is up and responding!"
else
  warn "One or more services did not respond within ${MAX_WAIT}s."
  warn "They may still be starting. Check logs with:"
  warn "  docker compose -f ${COMPOSE_FILE} logs -f"
fi

# ─────────────────────────────────────────────────────────────────────────────
# UFW RULES (direct mode only — ports published on the host)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$GRAFANA_TRAEFIK" != "true" ]]; then
  ufw_add_rule "$GRAFANA_PORT" tcp "Grafana"
  info "No UFW rule added for Prometheus (port ${PROMETHEUS_PORT}). If you expose"
  info "the unauthenticated Prometheus UI beyond loopback, restrict it manually"
  info "(e.g. 'ufw allow from <subnet> to any port ${PROMETHEUS_PORT} proto tcp')."
fi

# Disable cleanup trap on successful completion
trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Monitoring setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
if [[ "$GRAFANA_TRAEFIK" == "true" ]]; then
  echo -e "  ${BOLD}Grafana${RESET}            https://${GRAFANA_DOMAIN}"
  echo -e "  ${BOLD}Prometheus (internal)${RESET}  http://prometheus:9090"
else
  echo -e "  ${BOLD}Grafana${RESET}            http://${GRAFANA_BIND_ADDRESS}:${GRAFANA_PORT}"
  echo -e "  ${BOLD}Prometheus${RESET}         http://${PROMETHEUS_BIND_ADDRESS}:${PROMETHEUS_PORT}"
fi
echo -e "  ${BOLD}Admin credentials${RESET}  ${GRAFANA_ENV_FILE} (mode 600)"
echo -e "  ${BOLD}Node Exporter (internal)${RESET}  http://node_exporter:9100"
echo -e "  ${BOLD}cAdvisor (internal)${RESET}    http://cadvisor:8080 (dashboard: 'cAdvisor - Container Metrics')"
echo -e "  ${BOLD}Compose file${RESET}       ${COMPOSE_FILE}"
echo ""
echo -e "${YELLOW}  Note:${RESET}"
echo -e "  - Prometheus scrapes only containers labeled 'prometheus.scrape=true'."
echo -e "  - Add 'prometheus.scrape=true' and 'prometheus.port=<port>' labels to a container to monitor it."
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Follow logs   : docker compose -f ${COMPOSE_FILE} logs -f"
echo -e "  Stop stack    : docker compose -f ${COMPOSE_FILE} down"
echo -e "  Start stack   : docker compose -f ${COMPOSE_FILE} up -d"
echo -e "  Restart stack : docker compose -f ${COMPOSE_FILE} restart"
echo -e "  Reload config : docker compose -f ${COMPOSE_FILE} exec prometheus wget -q --post-data='' http://localhost:9090/-/reload"
echo ""
