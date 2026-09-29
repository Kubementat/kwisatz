#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# =============================================================================
# setup-laya.sh — Install Laya (System 1 decision model) as a systemd daemon
# =============================================================================
#
# DESCRIPTION:
#   Installs "laya[serve]" (the official PyTorch + FastAPI server, see
#   docs/research/laya-system1-model-research.md §6.1) into an isolated
#   Python venv and runs it as a native systemd service. Laya is not a
#   llama.cpp/GGUF model — it is a Python package exposing a `laya-serve`
#   binary. The service binds LAYA_HOST:LAYA_PORT (default: 0.0.0.0:7771)
#   and answers typed choice/score/noul questions on POST /v1/systemone.
#
# KEY ACTIONS:
#   1. Pre-flight checks: python3, pip, venv module, systemctl, curl
#   2. Creates/reuses a venv at LAYA_DIR/venv
#   3. Installs (or upgrades, with --force) laya[serve] into the venv
#      on CPU machines: CPU-only torch wheels, skipping the multi-GB CUDA stack
#   4. Resolves the API token: uses LAYA_API_KEY if set, reads it back from
#      LAYA_DIR/.env on re-runs, otherwise generates one (openssl rand)
#   5. Generates and installs laya.service from template (EnvironmentFile=
#      LAYA_DIR/.env, mode 600 — the token is never rendered into the unit)
#   6. Reloads systemd, starts and enables the service
#   7. Waits for GET /health to report status ok
#   8. Adds a UFW inbound rule for LAYA_PORT (unless bound to loopback)
#   9. Writes a convenience start script to LAYA_DIR/start-laya.sh for
#      running laya-serve manually in the foreground
#
# IMPORTANT VARIABLES:
#   LAYA_DIR      - Install directory for the venv (default: /srv/laya)
#   LAYA_VERSION  - laya[serve] version to pin (default: 0.3.19)
#   LAYA_PORT     - Bind port for the API server (default: 7771)
#   LAYA_HOST     - Bind address (default: 0.0.0.0)
#   LAYA_DEVICE   - cpu|cuda for LAYA_DEVICE env var (default: auto-detect)
#   LAYA_USER     - Service runtime user (default: invoking user)
#   LAYA_PRELOAD  - Build checkpoints at startup: 0|1 (default: 1)
#   LAYA_API_KEY  - Bearer token required for POST /v1/systemone. If unset,
#                   read back from LAYA_DIR/.env; if still absent, a new token
#                   is generated with `openssl rand -hex 24` (never rotated on
#                   re-runs). /health stays open for the health gate.
#   LAYA_HEALTH_TIMEOUT - Health check timeout in seconds (default: 300)
#
# USAGE:
#   ./setup-laya.sh                # install/reuse venv, install + start service
#   ./setup-laya.sh --check        # check installation status only
#   ./setup-laya.sh --force        # reinstall/upgrade the package
#   ./setup-laya.sh --help         # show help and exit
#
# REFERENCE:
#   docs/research/laya-system1-model-research.md
#   https://huggingface.co/convaiinnovations/laya
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — handles partial failures
# ─────────────────────────────────────────────────────────────────────────────

# Set to 1 immediately BEFORE this run stops/starts or enables the laya unit,
# and reset to 0 once the service is proven healthy. The trap touches the unit
# only while this flag is set, so a late failure (config write, ufw) cannot
# stop a unit that was running before this script was invoked.
SERVICE_TOUCHED_THIS_RUN=0

cleanup_on_failure() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  if (( SERVICE_TOUCHED_THIS_RUN != 1 )); then
    warn "Setup failed (exit code: ${exit_code}). The laya service was not touched by this run — nothing stopped."
    return 0
  fi
  echo ""
  warn "Setup failed (exit code: ${exit_code})! Cleaning up the service state from this run..."
  if sudo systemctl cat laya &>/dev/null 2>&1; then
    if sudo systemctl is-active laya &>/dev/null; then
      info "Disabling and stopping partially configured service..."
      sudo systemctl stop laya 2>/dev/null || true
      sudo systemctl disable laya 2>/dev/null || true
      sudo systemctl daemon-reload 2>/dev/null || true
      success "Partial service removed."
    else
      info "Service from this run is already stopped — data in ${LAYA_DIR} is preserved."
    fi
  fi
}

trap cleanup_on_failure EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT DIRECTORY & LIBRARY
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/laya")"

# shellcheck source=../lib/helpers.sh
source "${LIB_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

LAYA_DIR="${LAYA_DIR:-/srv/laya}"
LAYA_VERSION="${LAYA_VERSION:-0.3.19}"
LAYA_PORT="${LAYA_PORT:-7771}"
LAYA_HOST="${LAYA_HOST:-0.0.0.0}"
LAYA_DEVICE="${LAYA_DEVICE:-}"   # empty = auto-detect below
LAYA_USER="${LAYA_USER:-${SUDO_USER:-$(id -un)}}"  # service runtime user
LAYA_PRELOAD="${LAYA_PRELOAD:-1}"
LAYA_API_KEY="${LAYA_API_KEY:-}"  # empty = read back from .env / generate
LAYA_HEALTH_TIMEOUT="${LAYA_HEALTH_TIMEOUT:-300}"  # health check timeout (s)
SERVICE_FILE="/etc/systemd/system/laya.service"
ENV_FILE="${LAYA_DIR}/.env"  # holds LAYA_API_KEY (mode 600), loaded via EnvironmentFile

CHECK_ONLY=0
FORCE=0

VENV_DIR="${LAYA_DIR}/venv"
VENV_PIP="${VENV_DIR}/bin/pip"
VENV_LAYA_SERVE="${VENV_DIR}/bin/laya-serve"

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs "laya[serve]" (self-hosted Laya System 1 decision model server,
see docs/research/laya-system1-model-research.md) into an isolated Python
venv at ${LAYA_DIR}/venv and runs it as a native systemd service
(laya.service). The server answers typed choice/score/noul questions on
POST /v1/systemone. A UFW inbound rule is added for the API port unless
the server is bound to loopback.

${BOLD}Options:${RESET}
  --check        Check installation status only (no changes)
  --force        Reinstall/upgrade the laya[serve] package
  -h, --help     Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  LAYA_DIR           Install directory for the venv (default: /srv/laya)
  LAYA_VERSION       laya[serve] version to pin (default: 0.3.19)
  LAYA_PORT          Bind port for the API server (default: 7771)
  LAYA_HOST          Bind address (default: 0.0.0.0; use 127.0.0.1 to keep
                     the API local-only — no UFW rule is added then)
  LAYA_DEVICE        cpu|cuda for the LAYA_DEVICE env var (default: auto-detect
                     via nvidia-smi). "cpu" also installs CPU-only torch wheels
                     (skips the multi-GB nvidia CUDA stack pulled by the default
                     torch wheel from PyPI).
  LAYA_USER          Service runtime user (default: invoking user)
  LAYA_PRELOAD       Build checkpoints at startup, 0|1 (default: 1)
  LAYA_API_KEY       Bearer token required for POST /v1/systemone. If unset,
                     the existing value in ${LAYA_DIR}/.env is reused; if no
                     token exists yet, one is generated (openssl rand -hex 24).
                     GET /health is never authenticated. Re-runs never rotate
                     an existing token.
  LAYA_HEALTH_TIMEOUT  Health check timeout in seconds (default: 300)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

if ! command -v python3 &>/dev/null; then
  error "python3 is not installed. Run tasks/setup-basics.sh first."
fi
if ! python3 -m venv --help &>/dev/null; then
  error "python3 'venv' module is not available. Install with: sudo apt-get install python3-venv"
fi
success "python3 $(python3 --version | awk '{print $2}') detected."

if ! command -v systemctl &>/dev/null; then
  error "systemctl is not available. This script requires systemd."
fi
if ! command -v curl &>/dev/null; then
  error "curl is not installed. Required for health checks."
fi
if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
fi

if [[ "$EUID" -ne 0 ]]; then
  warn "Not running as root. Commands requiring root privileges will use sudo."
fi

if [[ -z "$LAYA_DEVICE" ]]; then
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    LAYA_DEVICE="cuda"
  else
    LAYA_DEVICE="cpu"
  fi
fi
info "LAYA_DEVICE=${LAYA_DEVICE}"
info "LAYA_USER=${LAYA_USER}"

# ─────────────────────────────────────────────────────────────────────────────
# CHECK-ONLY MODE
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  step "Checking for existing Laya installation"
  if [[ -x "$VENV_LAYA_SERVE" ]]; then
    success "Venv found at ${VENV_DIR}"
    "$VENV_PIP" show laya 2>/dev/null | grep -E '^(Name|Version)' | sed 's/^/    /'
  else
    warn "No laya[serve] install found at ${VENV_DIR}."
    info "Run without --check to install."
  fi
  if [[ -f "$SERVICE_FILE" ]]; then
    success "systemd service file found at ${SERVICE_FILE}"
    if sudo systemctl is-active laya &>/dev/null; then
      success "Service is currently running."
      success "Health: $(curl -s -m 5 "http://127.0.0.1:${LAYA_PORT}/health" 2>/dev/null || echo 'unreachable')"
      sudo systemctl status laya --no-pager
    else
      warn "Service is not running. Start with: sudo systemctl start laya"
    fi
  else
    warn "No systemd service installed at ${SERVICE_FILE}"
  fi
  if [[ -n "$(env_file_get "$ENV_FILE" LAYA_API_KEY 2>/dev/null || true)" ]]; then
    success "API token configured (token in ${ENV_FILE}, mode 600)"
  else
    info "No API token configured yet — the API is unauthenticated."
  fi
  if [[ -x "${LAYA_DIR}/start-laya.sh" ]]; then
    success "Start script at ${LAYA_DIR}/start-laya.sh"
  fi
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# PORT / EXISTING SERVICE CHECKS
# ─────────────────────────────────────────────────────────────────────────────

if [[ ! -f "$SERVICE_FILE" ]]; then
  # No existing installation — check port availability
  if ss -tln 2>/dev/null | grep -q ":${LAYA_PORT} " || \
     netstat -tln 2>/dev/null | grep -q ":${LAYA_PORT} "; then
    error "Port ${LAYA_PORT} is already in use. Choose a different LAYA_PORT."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CREATE VENV
# ─────────────────────────────────────────────────────────────────────────────

step "Setting up venv at ${VENV_DIR}"

if [[ ! -d "$LAYA_DIR" ]]; then
  sudo mkdir -p "$LAYA_DIR"
  sudo chown "$(id -u):$(id -g)" "$LAYA_DIR"
fi

if [[ -x "${VENV_DIR}/bin/python" ]]; then
  success "Venv already exists."
else
  python3 -m venv "$VENV_DIR"
  success "Venv created."
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL laya[serve]
# ─────────────────────────────────────────────────────────────────────────────

step "Installing laya[serve]==${LAYA_VERSION}"

# 'pip show' exits 1 when the package is missing; don't let pipefail
# treat that (the expected fresh-venv case) as a script failure.
INSTALLED_VERSION="$("$VENV_PIP" show laya 2>/dev/null | sed -n 's/^Version: //p' || true)"

if [[ -x "$VENV_LAYA_SERVE" && "$INSTALLED_VERSION" == "$LAYA_VERSION" && "$FORCE" -eq 0 ]]; then
  success "laya[serve] ${INSTALLED_VERSION} already installed. Use --force to reinstall."
else
  "$VENV_PIP" install --upgrade pip --quiet
  if [[ "$LAYA_DEVICE" == "cpu" ]]; then
    # PyPI's default torch wheel pulls the full nvidia-* CUDA stack (~4 GB);
    # on CPU-only machines install the small CPU wheels instead.
    info "Installing CPU-only torch (skips the multi-GB CUDA wheels) — may take a while..."
    "$VENV_PIP" install torch --index-url https://download.pytorch.org/whl/cpu
  else
    info "Downloading torch + CUDA stack (multi-GB) — may take a while..."
  fi
  info "Installing laya[serve]==${LAYA_VERSION} (pip output below; this step blocks until fully installed)..."
  "$VENV_PIP" install "laya[serve]==${LAYA_VERSION}"
  success "laya[serve] ${LAYA_VERSION} installed at ${VENV_DIR}."
fi

[[ -x "$VENV_LAYA_SERVE" ]] || error "Install finished but ${VENV_LAYA_SERVE} is missing — check pip output above."

# ─────────────────────────────────────────────────────────────────────────────
# API TOKEN
# ─────────────────────────────────────────────────────────────────────────────

step "Resolving API token"

# Never rotate a token the service (or its clients) already depend on:
# explicit env > existing .env value > generate new.
if [[ -z "$LAYA_API_KEY" && -f "$ENV_FILE" ]]; then
  LAYA_API_KEY="$(env_file_get "$ENV_FILE" LAYA_API_KEY || true)"
fi

if [[ -n "$LAYA_API_KEY" && -f "$ENV_FILE" ]]; then
  success "API token in use (kept from ${ENV_FILE})."
elif [[ -n "$LAYA_API_KEY" ]]; then
  info "Using LAYA_API_KEY from the environment."
else
  LAYA_API_KEY="$(openssl rand -hex 24)"
  info "Generated a new API token."
fi

printf 'LAYA_API_KEY=%s\n' "$LAYA_API_KEY" | env_file_write "$ENV_FILE"
# The service reads this via EnvironmentFile — it must be readable by the
# service user (env_file_write may have fallen back to a root-owned install).
sudo chown "${LAYA_USER}" "$ENV_FILE" 2>/dev/null || true
success "Token written to ${ENV_FILE} (mode 600, owned by ${LAYA_USER})."

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE AND INSTALL SYSTEMD SERVICE
# ─────────────────────────────────────────────────────────────────────────────

step "Generating systemd service file"

export LAYA_USER LAYA_DIR LAYA_HOST LAYA_PORT LAYA_DEVICE LAYA_PRELOAD VENV_LAYA_SERVE ENV_FILE

SERVICE_TMP="$(mktemp)"
envsubst '${LAYA_USER} ${LAYA_DIR} ${LAYA_HOST} ${LAYA_PORT} ${LAYA_DEVICE} ${LAYA_PRELOAD} ${VENV_LAYA_SERVE} ${ENV_FILE}' \
  < "${TEMPLATE_DIR}/laya.service" \
  > "$SERVICE_TMP"
sudo install -m 644 "$SERVICE_TMP" "$SERVICE_FILE"
rm -f "$SERVICE_TMP"
success "Service file installed at ${SERVICE_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# RELOAD SYSTEMD AND START SERVICE
# ─────────────────────────────────────────────────────────────────────────────

step "Reloading systemd daemon"

sudo systemctl daemon-reload
success "Daemon reloaded."

step "Starting laya service"

# This run now owns the unit: a failure from here on may stop/disable it.
SERVICE_TOUCHED_THIS_RUN=1
if sudo systemctl is-active laya &>/dev/null; then
  info "Service already running — restarting with the new unit."
  sudo systemctl restart laya
else
  sudo systemctl enable laya
  sudo systemctl start laya
fi
success "Service started and enabled."

# ─────────────────────────────────────────────────────────────────────────────
# WAIT FOR HEALTH CHECK
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for laya to respond"

MAX_WAIT="$LAYA_HEALTH_TIMEOUT"
INTERVAL=5
ELAPSED=0
READY=false

# GET /health is unauthenticated and reports {status, loaded, device};
# it returns 200 + "status":"ok" once the server is listening.
ACCESS_URL="http://127.0.0.1:${LAYA_PORT}/health"

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  HEALTH_BODY=$(curl -s -m 5 "$ACCESS_URL" 2>/dev/null || echo "")
  if grep -q '"status":"ok"' <<< "$HEALTH_BODY"; then
    READY=true
    break
  fi
  echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s ... (${HEALTH_BODY:-no response})"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""

if [[ "$READY" == "true" ]]; then
  success "laya is up: ${HEALTH_BODY}"
  SERVICE_TOUCHED_THIS_RUN=0   # proven healthy -> a later failure must not stop the service
else
  warn "laya did not report healthy within ${MAX_WAIT}s (first startup downloads and preloads checkpoints)."
  warn "Check service status and logs:"
  warn "  systemctl status laya"
  warn "  journalctl -u laya -n 50"
fi

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$LAYA_HOST" == "127.0.0.1" || "$LAYA_HOST" == "localhost" ]]; then
  info "Server bound to loopback — no UFW rule required."
else
  ufw_firewall_section "Laya API" "$LAYA_PORT" tcp "laya-api"
fi

# ─────────────────────────────────────────────────────────────────────────────
# DISABLE CLEANUP TRAP ON SUCCESS
# ─────────────────────────────────────────────────────────────────────────────

trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# CONVENIENCE START SCRIPT
# ─────────────────────────────────────────────────────────────────────────────

START_SCRIPT="${LAYA_DIR}/start-laya.sh"
envsubst '${VENV_LAYA_SERVE} ${LAYA_DEVICE}' \
  < "${TEMPLATE_DIR}/start-laya.sh" \
  > "$START_SCRIPT"
chmod 755 "$START_SCRIPT"
success "Start script written to ${START_SCRIPT}"

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Laya setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}API (typed decisions)${RESET}  POST http://<host>:${LAYA_PORT}/v1/systemone"
echo -e "  ${BOLD}Health${RESET}                   http://<host>:${LAYA_PORT}/health  (no auth)"
echo -e "  ${BOLD}FastAPI docs${RESET}             http://<host>:${LAYA_PORT}/docs"
echo -e "  ${BOLD}API token${RESET}                ${LAYA_API_KEY}  (stored in ${ENV_FILE}, mode 600)"
echo -e "  ${BOLD}Venv${RESET}                       ${VENV_DIR}"
echo -e "  ${BOLD}Binary${RESET}                     ${VENV_LAYA_SERVE}"
echo -e "  ${BOLD}Service file${RESET}               ${SERVICE_FILE}"
echo -e "  ${BOLD}Listen${RESET}                     ${LAYA_HOST}:${LAYA_PORT}"
echo -e "  ${BOLD}Runtime user${RESET}               ${LAYA_USER}"
echo -e "  ${BOLD}Manual start script${RESET}        ${START_SCRIPT} (foreground)"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Status:   sudo systemctl status laya"
echo -e "  Restart:  sudo systemctl restart laya"
echo -e "  Stop:     sudo systemctl stop laya"
echo -e "  Logs:     sudo journalctl -u laya -f"
echo -e "  Check:    $0 --check"
echo ""
echo -e "  Test the API (typed choice/score/noul questions, not chat completions):"
echo -e "  curl -X POST http://<host>:${LAYA_PORT}/v1/systemone \\"
echo -e "    -H \"Authorization: Bearer ${LAYA_API_KEY}\" -H \"Content-Type: application/json\" \\"
echo -e "    -d '{\"state\": \"...\", \"questions\": {...}}'"
echo -e "  See docs/research/laya-system1-model-research.md and skills/laya/SKILL.md."
