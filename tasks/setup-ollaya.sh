#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# =============================================================================
# setup-ollaya.sh — Install Ollaya (decision model runtime) as a systemd daemon
# =============================================================================
#
# DESCRIPTION:
#   Installs Ollaya (https://github.com/ollaya-dev/ollaya, "Ollama for decision
#   models") with the official release installer (checksum-verified, pinned
#   version) and runs `ollaya serve` as a native systemd service under a
#   dedicated system user. Models live in OLLAYA_DIR/models. The API listens on
#   OLLAYA_HOST (default 0.0.0.0:11435) and speaks TypeSafe's /v1/systemone as
#   well as the native /api/* endpoints.
#
# KEY ACTIONS:
#   1. Pre-flight checks: glibc >= 2.38, curl, zstd, systemctl, envsubst
#   2. Runs the official install.sh (OLLAYA_NO_SERVICE=1) unless the pinned
#      version is already installed (downloaded to a temp file, not piped)
#   3. Creates the `ollaya` system user and OLLAYA_DIR (models, .env)
#   4. Resolves the API key: OLLAYA_API_KEY env > OLLAYA_DIR/.env > generated
#   5. Renders templates/ollaya/ollaya.service (EnvironmentFile=, mode 600 —
#      the key is never rendered into the unit), enables + (re)starts it
#   6. Waits for GET / ("Ollaya is running") and verifies the key on /api/version
#   7. Pulls OLLAYA_PULL_MODELS through POST /api/pull (idempotent)
#   8. Adds a UFW inbound rule unless bound to loopback
#
# IMPORTANT VARIABLES:
#   OLLAYA_DIR                Data directory (default: /srv/ollaya)
#   OLLAYA_VERSION            Release to install, e.g. 0.7.5 (default: latest release)
#   OLLAYA_INSTALL_DIR        Install prefix for the binary (default: /usr/local)
#   OLLAYA_HOST               Bind host:port (default: 0.0.0.0:11435)
#   OLLAYA_USER               Service user (default: ollaya)
#   OLLAYA_DEVICE             auto|cpu|cuda|cuda:<n> (default: auto)
#   OLLAYA_KEEP_ALIVE         Idle time before unloading a model (default: 5m)
#   OLLAYA_MAX_LOADED_MODELS  Loaded-model limit (default: 3)
#   OLLAYA_NO_CUDA            1 = skip the CUDA libraries even with an NVIDIA GPU
#   OLLAYA_PULL_MODELS        Space separated models to pull (default: laya;
#                             empty = pull nothing)
#   OLLAYA_PULL_TIMEOUT       Timeout per model pull in seconds (default: 3600)
#   OLLAYA_API_KEY            Bearer key; reused from OLLAYA_DIR/.env, else generated
#   OLLAYA_HEALTH_TIMEOUT     Health check timeout in seconds (default: 60)
#
# USAGE:
#   ./setup-ollaya.sh                # install + configure + start
#   ./setup-ollaya.sh --check        # status only
#   ./setup-ollaya.sh --force        # re-run the release installer
#   ./setup-ollaya.sh --help
#
# REFERENCE:
#   docs/research/ollaya-research.md
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — only touches the unit while this run owns its state
# ─────────────────────────────────────────────────────────────────────────────

SERVICE_TOUCHED_THIS_RUN=0

cleanup_on_failure() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  if (( SERVICE_TOUCHED_THIS_RUN != 1 )); then
    warn "Setup failed (exit code: ${exit_code}). The ollaya service was not touched by this run — nothing stopped."
    return 0
  fi
  echo ""
  warn "Setup failed (exit code: ${exit_code})! Stopping the service from this run (data in ${OLLAYA_DIR} is preserved)..."
  sudo systemctl stop ollaya 2>/dev/null || true
  sudo systemctl disable ollaya 2>/dev/null || true
}

trap cleanup_on_failure EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT DIRECTORY & LIBRARY
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/ollaya")"

# shellcheck source=../lib/helpers.sh
source "${LIB_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

OLLAYA_DIR="${OLLAYA_DIR:-/srv/ollaya}"
OLLAYA_VERSION="${OLLAYA_VERSION:-}"   # empty = latest release, resolved below
OLLAYA_INSTALL_DIR="${OLLAYA_INSTALL_DIR:-/usr/local}"
OLLAYA_HOST="${OLLAYA_HOST:-0.0.0.0:11435}"
OLLAYA_USER="${OLLAYA_USER:-ollaya}"
OLLAYA_DEVICE="${OLLAYA_DEVICE:-auto}"
OLLAYA_KEEP_ALIVE="${OLLAYA_KEEP_ALIVE:-5m}"
OLLAYA_MAX_LOADED_MODELS="${OLLAYA_MAX_LOADED_MODELS:-3}"
OLLAYA_NO_CUDA="${OLLAYA_NO_CUDA:-}"
OLLAYA_PULL_MODELS="${OLLAYA_PULL_MODELS-laya}"
OLLAYA_PULL_TIMEOUT="${OLLAYA_PULL_TIMEOUT:-3600}"
OLLAYA_API_KEY="${OLLAYA_API_KEY:-}"
OLLAYA_HEALTH_TIMEOUT="${OLLAYA_HEALTH_TIMEOUT:-60}"

OLLAYA_MODELS="${OLLAYA_DIR}/models"
OLLAYA_BIN="${OLLAYA_INSTALL_DIR%/}/bin/ollaya"
SERVICE_FILE="/etc/systemd/system/ollaya.service"
ENV_FILE="${OLLAYA_DIR}/.env"
INSTALLER_URL="https://ollaya.dev/install.sh"

# host:port split; the server is probed on loopback when it binds a wildcard
OLLAYA_PORT="${OLLAYA_HOST##*:}"
BIND_ADDR="${OLLAYA_HOST%:*}"
BIND_ADDR="${BIND_ADDR#http://}"
[[ "$OLLAYA_HOST" == *:* ]] || { OLLAYA_PORT=11435; BIND_ADDR="$OLLAYA_HOST"; OLLAYA_HOST="${OLLAYA_HOST}:11435"; }
case "$BIND_ADDR" in
  ""|0.0.0.0|"[::]"|"::") PROBE_ADDR="127.0.0.1" ;;
  *) PROBE_ADDR="$BIND_ADDR" ;;
esac
BASE_URL="http://${PROBE_ADDR}:${OLLAYA_PORT}"

CHECK_ONLY=0
FORCE=0

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs Ollaya (decision model runtime, https://github.com/ollaya-dev/ollaya)
with the official checksum-verified release installer (latest release unless
OLLAYA_VERSION is set) and runs it as the
systemd service ollaya.service under the system user "${OLLAYA_USER}". Models
are stored in ${OLLAYA_DIR}/models. A UFW inbound rule is added for the API
port unless the server is bound to loopback.

${BOLD}Options:${RESET}
  --check        Check installation status only (no changes)
  --force        Re-run the release installer even if the target version is installed
  -h, --help     Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  OLLAYA_DIR                Data directory: models, .env (default: /srv/ollaya)
  OLLAYA_VERSION            Release to install, e.g. 0.7.5 (default: the latest
                            GitHub release; re-runs upgrade when a newer one exists)
  OLLAYA_INSTALL_DIR        Install prefix of the binary (default: /usr/local)
  OLLAYA_HOST               Bind host:port (default: 0.0.0.0:11435; use
                            127.0.0.1:11435 to keep it local — no UFW rule then)
  OLLAYA_USER               Service user, created if missing (default: ollaya)
  OLLAYA_DEVICE             auto|cpu|cuda|cuda:<n> (default: auto)
  OLLAYA_KEEP_ALIVE         Idle time before a model is unloaded, -1 = never
                            (default: 5m)
  OLLAYA_MAX_LOADED_MODELS  Loaded-model limit (default: 3)
  OLLAYA_NO_CUDA            1 = don't install CUDA libraries even with a GPU
  OLLAYA_PULL_MODELS        Space separated models to pull, e.g. "laya winnow:e4b"
                            (default: laya; set to empty to pull nothing)
  OLLAYA_PULL_TIMEOUT       Timeout per model pull in seconds (default: 3600)
  OLLAYA_API_KEY            Bearer key required on all requests except GET /.
                            If unset, ${OLLAYA_DIR}/.env is reused; else one is
                            generated (openssl rand -hex 24). Never rotated.
  OLLAYA_HEALTH_TIMEOUT     Health check timeout in seconds (default: 60)
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
# CHECK-ONLY MODE
# ─────────────────────────────────────────────────────────────────────────────

installed_ok() {
  [[ -x "$OLLAYA_BIN" ]] && "$OLLAYA_BIN" --version 2>&1 | grep -qF "$OLLAYA_VERSION"
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  step "Checking for existing Ollaya installation"
  if [[ -x "$OLLAYA_BIN" ]]; then
    success "Binary: ${OLLAYA_BIN} ($("$OLLAYA_BIN" --version 2>&1 | head -n1))"
  else
    warn "No ollaya binary at ${OLLAYA_BIN}. Run without --check to install."
  fi
  if [[ -f "$SERVICE_FILE" ]]; then
    success "systemd unit found at ${SERVICE_FILE}"
    if sudo systemctl is-active ollaya &>/dev/null; then
      success "Service is running: $(curl -s -m 5 "${BASE_URL}/" 2>/dev/null || echo 'unreachable')"
    else
      warn "Service is not running. Start with: sudo systemctl start ollaya"
    fi
  else
    warn "No systemd unit at ${SERVICE_FILE}"
  fi
  if [[ -n "$(sudo sed -n 's/^OLLAYA_API_KEY=//p' "$ENV_FILE" 2>/dev/null || true)" ]]; then
    success "API key configured (${ENV_FILE}, mode 600)"
  else
    info "No API key configured yet — the API is unauthenticated."
  fi
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

for tool in curl systemctl envsubst zstd openssl; do
  command -v "$tool" &>/dev/null || error "${tool} is not installed. Run tasks/setup-basics.sh first (envsubst: gettext-base, zstd: zstd)."
done

GLIBC="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
if ! awk -v v="${GLIBC:-0}" 'BEGIN{split(v,a,"."); exit !(a[1]>2 || (a[1]==2 && a[2]>=38))}'; then
  error "Ollaya needs glibc >= 2.38 (Ubuntu 24.04+); found '${GLIBC:-unknown}'."
fi
success "glibc ${GLIBC}, systemd, curl, zstd present."

if ! ldconfig -p 2>/dev/null | grep -q 'libgomp\.so\.1'; then
  warn "libgomp1 not found — GGUF models (winnow, jevk5) need it: sudo apt-get install libgomp1"
fi

if [[ "$EUID" -ne 0 ]]; then
  warn "Not running as root. Commands requiring root privileges will use sudo."
fi

if [[ -f "$SERVICE_FILE" ]] && ! grep -q 'Managed by kwisatz' "$SERVICE_FILE"; then
  warn "Existing ${SERVICE_FILE} was not created by this script (e.g. upstream install.sh) — it will be replaced."
  warn "Models under /usr/share/ollaya (if any) are NOT migrated to ${OLLAYA_MODELS}."
elif [[ ! -f "$SERVICE_FILE" ]]; then
  if ss -tln 2>/dev/null | grep -q ":${OLLAYA_PORT} "; then
    error "Port ${OLLAYA_PORT} is already in use. Choose a different OLLAYA_HOST."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL BINARY (official release installer, service creation disabled)
# ─────────────────────────────────────────────────────────────────────────────

step "Resolving Ollaya version"

if [[ -z "$OLLAYA_VERSION" ]]; then
  # /releases/latest redirects to /releases/tag/<tag>: no API call, no rate limit.
  LATEST_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/ollaya-dev/ollaya/releases/latest")" \
    || error "Could not determine the latest Ollaya release. Set OLLAYA_VERSION explicitly."
  [[ "$LATEST_URL" == */releases/tag/* ]] \
    || error "No published Ollaya release found. Set OLLAYA_VERSION explicitly."
  OLLAYA_VERSION="${LATEST_URL##*/releases/tag/}"
  info "Using latest release: ${OLLAYA_VERSION#v}"
else
  info "Using requested version: ${OLLAYA_VERSION#v}"
fi
OLLAYA_VERSION="${OLLAYA_VERSION#v}"

step "Installing Ollaya ${OLLAYA_VERSION}"

if installed_ok && [[ "$FORCE" -eq 0 ]]; then
  success "Ollaya ${OLLAYA_VERSION} already installed at ${OLLAYA_BIN}. Use --force to reinstall."
else
  INSTALLER_TMP="$(mktemp)"
  curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_TMP" || error "Could not download ${INSTALLER_URL}"
  OLLAYA_NO_SERVICE=1 OLLAYA_VERSION="$OLLAYA_VERSION" OLLAYA_INSTALL_DIR="$OLLAYA_INSTALL_DIR" \
    OLLAYA_NO_CUDA="$OLLAYA_NO_CUDA" sh "$INSTALLER_TMP"
  rm -f "$INSTALLER_TMP"
fi

[[ -x "$OLLAYA_BIN" ]] || error "Install finished but ${OLLAYA_BIN} is missing — check the installer output above."
success "Binary: ${OLLAYA_BIN}"

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE USER & DATA DIRECTORY
# ─────────────────────────────────────────────────────────────────────────────

step "Preparing service user and ${OLLAYA_DIR}"

if ! id "$OLLAYA_USER" &>/dev/null; then
  sudo useradd -r -s /usr/sbin/nologin -U -M -d "$OLLAYA_DIR" "$OLLAYA_USER"
  success "Created system user ${OLLAYA_USER}."
fi
for grp in render video; do
  if getent group "$grp" &>/dev/null; then sudo usermod -a -G "$grp" "$OLLAYA_USER"; fi
done

sudo mkdir -p "$OLLAYA_MODELS"
sudo chown "${OLLAYA_USER}:${OLLAYA_USER}" "$OLLAYA_DIR" "$OLLAYA_MODELS"
sudo chmod 755 "$OLLAYA_DIR"
success "Data directory ready (models: ${OLLAYA_MODELS})."

# ─────────────────────────────────────────────────────────────────────────────
# API KEY
# ─────────────────────────────────────────────────────────────────────────────

step "Resolving API key"

# Never rotate a key clients already use: env > existing .env > generate.
if [[ -z "$OLLAYA_API_KEY" ]]; then
  OLLAYA_API_KEY="$(sudo sed -n 's/^OLLAYA_API_KEY=//p' "$ENV_FILE" 2>/dev/null | tail -n1 || true)"
  if [[ -n "$OLLAYA_API_KEY" ]]; then success "API key kept from ${ENV_FILE}."; fi
fi
if [[ -z "$OLLAYA_API_KEY" ]]; then
  OLLAYA_API_KEY="$(openssl rand -hex 24)"
  info "Generated a new API key."
fi

# Root-owned mode 600: systemd reads EnvironmentFile as PID 1, not as the service user.
ENV_TMP="$(mktemp)"
printf 'OLLAYA_API_KEY=%s\n' "$OLLAYA_API_KEY" > "$ENV_TMP"
sudo install -m 600 -o root -g root "$ENV_TMP" "$ENV_FILE"
rm -f "$ENV_TMP"
success "Key written to ${ENV_FILE} (mode 600)."

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEMD UNIT
# ─────────────────────────────────────────────────────────────────────────────

step "Generating systemd service file"

export OLLAYA_USER OLLAYA_DIR OLLAYA_HOST OLLAYA_MODELS OLLAYA_DEVICE OLLAYA_KEEP_ALIVE \
  OLLAYA_MAX_LOADED_MODELS OLLAYA_BIN ENV_FILE

SERVICE_TMP="$(mktemp)"
envsubst '${OLLAYA_USER} ${OLLAYA_DIR} ${OLLAYA_HOST} ${OLLAYA_MODELS} ${OLLAYA_DEVICE} ${OLLAYA_KEEP_ALIVE} ${OLLAYA_MAX_LOADED_MODELS} ${OLLAYA_BIN} ${ENV_FILE}' \
  < "${TEMPLATE_DIR}/ollaya.service" > "$SERVICE_TMP"
sudo install -m 644 "$SERVICE_TMP" "$SERVICE_FILE"
rm -f "$SERVICE_TMP"
success "Unit installed at ${SERVICE_FILE}"

sudo systemctl daemon-reload

step "Starting ollaya service"

SERVICE_TOUCHED_THIS_RUN=1
if sudo systemctl is-active ollaya &>/dev/null; then
  info "Service already running — restarting with the new unit."
  sudo systemctl restart ollaya
else
  sudo systemctl enable ollaya
  sudo systemctl start ollaya
fi
success "Service started and enabled."

# ─────────────────────────────────────────────────────────────────────────────
# HEALTH VERIFICATION
# ─────────────────────────────────────────────────────────────────────────────

step "Waiting for ollaya to respond"

ELAPSED=0
READY=false
while (( ELAPSED < OLLAYA_HEALTH_TIMEOUT )); do
  if curl -fsS -m 5 "${BASE_URL}/" 2>/dev/null | grep -q 'Ollaya is running'; then
    READY=true
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [[ "$READY" != "true" ]]; then
  warn "ollaya did not answer within ${OLLAYA_HEALTH_TIMEOUT}s. Check: journalctl -u ollaya -n 50"
  error "Ollaya failed its health check."
fi

# Authenticated request proves the key from the env file is active.
VERSION_BODY="$(curl -fsS -m 5 -H "Authorization: Bearer ${OLLAYA_API_KEY}" "${BASE_URL}/api/version")" \
  || error "Authenticated GET /api/version failed — check ${ENV_FILE} and journalctl -u ollaya."
success "ollaya is up: ${VERSION_BODY}"
SERVICE_TOUCHED_THIS_RUN=0   # proven healthy — a later failure must not stop it

# ─────────────────────────────────────────────────────────────────────────────
# MODELS
# ─────────────────────────────────────────────────────────────────────────────

if [[ -n "$OLLAYA_PULL_MODELS" ]]; then
  step "Pulling models: ${OLLAYA_PULL_MODELS}"
  for model in $OLLAYA_PULL_MODELS; do
    info "Pulling ${model} (idempotent; resumes partial downloads)..."
    curl -fsS -m "$OLLAYA_PULL_TIMEOUT" -H "Authorization: Bearer ${OLLAYA_API_KEY}" \
      -d "{\"model\": \"${model}\", \"stream\": false}" "${BASE_URL}/api/pull" >/dev/null \
      || error "Pulling ${model} failed — check the name (https://ollaya.dev/search) and journalctl -u ollaya."
    success "${model} available."
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────

case "$BIND_ADDR" in
  127.0.0.1|localhost|"[::1]") info "Server bound to loopback — no UFW rule required." ;;
  *) ufw_firewall_section "Ollaya API" "$OLLAYA_PORT" tcp "ollaya-api" ;;
esac

trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Ollaya setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}API${RESET}            http://<host>:${OLLAYA_PORT}  (/v1/systemone, /api/decide)"
echo -e "  ${BOLD}Liveness${RESET}       GET /  (no auth)"
echo -e "  ${BOLD}API key${RESET}        ${OLLAYA_API_KEY}  (stored in ${ENV_FILE}, mode 600)"
echo -e "  ${BOLD}Binary${RESET}         ${OLLAYA_BIN}"
echo -e "  ${BOLD}Models${RESET}         ${OLLAYA_MODELS}"
echo -e "  ${BOLD}Service file${RESET}   ${SERVICE_FILE}"
echo -e "  ${BOLD}Runtime user${RESET}   ${OLLAYA_USER}"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Status:   sudo systemctl status ollaya"
echo -e "  Logs:     sudo journalctl -u ollaya -f"
echo -e "  Models:   OLLAYA_HOST=${PROBE_ADDR}:${OLLAYA_PORT} OLLAYA_API_KEY=<key> ollaya list"
echo -e "  Check:    $0 --check"
echo ""
echo -e "  curl ${BASE_URL}/v1/systemone -H \"Authorization: Bearer ${OLLAYA_API_KEY}\" \\"
echo -e "    -d '{\"model\":\"laya\",\"state\":\"...\",\"questions\":{...}}'"
echo -e "  See docs/research/ollaya-research.md."
