#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-deepseek-harness.sh — Install DeepSeek Harness (dsh)
# =============================================================================
#
# Description:
#   Installs and configures DeepSeek Harness — an open-source agent harness
#   from DeepSeek AI built on a plugin-first architecture.
#   Ensures Node.js 22.19+ is installed and then installs dsh globally.
#
# Environment Variables (optional):
#   NVM_DIR        - NVM directory path (default: $HOME/.nvm)
#   DSH_NODE_VERSION - Node.js version to install (default: 22)
#
# Usage:
#   ./setup-deepseek-harness.sh
#   ./setup-deepseek-harness.sh --help
#
# Requirements:
#   - Node.js ^22.19.0 or >=24
#   - pnpm 11.7.0+ (via Corepack, for source builds)
#
# After install:
#   Run 'dsh web' to start the Web UI at http://127.0.0.1:3080
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

# =============================================================================
# USAGE / HELP
# =============================================================================

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs and configures DeepSeek Harness (dsh) — an open-source agent harness
from DeepSeek AI. Ensures Node.js 22.19+ is installed (via NVM) and then
installs dsh globally.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  NVM_DIR            NVM directory path (default: $HOME/.nvm)
  DSH_NODE_VERSION   Node.js version to install (default: 22)

${BOLD}After install:${RESET} run 'dsh web' to start the Web UI at http://127.0.0.1:3080
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

# Configuration
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
DSH_NODE_VERSION="${DSH_NODE_VERSION:-22}"

# =============================================================================
# Main
# =============================================================================

step "Setting up DeepSeek Harness"

# Load NVM if not already loaded
if ! command -v nvm &>/dev/null; then
  step "Loading NVM"
  export NVM_DIR
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
fi

# Check if nvm is available now
if ! command -v nvm &>/dev/null; then
  error "NVM is not installed. Please install NVM first."
fi

# Install required Node.js version
step "Installing Node.js ${DSH_NODE_VERSION}"
nvm install "${DSH_NODE_VERSION}"
nvm use "${DSH_NODE_VERSION}"
nvm alias default "${DSH_NODE_VERSION}"

# Verify Node.js version meets minimum requirement
NODE_VERSION=$(node --version | sed 's/v//')
NODE_MAJOR=$(echo "${NODE_VERSION}" | cut -d. -f1)
if [[ "${NODE_MAJOR}" -lt 22 ]]; then
  error "Node.js ${NODE_MAJOR} is too old. DeepSeek Harness requires Node.js ^22.19.0 or >=24."
fi
info "Node.js ${NODE_VERSION} is available"

# Check if dsh is already installed
if command -v dsh &>/dev/null; then
  info "DeepSeek Harness is already installed: $(dsh --version 2>/dev/null || echo 'version unknown')"
  info "Updating DeepSeek Harness..."
else
  step "Installing DeepSeek Harness"
fi

npm install -g "@deepseek-ai/dsh@${DSH_VERSION:-$(kw_version deepseek-harness)}"

success "DeepSeek Harness installed successfully"
info "Run 'dsh web' to start the Web UI at http://127.0.0.1:3080"
