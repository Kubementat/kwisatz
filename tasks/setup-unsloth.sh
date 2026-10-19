#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-unsloth.sh — Install Unsloth Studio and optionally Unsloth Desktop
# =============================================================================
#
# DESCRIPTION:
#   Installs Unsloth Studio (the browser-based web UI) and optionally the
#   Unsloth Desktop native app on Ubuntu/Debian systems.
#
#   Unsloth Studio is installed by default. Unsloth Desktop requires
#   UNSLOTH_INSTALL_DESKTOP=true (or 1).
#
# KEY ACTIONS:
#   1. Pre-flight checks: python3, git, curl, apt
#   2. Install Unsloth Studio via the official installer script
#   3. (Optional) Install Unsloth Desktop from the latest .deb release
#   4. Verify installation by running `unsloth --version`
#
# ENVIRONMENT VARIABLES:
#   UNSLOTH_INSTALL_DESKTOP  Install Unsloth Desktop app (default: false)
#   UNSLOTH_INSTALL_SERVICE  Install Unsloth Studio as systemd service (default: false)
#   UNSLOTH_STUDIO_USER      Runtime user for systemd service (default: $USER)
#   UNSLOTH_STUDIO_PORT      Port for Unsloth Studio (default: 8888)
#   UNSLOTH_STUDIO_BIND      Bind address (default: 127.0.0.1)
#   UNSLOTH_STUDIO_HOME      Custom install directory (default: /srv/unsloth)
#   UNSLOTH_PYTHON           Pin Python version for Unsloth (default: auto)
#   UNSLOTH_NO_TORCH         Skip PyTorch install for GGUF-only mode (default: false)
#
# DEPENDENCIES:
#   - python3 (3.11–3.13): Python runtime
#   - git: Version control (used by installer)
#   - curl: Download installer script
#   - apt / dpkg: Package management (for Desktop .deb)
#
# USAGE:
#   ./setup-unsloth.sh                              # Studio only (default)
#   UNSLOTH_INSTALL_DESKTOP=true ./setup-unsloth.sh # Studio + Desktop
#   UNSLOTH_STUDIO_PORT=9000 ./setup-unsloth.sh     # Custom port
#   ./setup-unsloth.sh --force                      # Force reinstall/update
#   ./setup-unsloth.sh --help                       # Show help and exit
#
# REFERENCE:
#   Studio: https://unsloth.ai/docs/get-started/install#unsloth-studio
#   Desktop: https://unsloth.ai/docs/desktop
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT DIRECTORY & LIBRARY
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"

# shellcheck source=lib/helpers.sh
# shellcheck disable=SC1091
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

UNSLOTH_INSTALL_DESKTOP="${UNSLOTH_INSTALL_DESKTOP:-false}"
UNSLOTH_INSTALL_SERVICE="${UNSLOTH_INSTALL_SERVICE:-false}"
UNSLOTH_STUDIO_USER="${UNSLOTH_STUDIO_USER:-${SUDO_USER:-${USER:-root}}}"
UNSLOTH_STUDIO_PORT="${UNSLOTH_STUDIO_PORT:-8888}"
UNSLOTH_STUDIO_BIND="${UNSLOTH_STUDIO_BIND:-127.0.0.1}"
UNSLOTH_STUDIO_HOME="${UNSLOTH_STUDIO_HOME:-/srv/unsloth}"
UNSLOTH_PYTHON="${UNSLOTH_PYTHON:-}"
UNSLOTH_NO_TORCH="${UNSLOTH_NO_TORCH:-false}"
FORCE=false

INSTALLER_URL="https://unsloth.ai/install.sh"
DESKTOP_DEB_URL="https://github.com/unslothai/unsloth/releases/latest/download/Unsloth-Desktop-Ubuntu.deb"
SERVICE_FILE="/etc/systemd/system/unsloth-studio.service"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/unsloth"

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs Unsloth Studio (browser-based web UI) and optionally Unsloth Desktop.

${BOLD}Options:${RESET}
  -h, --help   Show this help and exit
  --force      Force reinstall/update (skip existing-installation check)

${BOLD}Environment variables${RESET} (all optional):
  UNSLOTH_INSTALL_DESKTOP   Install Unsloth Desktop app (default: false)
                            Set to 'true' or '1' to also install Desktop.
  UNSLOTH_INSTALL_SERVICE   Install Unsloth Studio as systemd service (default: false)
  UNSLOTH_STUDIO_USER       Runtime user for systemd service (default: $USER)
  UNSLOTH_STUDIO_PORT       Port for Unsloth Studio (default: 8888)
  UNSLOTH_STUDIO_BIND       Bind address (default: 127.0.0.1)
  UNSLOTH_STUDIO_HOME       Custom install directory (default: /srv/unsloth)
  UNSLOTH_PYTHON            Pin Python version for Unsloth (default: auto)
  UNSLOTH_NO_TORCH          Skip PyTorch for GGUF-only mode (default: false)

${BOLD}Examples:${RESET}
  # Studio only (default)
  ./setup-unsloth.sh

  # Studio + Desktop
  UNSLOTH_INSTALL_DESKTOP=true ./setup-unsloth.sh

  # Custom port
  UNSLOTH_STUDIO_PORT=9000 ./setup-unsloth.sh

  # Force reinstall
  ./setup-unsloth.sh --force

  # Studio + systemd service
  UNSLOTH_INSTALL_SERVICE=true ./setup-unsloth.sh

  # Studio + Desktop on custom port, bind to all interfaces
  UNSLOTH_INSTALL_DESKTOP=true UNSLOTH_STUDIO_PORT=9000 UNSLOTH_STUDIO_BIND=0.0.0.0 ./setup-unsloth.sh
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# PARSE ARGUMENTS
# ─────────────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=true ;;
    -h|--help) usage; exit 0 ;;
    *)         error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done

# Normalise UNSLOTH_INSTALL_DESKTOP and UNSLOTH_INSTALL_SERVICE to boolean
if [[ "${UNSLOTH_INSTALL_DESKTOP}" == "true" || "${UNSLOTH_INSTALL_DESKTOP}" == "1" ]]; then
  UNSLOTH_INSTALL_DESKTOP=true
else
  UNSLOTH_INSTALL_DESKTOP=false
fi
if [[ "${UNSLOTH_INSTALL_SERVICE}" == "true" || "${UNSLOTH_INSTALL_SERVICE}" == "1" ]]; then
  UNSLOTH_INSTALL_SERVICE=true
else
  UNSLOTH_INSTALL_SERVICE=false
fi

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

# Check python3
if ! command -v python3 &>/dev/null; then
  error "python3 is not installed. Required for Unsloth Studio."
fi
info "Python3 found: $(python3 --version 2>&1 || echo 'unknown')"

# Check git
if ! command -v git &>/dev/null; then
  error "git is not installed. Required for Unsloth Studio. Install with: sudo apt install git"
fi
info "Git found: $(git --version 2>&1 || echo 'unknown')"

# Check curl
if ! command -v curl &>/dev/null; then
  error "curl is not installed. Required for downloading the installer."
fi

# Check apt
if ! command -v apt &>/dev/null; then
  error "apt is not installed. Required for Unsloth Desktop .deb installation."
fi

# Warn if not running as root (Desktop install needs sudo)
if [[ $EUID -ne 0 ]]; then
  warn "Not running as root. Commands requiring root privileges will use sudo."
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK FOR EXISTING INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

step "Checking for existing Unsloth installation"

# Check if Unsloth CLI is already installed
UNSLOTH_CLI_INSTALLED=false
if command -v unsloth &>/dev/null; then
  UNSLOTH_CLI_INSTALLED=true
  info "Unsloth CLI already installed: $(unsloth --version 2>&1 || echo 'unknown')"
else
  info "Unsloth CLI not found"
fi

# Check if Desktop is already installed
DESKTOP_ALREADY_INSTALLED=false
if dpkg-query -W -f='${db:Status-Status}' unsloth 2>/dev/null | grep -qx 'installed'; then
  DESKTOP_ALREADY_INSTALLED=true
  info "Unsloth Desktop package already installed"
else
  info "Unsloth Desktop package not found"
fi

# Guard: exit gracefully if already installed (unless --force)
if [[ "${UNSLOTH_CLI_INSTALLED}" == "true" ]]; then
  if [[ "${FORCE}" == "true" ]]; then
    warn "Unsloth is already installed. --force flag set — proceeding with reinstall."
  else
    info "Unsloth is already installed. Skipping."
    info "Re-run with --force to reinstall or update."
    exit 0
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL UNSLOTH STUDIO
# ─────────────────────────────────────────────────────────────────────────────

step "Installing Unsloth Studio"

# Download the installer script to a temp file (never pipe curl to bash directly)
INSTALLER_SCRIPT="$(mktempfile "unsloth-install.sh")"

info "Downloading installer from ${INSTALLER_URL}"
if ! curl -fsSL "${INSTALLER_URL}" -o "${INSTALLER_SCRIPT}"; then
  error "Failed to download installer from ${INSTALLER_URL}"
fi

INSTALLED_SHA256="$(sha256sum "${INSTALLER_SCRIPT}" | cut -d' ' -f1)"
info "Installer SHA-256: ${INSTALLED_SHA256}"

# Build installer environment (passed via `env` to the installer)
INSTALLER_ENV_ARGS=(UNSLOTH_SKIP_AUTOSTART=1)

if [[ -n "${UNSLOTH_PYTHON}" ]]; then
  INSTALLER_ENV_ARGS+=(UNSLOTH_PYTHON="${UNSLOTH_PYTHON}")
fi

if [[ "${UNSLOTH_NO_TORCH}" == "true" ]]; then
  INSTALLER_ENV_ARGS+=(UNSLOTH_NO_TORCH=1)
fi

info "Installer env overrides: ${INSTALLER_ENV_ARGS[*]}"

# Run the installer — use `set +e` around it because the installer may prompt
# for confirmation; under the orchestrator (run-setup.sh -> deploy.py) stdin is
# /dev/null and INTERACTIVE=false, so a prompt hits EOF and fails fast instead of
# hanging the run — and a missing tty is what makes the installer take its default.
set +e
env "${INSTALLER_ENV_ARGS[@]}" bash "${INSTALLER_SCRIPT}"
INSTALLER_RC=$?
set -e

if (( INSTALLER_RC != 0 )); then
  warn "Unsloth Studio installer exited with code ${INSTALLER_RC}"
  warn "This may be non-fatal — checking if 'unsloth' CLI is now available..."
fi

# Verify the unsloth CLI is now available
if command -v unsloth &>/dev/null; then
  success "Unsloth Studio installed successfully"
  info "Unsloth CLI version: $(unsloth --version 2>&1 || echo 'unknown')"
else
  warn "Unsloth Studio installer ran but 'unsloth' CLI is not yet in PATH"
  warn "Try sourcing your shell profile or opening a new terminal."
  warn "The install directory is: ${UNSLOTH_STUDIO_HOME}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL UNSLOTH DESKTOP (optional)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${UNSLOTH_INSTALL_DESKTOP}" == "true" ]]; then
  step "Installing Unsloth Desktop"

  # Check if Desktop is already installed — skip install if so
  if [[ "${DESKTOP_ALREADY_INSTALLED}" == "true" ]]; then
    success "Unsloth Desktop is already installed, skipping"
  else
    # Download the latest .deb
    DEB_FILE="$(mktempfile "Unsloth-Desktop-Ubuntu.deb")"

    info "Downloading Unsloth Desktop from ${DESKTOP_DEB_URL}"
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "${DEB_FILE}" "${DESKTOP_DEB_URL}"; then
      error "Failed to download Unsloth Desktop .deb from ${DESKTOP_DEB_URL}"
    fi

    DESKTOP_SHA256="$(sha256sum "${DEB_FILE}" | cut -d' ' -f1)"
    info "Downloaded Unsloth Desktop SHA-256: ${DESKTOP_SHA256}"

    # Install the .deb package (dpkg first, then fix dependencies)
    info "Installing Unsloth Desktop .deb package"
    sudo dpkg -i "${DEB_FILE}" || {
      info "Resolving missing dependencies..."
      sudo apt-get update -qq
      sudo apt-get install -f -y --fix-broken || {
        error "Failed to install Unsloth Desktop .deb package"
      }
    }

    success "Unsloth Desktop installed successfully"
  fi
else
  info "Unsloth Desktop install disabled (set UNSLOTH_INSTALL_DESKTOP=true to enable)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL SYSTEMD SERVICE (optional)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${UNSLOTH_INSTALL_SERVICE}" == "true" ]]; then
  step "Installing Unsloth Studio systemd service"

  # Check if service is already installed
  if [[ -f "${SERVICE_FILE}" && "${FORCE}" != "true" ]]; then
    warn "Systemd service file already exists at ${SERVICE_FILE}. Skipping (use --force to replace)."
  else
    if [[ -f "${SERVICE_FILE}" ]]; then
      info "--force flag set — replacing existing service."
      sudo systemctl stop unsloth-studio 2>/dev/null || true
      sudo systemctl disable unsloth-studio 2>/dev/null || true
    fi

    if [[ ! -f "${TEMPLATE_DIR}/unsloth-studio.service" ]]; then
      error "Service template not found: ${TEMPLATE_DIR}/unsloth-studio.service"
    fi
    if ! command -v envsubst &>/dev/null; then
      error "envsubst not installed — install with: sudo apt-get install gettext-base"
    fi

    # Generate service file from template
    export UNSLOTH_STUDIO_USER UNSLOTH_STUDIO_HOME UNSLOTH_STUDIO_BIND UNSLOTH_STUDIO_PORT

    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    envsubst '${UNSLOTH_STUDIO_USER} ${UNSLOTH_STUDIO_HOME} ${UNSLOTH_STUDIO_BIND} ${UNSLOTH_STUDIO_PORT}' \
      < "${TEMPLATE_DIR}/unsloth-studio.service" \
      | sudo tee "${SERVICE_FILE}" > /dev/null

    sudo chmod 644 "${SERVICE_FILE}"
    success "Service file installed at ${SERVICE_FILE}"

    # Reload systemd, enable and start the service
    step "Reloading systemd daemon"
    sudo systemctl daemon-reload
    success "Daemon reloaded."

    step "Starting unsloth-studio service"
    sudo systemctl enable unsloth-studio
    sudo systemctl start unsloth-studio
    success "Service started and enabled."

    # Wait for service to be active
    step "Waiting for unsloth-studio to start"
    MAX_WAIT=60
    INTERVAL=3
    ELAPSED=0
    READY=false

    while [[ $ELAPSED -lt $MAX_WAIT ]]; do
      if sudo systemctl is-active unsloth-studio &>/dev/null; then
        READY=true
        break
      fi
      echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s ..."
      sleep $INTERVAL
      ELAPSED=$((ELAPSED + INTERVAL))
    done
    echo ""

    if [[ "$READY" == "true" ]]; then
      success "unsloth-studio service is running."
    else
      warn "Service did not become active within ${MAX_WAIT}s."
      warn "Check status and logs:"
      warn "  systemctl status unsloth-studio"
      warn "  journalctl -u unsloth-studio -n 50"
    fi
  fi
else
  info "Systemd service install disabled (set UNSLOTH_INSTALL_SERVICE=true to enable)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Unsloth setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""

# ── Unsloth Studio ──────────────────────────────────────────────────────
echo -e "${BOLD}Unsloth Studio${RESET}"
echo -e "  URL:          http://${UNSLOTH_STUDIO_BIND}:${UNSLOTH_STUDIO_PORT}"
echo -e "  Install dir:  ${UNSLOTH_STUDIO_HOME}"
echo -e "  Start:        unsloth studio -H ${UNSLOTH_STUDIO_BIND} -p ${UNSLOTH_STUDIO_PORT}"
echo -e "  Secure mode:  unsloth studio --secure -p ${UNSLOTH_STUDIO_PORT}"

if [[ "${UNSLOTH_INSTALL_SERVICE}" == "true" ]]; then
  echo -e "  Service:      ${SERVICE_FILE}"
fi
echo ""

# ── Unsloth Desktop (if installed) ──────────────────────────────────────
if [[ "${UNSLOTH_INSTALL_DESKTOP}" == "true" ]]; then
  echo -e "${BOLD}Unsloth Desktop${RESET}"
  echo -e "  Start from app menu or run: unsloth-desktop"
  echo ""
fi

# ── Common commands ─────────────────────────────────────────────────────
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Version:      unsloth --version"
echo -e "  Uninstall:    curl -fsSL https://unsloth.ai/install.sh | UNSLOTH_NO_TORCH=1 sh"

if [[ "${UNSLOTH_INSTALL_SERVICE}" == "true" ]]; then
  echo ""
  echo -e "  ${BOLD}Service management:${RESET}"
  echo -e "  Start:          sudo systemctl start unsloth-studio"
  echo -e "  Stop:           sudo systemctl stop unsloth-studio"
  echo -e "  Restart:        sudo systemctl restart unsloth-studio"
  echo -e "  Status:         sudo systemctl status unsloth-studio"
  echo -e "  Follow logs:    sudo journalctl -u unsloth-studio -f"
  echo -e "  Recent logs:    sudo journalctl -u unsloth-studio --no-pager -n 50"
fi
echo ""

if [[ "${UNSLOTH_INSTALL_DESKTOP}" == "true" && "${UNSLOTH_INSTALL_SERVICE}" == "true" ]]; then
  info "Unsloth Studio (with systemd service) and Desktop are installed."
elif [[ "${UNSLOTH_INSTALL_SERVICE}" == "true" ]]; then
  info "Unsloth Studio is installed and running as a systemd service."
elif [[ "${UNSLOTH_INSTALL_DESKTOP}" == "true" ]]; then
  info "Unsloth Studio and Desktop are installed."
else
  info "Unsloth Studio is installed. Open http://${UNSLOTH_STUDIO_BIND}:${UNSLOTH_STUDIO_PORT} in your browser."
fi
