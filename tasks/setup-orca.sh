#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016  # envsubst variable list must stay single-quoted
# =============================================================================
# setup-orca.sh — Install Orca remote server (headless `orca serve`)
# =============================================================================
#
# Description:
#   Provisions a headless Orca (https://www.onorca.dev) remote server on an
#   Ubuntu/Debian host: installs the Electron/Xvfb prerequisites, downloads the
#   Linux AppImage, and runs `orca serve` as the `orca-serve.service` systemd
#   unit — by default under the invoking user (the sudo caller), or under an
#   explicit ORCA_SERVICE_USER. Clients (Orca desktop, web, mobile) pair to the
#   printed access link.
#
#   Optionally (ORCA_DESKTOP=true) a desktop AppImage launcher is installed at
#   /usr/local/bin/orca-desktop for GUI use. NOTE: only one host mode
#   (desktop app OR orca serve) may run on the same machine at a time.
#
#   Source: official headless guide
#   https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md
#
# Options:
#   --force   Re-download the AppImage even if the requested version is installed
#   --help    Display this help message
#
# Environment Variables (all optional):
#   ORCA_VERSION          Release tag (e.g. v1.4.218) or 'latest' (default)
#   ORCA_PORT             serve listen port (default: 6768)
#   ORCA_PAIRING_ADDRESS  Address clients should dial — Tailscale/LAN IP or
#                         hostname, or a full https://…/runtime reverse-proxy
#                         URL. Empty (default) = omit the flag (local-only).
#                         Never use 127.0.0.1 or wildcard addresses.
#   ORCA_MOBILE_PAIRING   'true' = add --mobile-pairing (QR code + link for
#                         the Orca mobile app) (default: false)
#   ORCA_DESKTOP          'true' = also install a desktop AppImage launcher at
#                         /usr/local/bin/orca-desktop (default: false)
#   ORCA_SERVICE_USER     User running the service (default: invoking user, i.e.
#                         the sudo caller)
#   ORCA_INSTALL_DIR      AppImage install directory (default: /opt/orca)
#   ORCA_HEALTH_TIMEOUT   Seconds to wait for the readiness JSON (default: 120)
#
# Usage:
#   sudo ./setup-orca.sh
#   ORCA_PAIRING_ADDRESS=100.64.1.20 sudo ./setup-orca.sh
#   ORCA_VERSION=v1.4.218 ORCA_MOBILE_PAIRING=true ORCA_DESKTOP=true ./setup-orca.sh
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

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
: "${ORCA_VERSION:=latest}"
: "${ORCA_PORT:=6768}"
: "${ORCA_PAIRING_ADDRESS:=}"
: "${ORCA_MOBILE_PAIRING:=false}"
: "${ORCA_DESKTOP:=false}"
: "${ORCA_SERVICE_USER:=${SUDO_USER:-$(id -un)}}"  # service runtime user (invoking user by default)
: "${ORCA_INSTALL_DIR:=/opt/orca}"
: "${ORCA_HEALTH_TIMEOUT:=120}"

if [[ "${ORCA_SERVICE_USER}" == "root" ]]; then
  warn "ORCA_SERVICE_USER resolves to 'root' — run via sudo as a regular user or set ORCA_SERVICE_USER explicitly."
fi

GITHUB_REPO="stablyai/orca"
SERVICE_NAME="orca-serve"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/orca"

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
  cat << 'EOF'
Usage: setup-orca.sh [OPTIONS]

Install Orca remote server (headless `orca serve` under systemd).

Options:
  --force    Re-download the AppImage even if the requested version is installed
  --help     Display this help message

Environment Variables (all optional):
  ORCA_VERSION          Release tag (e.g. v1.4.218) or 'latest' (default: latest)
  ORCA_PORT             serve listen port (default: 6768)
  ORCA_PAIRING_ADDRESS  Address clients should dial — Tailscale/LAN IP or
                        hostname, or a full https://…/runtime URL. Empty =
                        omit the flag (local-only). Never use 127.0.0.1 or
                        wildcard addresses.
  ORCA_MOBILE_PAIRING   'true' = add --mobile-pairing (default: false)
  ORCA_DESKTOP          'true' = also install a desktop AppImage launcher at
                        /usr/local/bin/orca-desktop (default: false)
  ORCA_SERVICE_USER     User running the service (default: invoking user, i.e.
                        the sudo caller)
  ORCA_INSTALL_DIR      AppImage install directory (default: /opt/orca)
  ORCA_HEALTH_TIMEOUT   Seconds to wait for the readiness JSON (default: 120)

Examples:
  sudo ./setup-orca.sh
  ORCA_PAIRING_ADDRESS=100.64.1.20 sudo ./setup-orca.sh
  ORCA_VERSION=v1.4.218 ORCA_MOBILE_PAIRING=true ./setup-orca.sh

After setup, paste the printed pairing URL into
Settings -> Remote Orca Servers -> Add Server on your client.
Docs: https://www.onorca.dev/docs/remote-servers
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
FORCE_INSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE_INSTALL=true
      shift
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      error "Unknown option: $1. Use --help for usage information."
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
step "Running pre-flight checks"

if [[ $(id -u) -ne 0 ]] && ! sudo -n true 2>/dev/null; then
  error "This script requires root or passwordless sudo."
fi
command -v systemctl &>/dev/null || error "systemctl not found — a systemd host is required."
for tool in curl apt-get jq file envsubst; do
  command -v "$tool" &>/dev/null \
    || error "$tool is not installed. (envsubst comes from: sudo apt-get install gettext-base)"
done
if ! [[ "$ORCA_PORT" =~ ^[0-9]+$ ]]; then
  error "ORCA_PORT must be a number between 1 and 65535 (got: ${ORCA_PORT})"
fi
ORCA_PORT=$((10#${ORCA_PORT}))   # normalize: reject octal-ish leading zeros
if (( ORCA_PORT < 1 || ORCA_PORT > 65535 )); then
  error "ORCA_PORT must be a number between 1 and 65535 (got: ${ORCA_PORT})"
fi
if ! [[ "$ORCA_HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || (( 10#${ORCA_HEALTH_TIMEOUT} < 1 )); then
  error "ORCA_HEALTH_TIMEOUT must be a positive integer number of seconds (got: ${ORCA_HEALTH_TIMEOUT})"
fi
ORCA_HEALTH_TIMEOUT=$((10#${ORCA_HEALTH_TIMEOUT}))

# Wildcards and loopback addresses are meaningless as an advertised pairing
# address (bare or embedded in a proxy URL) — fail fast instead of producing
# a server clients cannot reach.
if [[ "${ORCA_PAIRING_ADDRESS}" == *"127."* || "${ORCA_PAIRING_ADDRESS}" == *"::1"* \
  || "${ORCA_PAIRING_ADDRESS}" == *"0.0.0.0"* || "${ORCA_PAIRING_ADDRESS}" == *"*"* ]]; then
  error "ORCA_PAIRING_ADDRESS must be a reachable LAN/Tailscale address or a full https://… URL, not '${ORCA_PAIRING_ADDRESS}'."
fi
success "Pre-flight checks passed"

# ---------------------------------------------------------------------------
# 1. Install apt dependencies
# ---------------------------------------------------------------------------
step "Installing apt dependencies (Xvfb + Electron shared libraries)"

sudo apt-get update -qq

# The 64-bit time_t transition renamed six of the Electron libraries with a
# 't64' suffix on Ubuntu >= 24.04 / Debian >= 13 (see the official headless
# guide). Probe once against the FRESH package index to pick the right set.
if sudo apt-cache show libgtk-3-0t64 &>/dev/null; then
  ELECTRON_LIBS=(libgtk-3-0t64 libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libgbm1
    libasound2t64 libxtst6 libcups2t64 libdrm2 libxkbcommon0 libpango-1.0-0
    libcairo2 libatspi2.0-0t64 libxcomposite1 libxdamage1 libxfixes3 libxrandr2
    libxrender1 libx11-xcb1 libxcb-dri3-0 libxss1)
else
  ELECTRON_LIBS=(libgtk-3-0 libnss3 libatk1.0-0 libatk-bridge2.0-0 libgbm1
    libasound2 libxtst6 libcups2 libdrm2 libxkbcommon0 libpango-1.0-0
    libcairo2 libatspi2.0-0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2
    libxrender1 libx11-xcb1 libxcb-dri3-0 libxss1)
fi

# libfuse2: lets the AppImage run through FUSE (plain name resolves on all
# supported releases). xvfb: Orca auto-starts Xvfb on :99 for `orca serve`.
# git: worktrees are Orca's core unit of work.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl file jq git ca-certificates xvfb libfuse2 zlib1g-dev \
  "${ELECTRON_LIBS[@]}"
success "Dependencies installed"

# ---------------------------------------------------------------------------
# 2. Create the service user
# ---------------------------------------------------------------------------
step "Ensuring service user '${ORCA_SERVICE_USER}'"

if ! id "${ORCA_SERVICE_USER}" &>/dev/null; then
  # Only reached when ORCA_SERVICE_USER was set explicitly to a user that does
  # not exist yet (the default invoking user always exists).
  sudo useradd --system --create-home --shell /usr/sbin/nologin "${ORCA_SERVICE_USER}"
  success "Created system user '${ORCA_SERVICE_USER}'"
else
  info "User '${ORCA_SERVICE_USER}' already exists."
fi

# Lingering keeps the user's systemd manager alive so live terminals/agent
# processes survive in their own orca-daemon-*.scope across service restarts.
if ! sudo loginctl show-user "${ORCA_SERVICE_USER}" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
  sudo loginctl enable-linger "${ORCA_SERVICE_USER}"
  success "Enabled lingering for '${ORCA_SERVICE_USER}'"
else
  info "Lingering already enabled for '${ORCA_SERVICE_USER}'."
fi

ORCA_HOME="$(getent passwd "${ORCA_SERVICE_USER}" | cut -d: -f6)"
[[ -n "${ORCA_HOME}" ]] || error "Could not resolve home directory for user '${ORCA_SERVICE_USER}'"
# A pre-existing user whose home was removed would point the unit's
# WorkingDirectory at nothing — recreate it so the service can start.
if [[ ! -d "${ORCA_HOME}" ]]; then
  sudo mkdir -p -m 750 -o "${ORCA_SERVICE_USER}" -g "${ORCA_SERVICE_USER}" "${ORCA_HOME}"
  info "Recreated missing home directory ${ORCA_HOME}"
fi

# ---------------------------------------------------------------------------
# 3. Install the AppImage
# ---------------------------------------------------------------------------
step "Installing Orca AppImage (version: ${ORCA_VERSION})"

case "$(uname -m)" in
  x86_64)
    ORCA_ASSET="orca-linux.AppImage"
    ORCA_FILE_MACHINE="x86-64"
    ;;
  aarch64|arm64)
    ORCA_ASSET="orca-linux-arm64.AppImage"
    ORCA_FILE_MACHINE="aarch64"
    ;;
  *)
    error "Unsupported architecture: $(uname -m)"
    ;;
esac

ORCA_APPIMAGE="${ORCA_INSTALL_DIR}/orca-linux.AppImage"
ORCA_VERSION_FILE="${ORCA_INSTALL_DIR}/VERSION"

# Resolve the release tag: exact for pinned versions, effective URL for latest.
# GitHub's first redirect for a /latest/download/ URL points at the tagged
# download URL — that is where the release tag lives (the final CDN URL
# does not carry it).
resolve_tag_from_url() {
  curl -fsSI "$1" 2>/dev/null \
    | grep -im1 '^location:' \
    | sed -n 's|.*download/\(v[0-9][^/]*\)/.*|\1|p' || true
}

INSTALLED_VERSION=""
if [[ -f "${ORCA_VERSION_FILE}" ]]; then
  INSTALLED_VERSION="$(sudo cat "${ORCA_VERSION_FILE}")"
fi

# Skip the download only when the requested version is already installed
# (a pinned tag matches the recorded one, or we want 'latest' and a binary
# exists). Any mismatch — or --force — downloads.
SKIP_DOWNLOAD=false
if [[ -f "${ORCA_APPIMAGE}" && "${FORCE_INSTALL}" != "true" ]]; then
  if [[ "${ORCA_VERSION}" == "latest" || "${INSTALLED_VERSION}" == "${ORCA_VERSION}" ]]; then
    SKIP_DOWNLOAD=true
    info "AppImage already installed (version: ${INSTALLED_VERSION:-unknown}). Skipping download (use --force to re-download)."
  else
    info "Installed version ${INSTALLED_VERSION:-unknown} does not match requested ${ORCA_VERSION} — upgrading."
  fi
fi

if [[ "${SKIP_DOWNLOAD}" != "true" ]]; then
  if [[ "${ORCA_VERSION}" == "latest" ]]; then
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/${ORCA_ASSET}"
  else
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${ORCA_VERSION}/${ORCA_ASSET}"
  fi

  info "Downloading ${DOWNLOAD_URL}"
  DOWNLOAD_TMP="$(mktempfile "${ORCA_ASSET}.new")"
  curl -fL --retry 3 "${DOWNLOAD_URL}" -o "${DOWNLOAD_TMP}" \
    || error "Download failed: ${DOWNLOAD_URL}"

  # Verify the payload is an ELF executable for this architecture before
  # touching the live binary (upstream never publishes checksums).
  FILE_INFO="$(LC_ALL=C file "${DOWNLOAD_TMP}")"
  grep -q 'ELF .* executable' <<<"${FILE_INFO}" \
    || error "Downloaded file is not an ELF executable: ${FILE_INFO}"
  grep -qiF "${ORCA_FILE_MACHINE}" <<<"${FILE_INFO}" \
    || error "Downloaded AppImage does not match architecture (${ORCA_FILE_MACHINE}): ${FILE_INFO}"

  DEPLOYED_TAG="$(resolve_tag_from_url "${DOWNLOAD_URL}")"
  [[ -n "${DEPLOYED_TAG}" ]] || DEPLOYED_TAG="unknown"

  # Refuse a symlinked install target (staging/chmod would follow it)
  # and clear any stale staging name.
  sudo test ! -L "${ORCA_APPIMAGE}" \
    || error "Refusing to install over a symlink: ${ORCA_APPIMAGE}"
  sudo rm -f "${ORCA_APPIMAGE}.new"

  sudo install -d -m 755 -o root -g root "${ORCA_INSTALL_DIR}"
  # Stage to a side name and rename — never overwrite a FUSE binary in place.
  sudo install -m 755 -o root -g root "${DOWNLOAD_TMP}" "${ORCA_APPIMAGE}.new"
  sudo mv -f "${ORCA_APPIMAGE}.new" "${ORCA_APPIMAGE}"
  printf '%s\n' "${DEPLOYED_TAG}" | sudo tee "${ORCA_VERSION_FILE}" > /dev/null
  rm -f "${DOWNLOAD_TMP}"
  success "AppImage installed at ${ORCA_APPIMAGE} (version: ${DEPLOYED_TAG})"
fi
# Keep the dir/binary root-owned 755: the service user must not replace them.
sudo chown root:root "${ORCA_INSTALL_DIR}" "${ORCA_APPIMAGE}"
sudo chmod 755 "${ORCA_INSTALL_DIR}" "${ORCA_APPIMAGE}"

# ---------------------------------------------------------------------------
# 4. Render and install the systemd unit
# ---------------------------------------------------------------------------
step "Rendering ${SERVICE_FILE}"

ORCA_SERVE_ARGS=""
if [[ -n "${ORCA_PAIRING_ADDRESS}" ]]; then
  ORCA_SERVE_ARGS+="--pairing-address ${ORCA_PAIRING_ADDRESS} "
fi
if [[ "${ORCA_MOBILE_PAIRING}" == "true" ]]; then
  ORCA_SERVE_ARGS+="--mobile-pairing"
fi

export ORCA_SERVICE_USER ORCA_HOME ORCA_APPIMAGE ORCA_PORT ORCA_SERVE_ARGS
UNIT_TMP="$(mktempfile "orca-serve.service")"
envsubst '${ORCA_SERVICE_USER} ${ORCA_HOME} ${ORCA_APPIMAGE} ${ORCA_PORT} ${ORCA_SERVE_ARGS}' \
  < "${TEMPLATE_DIR}/orca-serve.service" > "${UNIT_TMP}"

if [[ -f "${SERVICE_FILE}" ]] && diff -q <(sudo cat "${SERVICE_FILE}") "${UNIT_TMP}" &>/dev/null; then
  info "Service file unchanged — no daemon-reload/restart needed."
  UNIT_CHANGED=false
else
  sudo install -m 644 -o root -g root "${UNIT_TMP}" "${SERVICE_FILE}"
  sudo systemctl daemon-reload
  success "Service file installed at ${SERVICE_FILE}"
  UNIT_CHANGED=true
fi
rm -f "${UNIT_TMP}"

# ---------------------------------------------------------------------------
# 5. Enable and (re)start the service
# ---------------------------------------------------------------------------
step "Starting ${SERVICE_NAME} service"

# reset-failed clears a tripped StartLimitBurst left by a previous bad launch.
sudo systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
sudo systemctl enable "${SERVICE_NAME}.service"

SERVICE_STATE="$(sudo systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
if [[ "${UNIT_CHANGED}" == "true" || "${SERVICE_STATE}" != "active" ]]; then
  START_TS="$(date +%s)"
  sudo systemctl restart "${SERVICE_NAME}.service"
  RESTARTED=true
  success "Service restarted"
else
  RESTARTED=false
  info "Service already running with the current configuration — left untouched."
fi

# ---------------------------------------------------------------------------
# 6. Verify the stack is healthy (bounded)
# ---------------------------------------------------------------------------
# Readiness contract: unit is active AND the journal contains one
# orca_server_ready line with schemaVersion 1.
get_ready_line() {
  sudo journalctl -u "${SERVICE_NAME}.service" -o cat 2>/dev/null \
    | jq -Rrc 'fromjson? | select(.type == "orca_server_ready" and .schemaVersion == 1)' \
    | tail -n1
}

if [[ "${RESTARTED}" == "true" ]]; then
  step "Waiting for Orca readiness (timeout: ${ORCA_HEALTH_TIMEOUT}s)"

  # Only trust ready lines logged since this restart.
  get_ready_line() {
    sudo journalctl -u "${SERVICE_NAME}.service" -o cat --since "@${START_TS}" 2>/dev/null \
      | jq -Rrc 'fromjson? | select(.type == "orca_server_ready" and .schemaVersion == 1)' \
      | tail -n1
  }

  ELAPSED=0
  READY_LINE=""
  while (( ELAPSED <= ORCA_HEALTH_TIMEOUT )); do
    SERVICE_STATE="$(sudo systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
    if [[ "${SERVICE_STATE}" == "active" ]]; then
      READY_LINE="$(get_ready_line || true)"
      [[ -n "${READY_LINE}" ]] && break
    fi
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
  done
fi

if [[ "${RESTARTED}" == "true" && -z "${READY_LINE}" ]]; then
  {
    echo "Inspect:     sudo systemctl status ${SERVICE_NAME}.service"
    echo "Logs:        sudo journalctl -u ${SERVICE_NAME}.service -n 50"
    echo "Common causes: missing Electron libraries (see apt step), Xvfb not installed,"
    echo "               port ${ORCA_PORT} in use, or an unreachable/invalid ORCA_PAIRING_ADDRESS."
  } | while IFS= read -r line; do warn "${line}"; done
  error "${SERVICE_NAME} did not become ready within ${ORCA_HEALTH_TIMEOUT}s (state: ${SERVICE_STATE:-unknown})"
fi

if [[ "${RESTARTED}" == "false" ]]; then
  READY_LINE="$(get_ready_line || true)"
  if [[ -n "${READY_LINE}" ]]; then
    success "Service active and a ready record is present in the journal"
  else
    warn "Service is active but no ready record was found in the journal — check: sudo journalctl -u ${SERVICE_NAME}.service -n 50"
  fi
fi

BOUND_ENDPOINT="$(jq -r '.boundEndpoint // empty' <<<"${READY_LINE}")"
ADVERTISED_ENDPOINT="$(jq -r '.advertisedEndpoint // empty' <<<"${READY_LINE}")"
PAIRING_URL="$(jq -r '.pairing.url // empty' <<<"${READY_LINE}")"
PAIRING_AVAILABLE="$(jq -r '.pairing.available // false' <<<"${READY_LINE}")"
PAIRING_REASON="$(jq -r '.pairing.reason // empty' <<<"${READY_LINE}")"

# ---------------------------------------------------------------------------
# 7. Firewall rule (each service opens its own port)
# ---------------------------------------------------------------------------
if ufw_available && ufw_active 2>/dev/null; then
  ufw_add_rule "${ORCA_PORT}" tcp "orca-serve runtime" || warn "Could not add UFW rule for ${ORCA_PORT}/tcp"
fi

# ---------------------------------------------------------------------------
# 8. Optional desktop AppImage launcher
# ---------------------------------------------------------------------------
if [[ "${ORCA_DESKTOP}" == "true" ]]; then
  step "Installing desktop AppImage launcher"
  sudo ln -sfn "${ORCA_APPIMAGE}" /usr/local/bin/orca-desktop
  success "Desktop launcher installed: /usr/local/bin/orca-desktop"
  warn "Only one host mode may run per machine: the Orca desktop app OR orca serve."
  warn "Use 'orca-desktop' for GUI use and stop ${SERVICE_NAME} while it runs."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Orca remote server setup complete${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Service${RESET}          ${SERVICE_NAME}.service (user: ${ORCA_SERVICE_USER})"
echo -e "  ${BOLD}AppImage${RESET}         ${ORCA_APPIMAGE} ($(sudo cat "${ORCA_VERSION_FILE}" 2>/dev/null || echo unknown))"
echo -e "  ${BOLD}Bound endpoint${RESET}   ${BOUND_ENDPOINT}"
echo -e "  ${BOLD}Advertised${RESET}       ${ADVERTISED_ENDPOINT}"
if [[ "${PAIRING_AVAILABLE}" == "true" && -n "${PAIRING_URL}" ]]; then
  echo ""
  echo -e "  ${BOLD}Pairing URL${RESET}"
  echo -e "  ${GREEN}${PAIRING_URL}${RESET}"
  echo ""
  echo -e "  Connect a client: Settings -> Remote Orca Servers -> Add Server -> paste the URL."
else
  warn "No pairing URL available (reason: ${PAIRING_REASON:-ORCA_PAIRING_ADDRESS empty})."
  warn "Set ORCA_PAIRING_ADDRESS to a reachable address and re-run to advertise this server."
fi
echo ""
echo -e "  Register agent accounts on the server (interactive):"
echo -e "    sudo -Hu ${ORCA_SERVICE_USER} ${ORCA_APPIMAGE} account add --agent claude"
echo -e "    sudo -Hu ${ORCA_SERVICE_USER} ${ORCA_APPIMAGE} account add --agent codex"
echo -e "  Install agent skills:"
echo -e "    sudo -Hu ${ORCA_SERVICE_USER} ${ORCA_APPIMAGE} skills install --skill orca-cli --skill orchestration"
echo ""
echo -e "  Logs: sudo journalctl -u ${SERVICE_NAME}.service -f"
echo -e "  Docs: https://www.onorca.dev/docs/remote-servers"
echo ""
success "Orca remote server is ready"
