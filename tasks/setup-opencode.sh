#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-opencode.sh — Install Opencode AI Coding Agent
# =============================================================================
#
# Description:
#   Installs the Opencode (V2) CLI by default (npm @opencode/cli). Optionally
#   installs the "opencode" systemd service (OPENCODE_SERVICE=true) or deploys
#   the Opencode server as a Docker Compose stack (USE_DOCKER=true).
#   The CLI install initializes the user-level config file
#   (~/.config/opencode/opencode.json) as {} when it does not exist yet.
#
#   V2 notes (https://opencode.ai/v2/docs/migrate-v1/): the CLI ships as
#   @opencode/cli — the old opencode-ai package never goes past 1.19 — and the
#   server's Basic-auth username is fixed to "opencode", so there is no
#   username to configure and the V1 OPENCODE_SERVER_USERNAME is gone.
#
# Environment Variables:
#   OPENCODE_SERVICE         - Install the opencode systemd service (default: false)
#   USE_DOCKER               - Use Docker Compose mode (default: false)
#   OPENCODE_VERSION         - Version to install (default: 2.2.0). Drives both the
#                              npm package and the default server image.
#   OPENCODE_PORT            - Server port (default: 4096)
#   OPENCODE_HOSTNAME        - Bind address (default: 0.0.0.0; alias: OPENCODE_HOST)
#   OPENCODE_PASSWORD        - Server password (HTTP Basic, username "opencode").
#                              Auto-generated when empty.
#   OPENCODE_DATA_DIR        - Data directory (default: /srv/opencode)
#   OPENCODE_TRAEFIK         - Enable Traefik (default: false)
#   OPENCODE_DOMAIN          - Public domain for Traefik routing (required when OPENCODE_TRAEFIK=true)
#   PROXY_NETWORK            - Traefik Docker network (default: proxy)
#   OPENCODE_IMAGE           - Opencode image (default: ghcr.io/anomalyco/opencode:${OPENCODE_VERSION}, pinned)
#   WAIT_TIMEOUT             - Max seconds to wait for the stack to become healthy (default: 180)
#
# Usage:
#   ./setup-opencode.sh                        # CLI only (default)
#   OPENCODE_SERVICE=true ./setup-opencode.sh  # CLI + systemd service
#   USE_DOCKER=true ./setup-opencode.sh        # Docker Compose stack
# =============================================================================

set -euo pipefail

# Determine script directory and source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/opencode-server"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

SERVICE_NAME="opencode"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

load_config() {
    OPENCODE_SERVICE="${OPENCODE_SERVICE:-false}"
    USE_DOCKER="${USE_DOCKER:-false}"
    OPENCODE_PORT="${OPENCODE_PORT:-4096}"
    OPENCODE_HOSTNAME="${OPENCODE_HOSTNAME:-${OPENCODE_HOST:-0.0.0.0}}"
    OPENCODE_PASSWORD="${OPENCODE_PASSWORD:-}"
    DATA_DIR="${OPENCODE_DATA_DIR:-/srv/opencode}"
    OPENCODE_TRAEFIK="${OPENCODE_TRAEFIK:-false}"
    OPENCODE_DOMAIN="${OPENCODE_DOMAIN:-}"
    PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
    # Pinned on purpose (ticket improvements-2/17): `:latest` made the generated
    # docker-compose.yml pull a moving reference — and on this registry `latest`
    # is still the 1.x line, so only versioned tags are V2 images.
    # Default looked up 2026-10-28 from https://github.com/anomalyco/opencode/releases
    # (v2.2.0; the GHCR tag carries no leading 'v').
    # Update deliberately: docker buildx imagetools inspect ghcr.io/anomalyco/opencode
    OPENCODE_VERSION="${OPENCODE_VERSION:-2.2.0}"
    OPENCODE_IMAGE="${OPENCODE_IMAGE:-ghcr.io/anomalyco/opencode:${OPENCODE_VERSION}}"
    warn_moving_image "${OPENCODE_IMAGE}" "OPENCODE_IMAGE"
}

print_config() {
    local mode
    if [[ "$USE_DOCKER" == "true" ]]; then
        mode="docker"
    elif [[ "$OPENCODE_SERVICE" == "true" ]]; then
        mode="cli + systemd service"
    else
        mode="cli only"
    fi

    echo "Opencode Configuration:"
    echo "  Mode:                     $mode"
    if [[ "$USE_DOCKER" == "true" ]]; then
        echo "  OPENCODE_PORT:            $OPENCODE_PORT"
        echo "  OPENCODE_VERSION:         $OPENCODE_VERSION"
        echo "  OPENCODE_PASSWORD:        ${OPENCODE_PASSWORD:+*** (set)}"
        echo "  DATA_DIR:                 $DATA_DIR"
        echo "  Basic auth username:      opencode (fixed by Opencode V2)"
        if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
            echo "  OPENCODE_DOMAIN:          ${OPENCODE_DOMAIN:-(required for Traefik)}"
            echo "  PROXY_NETWORK:            $PROXY_NETWORK"
        fi
    else
        echo "  OPENCODE_SERVICE:         $OPENCODE_SERVICE"
        if [[ "$OPENCODE_SERVICE" == "true" ]]; then
            echo "  OPENCODE_PORT:            $OPENCODE_PORT"
            echo "  OPENCODE_HOSTNAME:        $OPENCODE_HOSTNAME"
            echo "  OPENCODE_VERSION:         $OPENCODE_VERSION"
            echo "  OPENCODE_PASSWORD:        ${OPENCODE_PASSWORD:+*** (set)}"
            echo "  Basic auth username:      opencode (fixed by Opencode V2)"
        fi
    fi
    echo "--------------------------------"
}

maybe_generate_password() {
    if [[ -n "$OPENCODE_PASSWORD" ]]; then
        return
    fi

    # Re-read the persisted password so re-runs never rotate a secret a running
    # service or an existing session store depends on
    # (specification/project/conventions.md).
    if [[ "$USE_DOCKER" == "true" ]]; then
        # .env is root-owned mode 600 — read it with sudo (env_file_get cannot
        # read it as the invoking user, which would silently rotate the secret).
        local env_file="${DATA_DIR}/.env"
        if [[ -f "$env_file" ]]; then
            OPENCODE_PASSWORD="$(sudo sed -n 's/^[[:space:]]*OPENCODE_PASSWORD=//p' "$env_file" 2>/dev/null | tail -n1 || true)"
        fi
    elif [[ "$OPENCODE_SERVICE" == "true" ]] && [[ -f "$SERVICE_FILE" ]]; then
        OPENCODE_PASSWORD="$(sed -n 's/^Environment="OPENCODE_PASSWORD=\(.*\)"$/\1/p' "$SERVICE_FILE" | tail -n1)"
    fi

    if [[ -n "$OPENCODE_PASSWORD" ]]; then
        info "Reusing the existing Opencode server password."
        return
    fi

    step "Generating secure random password..."
    OPENCODE_PASSWORD=$(openssl rand -base64 32)

    echo ""
    echo "=============================================="
    echo "IMPORTANT: Generated Opencode Server Password"
    echo "=============================================="
    echo ""
    echo "Username: opencode (fixed by Opencode V2)"
    echo "Password: $OPENCODE_PASSWORD"
    echo ""
    echo "Please save this password securely. It will not be displayed again."
    echo "You can set OPENCODE_PASSWORD to reuse it on the next run."
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — handles partial failures (docker mode)
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
    if [[ -d "${DATA_DIR:-}" ]] && cd "$DATA_DIR" 2>/dev/null; then
        if [[ -n "$(sudo docker compose ps -q 2>/dev/null || true)" ]]; then
            sudo docker compose down --remove-orphans 2>/dev/null || true
            info "Removed partially created stack."
        else
            info "Stack from this run is already stopped — data volume (opencode_data) is preserved."
        fi
    fi
}

trap cleanup_on_failure EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

preflight_cli() {
    step "Running pre-flight checks (CLI mode)"

    if ! command -v sudo &>/dev/null; then
        error "sudo is not installed."
    fi
    if ! command -v npm &>/dev/null && ! command -v apt &>/dev/null; then
        error "npm is not installed and apt is unavailable. Install Node.js/npm or set up the basics first (tasks/setup-basics.sh)."
    fi
    success "Pre-flight checks passed."
}

preflight_docker() {
    step "Running pre-flight checks (Docker mode)"

    if ! command -v docker &>/dev/null; then
        error "Docker is not installed or not in PATH. Run setup-docker.sh first."
    fi

    if ! sudo docker info &>/dev/null; then
        error "Docker daemon is not running. Start it with: sudo systemctl start docker"
    fi

    success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

    if [[ -z "$OPENCODE_PASSWORD" ]] && ! command -v openssl &>/dev/null; then
        error "openssl is not installed. Required for generating secure password. Install it or set OPENCODE_PASSWORD manually."
    fi

    if ! command -v envsubst &>/dev/null; then
        error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
    fi

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        _preflight_traefik
    fi
}

_preflight_traefik() {
    if ! ensure_proxy_network; then
        warn "Traefik proxy network '${PROXY_NETWORK}' not found or inaccessible."
        warn "If you want Traefik integration, run setup-traefik.sh first."
        warn "Continuing in direct-access mode..."
        OPENCODE_TRAEFIK="false"
        return
    fi

    if [[ -z "$OPENCODE_DOMAIN" ]]; then
        error "OPENCODE_DOMAIN must be set when OPENCODE_TRAEFIK=true (e.g., opencode.example.com)."
    fi
}

preflight_systemd() {
    step "Running pre-flight checks (systemd mode)"

    if ! command -v openssl &>/dev/null; then
        warn "openssl not found. Generating the password may fail, or set OPENCODE_PASSWORD manually."
    fi

    if ! command -v envsubst &>/dev/null; then
        error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI INSTALL (npm)
# ─────────────────────────────────────────────────────────────────────────────

install_opencode_cli() {
    step "Installing/Updating the Opencode CLI (@opencode/cli@${OPENCODE_VERSION})"

    if ! command -v npm &>/dev/null; then
        info "npm is not installed. Installing Node.js and npm..."
        sudo apt update
        sudo apt install -y nodejs npm
    fi

    # The V1 package (opencode-ai) installs the same `opencode` command and never
    # ships past 1.19, so leaving it behind lets the wrong binary win. Remove it;
    # V2 owns the command from here on.
    if npm ls -g --depth=0 opencode-ai &>/dev/null; then
        info "Removing the V1 package opencode-ai (V2 lives in @opencode/cli)..."
        npm uninstall -g opencode-ai || true
    fi

    # Older runs installed opencode-ai via 'sudo npm install -g', i.e. into a prefix
    # this user cannot write (/usr/local/lib/node_modules/opencode-ai plus a
    # root-owned symlink). npm cannot remove that, and every non-interactive PATH
    # (cron, systemd units, adr containers) silently runs the 1.x binary — so
    # delete it by resolving what *every* 'opencode' on PATH points at.
    local candidate candidate_target candidate_root
    while IFS= read -r candidate; do
        candidate_target="$(readlink -f "$candidate" 2>/dev/null || true)"
        candidate_root="${candidate_target%/bin/*}"
        if [[ "$candidate_root" == */node_modules/opencode-ai ]]; then
            info "Removing the root-owned V1 install in ${candidate_root}..."
            sudo rm -rf "$candidate_root"
            sudo rm -f "$candidate"
        fi
    done < <(type -aP opencode 2>/dev/null || true)

    if command -v opencode &>/dev/null; then
        info "Opencode found at $(command -v opencode) (current: $(opencode --version 2>/dev/null || echo unknown)). Installing the pinned version..."
    fi

    # No --force, no :latest: the version is pinned, and npm refuses a prefix it
    # cannot write rather than silently installing to a location that loses to
    # another node prefix on PATH.
    npm install -g "@opencode/cli@${OPENCODE_VERSION}"

    local installed
    # 'opencode --version' prints "opencode v2.2.0", so pick the number out of it.
    installed="$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    installed="${installed:-unknown}"
    if [[ "$installed" != 2.* ]]; then
        error "expected opencode 2.x from @opencode/cli@${OPENCODE_VERSION}, found '${installed}' at $(command -v opencode || echo 'nothing on PATH')"
    fi

    success "Opencode CLI ${installed} installed."

    # Ensure the user-level config file (config + provider/model definitions)
    # exists; initialize it as {} when missing. Tools that merge models into
    # it (e.g. tasks/sync-models.py) require the file to exist.
    step "Ensuring Opencode config file exists"
    local opencode_config="${HOME}/.config/opencode/opencode.json"
    if [[ ! -f "${opencode_config}" ]]; then
        mkdir -p "$(dirname "${opencode_config}")"
        echo '{}' > "${opencode_config}"
        info "Initialized ${opencode_config}"
    else
        info "Already present: ${opencode_config}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DOCKER MODE
# ─────────────────────────────────────────────────────────────────────────────

_generate_compose_file() {
    local compose_file="$1"
    local compose_template

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        compose_template="${TEMPLATE_DIR}/docker-compose.traefik.yml"
    else
        compose_template="${TEMPLATE_DIR}/docker-compose.direct.yml"
    fi

    GENERATED_DATE="$(date -Iseconds)"
    export GENERATED_DATE OPENCODE_PORT PROXY_NETWORK OPENCODE_DOMAIN OPENCODE_IMAGE
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    envsubst '${GENERATED_DATE} ${OPENCODE_PORT} ${PROXY_NETWORK} ${OPENCODE_DOMAIN} ${OPENCODE_IMAGE}' \
        < "$compose_template" | sudo tee "$compose_file" > /dev/null
}

_generate_env_file() {
    local env_file="${DATA_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        warn "Existing .env file found. Backing up to ${env_file}.bak"
        sudo cp "$env_file" "${env_file}.bak"
    fi

    export OPENCODE_PASSWORD
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    envsubst '${OPENCODE_PASSWORD}' \
        < "${TEMPLATE_DIR}/env.template" | sudo tee "$env_file" > /dev/null

    sudo chmod 600 "$env_file"
    success "Secrets stored securely in .env file (mode: 600)."
}

_generate_start_script() {
    sudo cp "${TEMPLATE_DIR}/start_opencode.sh" "${DATA_DIR}/start_opencode.sh"
    sudo chmod +x "${DATA_DIR}/start_opencode.sh"
    success "start_opencode.sh created."
}

_wait_for_opencode_docker() {
    step "Waiting for Opencode to respond"

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        info "Traefik mode: skipping direct health check (TLS access at https://${OPENCODE_DOMAIN})"
        info "Container will be accessible once DNS resolves and TLS is provisioned."
        return 0
    fi

    # /api/info is the V2 readiness/identity endpoint (GET /api/info -> ServerInfo).
    # The username is always 'opencode'; see https://opencode.ai/v2/docs/cli/web.
    local access_url="http://localhost:${OPENCODE_PORT}/api/info"
    local max_wait=120 interval=5 elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        if curl -fsS -u "opencode:${OPENCODE_PASSWORD}" -o /dev/null "$access_url"; then
            echo ""
            success "Opencode is up and responding!"
            return 0
        fi
        echo -ne "\r    Waited ${elapsed}s / ${max_wait}s ..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    warn "Opencode did not respond within ${max_wait}s."
    warn "It may still be starting. Check logs with: docker compose logs -f"
}

# Opens OPENCODE_PORT for direct (non-Traefik) server access. Traefik owns
# the public edge in proxy mode, so no direct rule is added there.
_configure_ufw() {
    ufw_firewall_section "opencode" "$OPENCODE_PORT" tcp "OPENCODE"
}

setup_docker() {
    local compose_file="${DATA_DIR}/docker-compose.yml"

    sudo mkdir -p "$DATA_DIR"

    step "Generating ${compose_file}"
    _generate_compose_file "$compose_file"
    success "docker-compose.yml created."

    step "Generating ${DATA_DIR}/.env"
    _generate_env_file

    step "Creating start script"
    _generate_start_script

    step "Pulling Docker images"
    cd "$DATA_DIR"
    sudo docker compose pull
    success "Images pulled."

    step "Starting Opencode stack (detached)"
    STACK_CREATED_THIS_RUN=1
    sudo docker compose up -d

    # Health gate: prove the containers are actually up before reporting
    # success (on failure the EXIT trap tears the stack down while the
    # STACK_CREATED_THIS_RUN flag is set).
    mapfile -t _ids < <(sudo docker compose ps -q)
    wait_for_healthy "${WAIT_TIMEOUT:-180}" "${_ids[@]}" \
      || error "Opencode stack did not come up — see the status output above"
    STACK_CREATED_THIS_RUN=0     # proven healthy -> a later failure must not tear it down

    _wait_for_opencode_docker
    if [[ "$OPENCODE_TRAEFIK" != "true" ]]; then
        _configure_ufw
    fi

    trap - EXIT
}

summary_docker() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Opencode Server (Docker) setup complete!${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo ""

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        echo -e "  ${BOLD}Web UI (Traefik)${RESET}   https://${OPENCODE_DOMAIN}"
        echo -e "  ${BOLD}TLS${RESET}                Enabled via Let's Encrypt"
    else
        echo -e "  ${BOLD}Web UI${RESET}             http://localhost:${OPENCODE_PORT}"
    fi

    echo ""
    echo -e "  ${BOLD}Data directory${RESET}     Persistent volume (opencode_data)"
    echo -e "  ${BOLD}Compose file${RESET}       ${DATA_DIR}/docker-compose.yml"
    echo -e "  ${BOLD}Environment file${RESET}   ${DATA_DIR}/.env"

    if [[ "$OPENCODE_TRAEFIK" != "true" ]]; then
        echo ""
        echo -e "${YELLOW}  Note:${RESET}"
        echo -e "  - OPENCODE_PASSWORD is stored in .env (not exposed in docker-compose.yml)"
        echo -e "  - To use a custom password, set OPENCODE_PASSWORD before running this script"
        echo -e "  - HTTP Basic auth username is 'opencode' (fixed by Opencode V2)"
    fi

    if [[ "$OPENCODE_TRAEFIK" == "true" ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}Traefik-specific commands:${RESET}"
        echo -e "  Check access logs:  docker logs traefik | grep ${OPENCODE_DOMAIN}"
        echo -e "  Verify DNS:         dig ${OPENCODE_DOMAIN}"
    fi

    echo ""
    echo -e "${BOLD}Useful commands:${RESET}"
    echo -e "  Start:        ./start_opencode.sh"
    echo -e "  Stop:         docker compose down"
    echo -e "  Restart:      docker compose restart"
    echo -e "  Follow logs:  docker compose logs -f"
    echo -e "  Shell into:   docker exec -it ${SERVICE_NAME} bash"

    if [[ "$OPENCODE_TRAEFIK" != "true" ]]; then
        echo ""
        echo -e "${BOLD}Security Notice:${RESET}"
        echo -e "  Your OPENCODE_PASSWORD is stored in .env (mode: 600)."
        echo -e "  Authenticate as 'opencode:<password>'; do not share this file or expose it without TLS."
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEMD MODE
# ─────────────────────────────────────────────────────────────────────────────

# Render the unit and install it only when it differs from what is already
# there, so re-running this script converges an existing service instead of
# leaving a stale unit behind (Re-run policy in specification/project/conventions.md).
_write_service_file() {
    local rendered
    rendered="$(mktemp)"

    # The npm install puts the binary wherever the invoking user's node prefix
    # points, so resolve it from PATH instead of assuming /usr/local/bin.
    local opencode_bin
    opencode_bin="$(command -v opencode || true)"
    [[ -n "$opencode_bin" ]] || error "opencode binary not found on PATH — install the CLI first"

    export USER HOME OPENCODE_PASSWORD OPENCODE_HOSTNAME OPENCODE_PORT OPENCODE_BIN="$opencode_bin"
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    envsubst '${USER} ${HOME} ${OPENCODE_PASSWORD} ${OPENCODE_HOSTNAME} ${OPENCODE_PORT} ${OPENCODE_BIN}' \
        < "${TEMPLATE_DIR}/${SERVICE_NAME}.service" > "$rendered"

    if [[ -f "$SERVICE_FILE" ]] && sudo cmp -s "$rendered" "$SERVICE_FILE"; then
        info "Service unit ${SERVICE_FILE} is already current — leaving it in place."
        rm -f "$rendered"
        return
    fi

    sudo install -m 644 "$rendered" "$SERVICE_FILE"
    rm -f "$rendered"
    success "Service file written to $SERVICE_FILE"
}

_test_health_endpoint() {
    if [[ "$OPENCODE_HOSTNAME" == "127.0.0.1" || "$OPENCODE_HOSTNAME" == "localhost" ]]; then
        return
    fi

    info "Testing readiness endpoint..."
    sleep 3
    if command -v curl &>/dev/null; then
        curl -s -u "opencode:${OPENCODE_PASSWORD}" \
            "http://$OPENCODE_HOSTNAME:$OPENCODE_PORT/api/info" || true
    fi
}

setup_systemd() {
    step "Creating systemd service file"
    _write_service_file

    step "Reloading systemd daemon"
    sudo systemctl daemon-reload
    success "Systemd daemon reloaded."

    step "Enabling ${SERVICE_NAME}.service"
    sudo systemctl enable "${SERVICE_NAME}.service"
    success "Service enabled (will start on boot)."

    step "Starting/restarting ${SERVICE_NAME}.service"
    if sudo systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        info "Service is running. Restarting to apply changes..."
        sudo systemctl restart "${SERVICE_NAME}.service"
    else
        info "Service not running. Starting..."
        sudo systemctl start "${SERVICE_NAME}.service"
    fi
    success "Opencode service started/restarted successfully."

    _configure_ufw
    _test_health_endpoint
}

summary_systemd() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Opencode Server (systemd) setup complete!${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Web UI${RESET}   http://${OPENCODE_HOSTNAME}:${OPENCODE_PORT}"
    echo ""
    echo -e "${BOLD}${CYAN}HTTP Basic auth:${RESET}"
    echo -e "  Username: opencode (fixed by Opencode V2)"
    if [[ -n "$OPENCODE_PASSWORD" ]]; then
        echo -e "  Password: *** (configured)"
    else
        echo -e "  Password: *** (auto-generated on first run via env vars)"
    fi

    echo ""
    echo -e "${BOLD}Useful commands:${RESET}"
    echo -e "  Status:       sudo systemctl status ${SERVICE_NAME}"
    echo -e "  Start:        sudo systemctl start ${SERVICE_NAME}"
    echo -e "  Stop:         sudo systemctl stop ${SERVICE_NAME}"
    echo -e "  Restart:      sudo systemctl restart ${SERVICE_NAME}"
    echo -e "  Logs:         sudo journalctl -u ${SERVICE_NAME} -f"

    echo ""
    echo -e "${BOLD}Security Notice:${RESET}"
    echo -e "  Environment variables are stored in the systemd service file."
    echo -e "  View with: sudo systemctl cat ${SERVICE_NAME}"
    echo ""
}

summary_cli() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Opencode CLI setup complete!${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Version${RESET}  $(opencode --version 2>/dev/null || echo 'unknown')"
    echo ""
    echo -e "${BOLD}Useful commands:${RESET}"
    echo -e "  Run interactively:  opencode"
    echo -e "  Start server:       opencode serve --hostname 0.0.0.0 --port ${OPENCODE_PORT}"
    echo -e "  Install the systemd service:"
    echo -e "                     OPENCODE_SERVICE=true ./setup-opencode.sh"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────

uninstall_cli() {
    step "Uninstalling Opencode CLI"

    if command -v npm &>/dev/null; then
        # Both packages own the `opencode` command; V2 is @opencode/cli, V1 was
        # opencode-ai. Remove whichever is installed.
        for pkg in @opencode/cli opencode-ai; do
            if npm ls -g --depth=0 "$pkg" &>/dev/null; then
                info "Removing npm package ${pkg}..."
                npm uninstall -g "$pkg" || true
            fi
        done
        success "Opencode CLI removed."
    else
        warn "npm not found. Nothing to remove."
    fi

    # Config (~/.config/opencode) and session data (~/.local/share/opencode) are
    # deliberately left alone — this script does not delete user history.
    info "Left untouched: ~/.config/opencode and ~/.local/share/opencode"
}

uninstall_docker() {
    step "Uninstalling Opencode Server (Docker mode)"

    if [[ -f "${DATA_DIR}/docker-compose.yml" ]]; then
        info "Stopping and removing Docker stack..."
        cd "$DATA_DIR"
        sudo docker compose down --remove-orphans
        success "Docker stack removed."
    else
        warn "No docker-compose.yml found in ${DATA_DIR}. Skipping stack teardown."
    fi

    if [[ -d "$DATA_DIR" ]]; then
        info "Removing data directory ${DATA_DIR}..."
        sudo rm -rf "$DATA_DIR"
        success "Data directory removed."
    fi

    if ufw_available && [[ "$OPENCODE_TRAEFIK" != "true" ]]; then
        step "Removing UFW firewall rule for port ${OPENCODE_PORT}"
        ufw_delete_rule "$OPENCODE_PORT" "tcp"
    fi

    success "Opencode Server (Docker) uninstalled."
}

uninstall_systemd() {
    step "Uninstalling Opencode Server (systemd mode)"

    if sudo systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        info "Stopping ${SERVICE_NAME}.service..."
        sudo systemctl stop "${SERVICE_NAME}.service"
        success "Service stopped."
    fi

    if sudo systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        info "Disabling ${SERVICE_NAME}.service..."
        sudo systemctl disable "${SERVICE_NAME}.service"
        success "Service disabled."
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        info "Removing service file ${SERVICE_FILE}..."
        sudo rm "$SERVICE_FILE"
        sudo systemctl daemon-reload
        success "Service file removed and daemon reloaded."
    else
        warn "Service file ${SERVICE_FILE} not found. Already removed?"
    fi

    if ufw_available; then
        step "Removing UFW firewall rule for port ${OPENCODE_PORT}"
        ufw_delete_rule "$OPENCODE_PORT" "tcp"
    fi

    success "Opencode Server (systemd) uninstalled."
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage: setup-opencode.sh [--help] [--uninstall]

Installs the Opencode AI coding agent.
By default only the CLI is installed (npm). The systemd service and the
Docker Compose stack are opt-in via environment variables.
All configuration is provided via environment variables.

GENERAL OPTIONS
  OPENCODE_PORT                Port to bind the server to.
                               Default: 4096
  OPENCODE_PASSWORD            Password for HTTP basic auth (server modes).
                               The username is always "opencode" (Opencode V2
                               removed OPENCODE_SERVER_USERNAME).
                               Default: auto-generated (printed once at startup)

INSTALL MODES
  OPENCODE_SERVICE             Set to "true" to install the "opencode" systemd
                               service (in addition to the CLI).
                               Default: false (CLI only)
  USE_DOCKER                   Set to "true" to use Docker Compose deployment
                               instead of the CLI/systemd install.
                               Default: false

DOCKER MODE OPTIONS            (only used when USE_DOCKER=true)
  OPENCODE_DATA_DIR            Host directory for Docker Compose files and .env.
                               Default: /srv/opencode
  OPENCODE_IMAGE               Image used by the generated docker-compose.yml.
                               Defaults to the pinned OPENCODE_VERSION tag.
                               Override with an explicit version tag, never a
                               moving tag: this registry's :latest is still 1.x.
                               Default: ghcr.io/anomalyco/opencode:<OPENCODE_VERSION>
  WAIT_TIMEOUT                 Max seconds to wait for the stack to come up and
                               become healthy after 'docker compose up -d'.
                               Default: 180

SYSTEMD MODE OPTIONS           (only used when OPENCODE_SERVICE=true)
  OPENCODE_HOSTNAME            Hostname/IP to bind the server to.
                               Default: 0.0.0.0 (alias: OPENCODE_HOST)

TRAEFIK OPTIONS                (only used when USE_DOCKER=true)
  OPENCODE_TRAEFIK             Set to "true" to enable Traefik reverse proxy integration.
                               Default: false
  OPENCODE_DOMAIN              Public domain name for Traefik routing.
                               Required when OPENCODE_TRAEFIK=true
                               Example: opencode.example.com
  PROXY_NETWORK                Name of the external Docker network Traefik listens on.
                               Default: proxy

PRIVILEGES
  Run as your normal user — the script escalates with sudo internally where
  needed (npm/apt installs, /srv/opencode, systemd, ufw, docker).

NOTES
  The CLI install runs 'npm install -g @opencode/cli@<OPENCODE_VERSION>' and
  removes the V1 package opencode-ai first: both provide the same `opencode`
  command, so they must not both be installed. The user config file
  (~/.config/opencode/opencode.json) is initialized to {} when missing so model
  sync tooling can merge into it; existing config and session data are kept.

  Opencode V2 replaces the layered V1 tui.json with a single global
  ~/.config/opencode/cli.json on the first interactive run; that file is owned
  by the terminal client, not by this script.

EXAMPLES
  # CLI only (default):
  ./setup-opencode.sh

  # CLI + systemd service with explicit password:
  OPENCODE_SERVICE=true OPENCODE_PASSWORD=mysecret ./setup-opencode.sh

  # Docker mode with Traefik:
  USE_DOCKER=true OPENCODE_TRAEFIK=true OPENCODE_DOMAIN=opencode.example.com \
    ./setup-opencode.sh

  # Docker mode, direct port binding:
  USE_DOCKER=true OPENCODE_PORT=4096 ./setup-opencode.sh

  # Uninstall (CLI, default):
  ./setup-opencode.sh --uninstall

  # Uninstall (systemd service):
  OPENCODE_SERVICE=true ./setup-opencode.sh --uninstall

  # Uninstall (Docker mode):
  USE_DOCKER=true ./setup-opencode.sh --uninstall
EOF
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    load_config

    if [[ "${1:-}" == "--uninstall" ]]; then
        if [[ "$USE_DOCKER" == "true" ]]; then
            uninstall_docker
        elif [[ "$OPENCODE_SERVICE" == "true" ]]; then
            uninstall_systemd
        else
            uninstall_cli
        fi
        exit 0
    fi

    print_config

    if [[ "$USE_DOCKER" == "true" ]]; then
        maybe_generate_password
        preflight_docker
        setup_docker
        summary_docker
    else
        preflight_cli
        install_opencode_cli
        if [[ "$OPENCODE_SERVICE" == "true" ]]; then
            maybe_generate_password
            preflight_systemd
            setup_systemd
            summary_systemd
        else
            summary_cli
        fi
    fi
}

main "$@"
