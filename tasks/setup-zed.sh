#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-zed.sh — Install Zed Editor
# =============================================================================
#
# Description:
#   Installs the Zed editor on Linux using the official installation script.
#   Supports both stable and preview channels.
#
# Options:
#   --force     Reinstall even if Zed is already installed
#   --help      Display this help message
#
# Environment Variables (optional):
#   ZED_CHANNEL=preview - Install preview build instead of stable
#
# Usage:
#   ./setup-zed.sh              # Install stable version
#   ./setup-zed.sh --force      # Reinstall stable version
#   ZED_CHANNEL=preview ./setup-zed.sh  # Install preview version
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

# Configuration
: "${ZED_CHANNEL:=stable}"
ZED_INSTALL_SCRIPT_URL="https://zed.dev/install.sh"
ZED_BIN_NAME="zed"

# =============================================================================
# Help
# =============================================================================

show_help() {
  cat << 'EOF'
Usage: setup-zed.sh [OPTIONS]

Install Zed Editor on Linux.

Options:
  --force    Reinstall even if Zed is already installed
  --help     Display this help message

Environment Variables:
  ZED_CHANNEL=preview    Install preview build instead of stable

Examples:
  ./setup-zed.sh              # Install stable version
  ./setup-zed.sh --force      # Reinstall (force)
  ZED_CHANNEL=preview ./setup-zed.sh  # Install preview version

For more information, visit: https://zed.dev/
EOF
}

# =============================================================================
# Argument parsing
# =============================================================================

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

# =============================================================================
# Main
# =============================================================================

step "Setting up Zed Editor (channel: ${ZED_CHANNEL})"

# Check if Zed is already installed
if command -v "${ZED_BIN_NAME}" &>/dev/null; then
  if [[ "${FORCE_INSTALL}" == "true" ]]; then
    warn "Zed is already installed, --force specified, proceeding with reinstallation..."
  else
    info "Zed is already installed: ${ZED_BIN_NAME}"
    success "No installation needed"
    exit 0
  fi
fi

info "Installing Zed Editor..."

# Download installation script to temporary file
step "Downloading Zed installation script"
INSTALL_SCRIPT=$(mktempfile "zed-install.sh" || mktemp)
curl -fsSL "${ZED_INSTALL_SCRIPT_URL}" -o "${INSTALL_SCRIPT}"
chmod +x "${INSTALL_SCRIPT}"

# Verify script integrity (check for suspicious content)
step "Verifying installation script integrity"
if grep -qE '^exec\s' "${INSTALL_SCRIPT}" 2>/dev/null; then
  error "Installation script appears to contain direct execution — aborting for safety."
fi
if grep -qE 'eval\s' "${INSTALL_SCRIPT}" 2>/dev/null; then
  error "Installation script contains 'eval' — potential command injection detected."
fi
success "Script integrity verified."

# Execute installation script
step "Running Zed installation script"
if [[ "${ZED_CHANNEL}" == "preview" ]]; then
  ZED_CHANNEL=preview bash "${INSTALL_SCRIPT}"
else
  bash "${INSTALL_SCRIPT}"
fi

# Cleanup
rm -f "${INSTALL_SCRIPT}"

# Verify installation (~/.local/bin is not in the PATH of a non-login shell,
# e.g. when run through the orchestrator — accept either lookup location)
if command -v "${ZED_BIN_NAME}" &>/dev/null || [[ -x "${HOME}/.local/bin/${ZED_BIN_NAME}" ]]; then
  success "Zed installed successfully"
  info "Run 'zed' to start the editor"
else
  error "Zed installation failed - binary not found in PATH or ~/.local/bin"
fi