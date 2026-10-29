#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-basics.sh — Install essential development tools
# =============================================================================
#
# Description:
#   Installs essential system packages and tools for development environment.
#
# Environment Variables (optional):
#   NVM_VERSION        - NVM version to install (default: versions.yml key nvm)
#   NVM_DIR            - NVM installation directory (default: $HOME/.nvm)
#   HF_CLI_INSTALL_SHA256   - expected SHA-256 of https://hf.co/cli/install.sh
#                             (optional; the digest is always logged)
#   HERDR_INSTALL_SHA256    - expected SHA-256 of https://herdr.dev/install.sh
#                             (optional; the digest is always logged)
#
# Usage:
#   ./setup-basics.sh
#   ./setup-basics.sh --help
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

Installs essential system packages and tools for the development environment
(apt packages, uv, NVM, huggingface-cli, herdr, hunk). Uses sudo internally.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  NVM_VERSION     NVM version to install (default: $(kw_version nvm | sed "s/^v//"))
  NVM_DIR         NVM installation directory (default: $HOME/.nvm)
  HF_CLI_INSTALL_SHA256   Pin the SHA-256 of the huggingface-cli installer
                          (default: unset — the digest is logged every run)
  HERDR_INSTALL_SHA256    Pin the SHA-256 of the herdr installer
                          (default: unset — the digest is logged every run)
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
NVM_VERSION="${NVM_VERSION:-$(kw_version nvm | sed "s/^v//")}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# Installer checksums (ticket improvements-2/17). Each installer is downloaded to
# a file, its SHA-256 logged, and only then executed (lib fetch_and_run) — never
# piped straight from curl into bash.
#
# Both upstreams publish a checksum for the *release artifact* their installer
# downloads (herdr: a sha256 in its release manifest; lmstudio: a .sha512 next to
# the AppImage), but no digest for the installer script itself — verified
# 2026-08-31: https://hf.co/cli/install.sh.sha256 -> 404, and the .sha256 paths
# below serve the site's HTML, not a digest:
#   https://hf.co/cli/install.sh            (pip/venv based, no published digest)
#   https://herdr.dev/install.sh            (no published digest)
# So the defaults stay empty (the run log records the digest every run) and an
# operator who has reviewed an installer can pin it, e.g.
#   HF_CLI_INSTALL_SHA256=<64 hex> ./setup-basics.sh
# Update deliberately: re-download the installer and compare the logged digest.
: "${HF_CLI_INSTALL_SHA256:=}"
: "${HERDR_INSTALL_SHA256:=}"

# Packages to install
declare -a APT_PACKAGES=(
  curl
  gettext-base
  bat
  git
  python3-pip
  python3-full
  jq
  yq
  net-tools
  wget
  gpg
  netcat-openbsd
  libfuse2
  nvtop
  radeontop
  btop
  htop
  tmux
  openssl
  spirv-headers
)

# =============================================================================
# Main
# =============================================================================

step "Setting up development basics"

# Update package lists
step "Updating package lists"
sudo apt update

# Install apt packages
step "Installing packages"
for pkg in "${APT_PACKAGES[@]}"; do
  if is_apt_package_installed "$pkg"; then
    info "$pkg already installed"
  else
    info "Installing $pkg"
    sudo apt install -y "$pkg"
  fi
done

# Install uv (Python package manager)
step "Installing uv"
if command -v uv &>/dev/null; then
  success "uv already installed"
else
  info "Installing uv..."
  pip install uv --break-system-packages
fi

# Install NVM
step "Installing NVM v${NVM_VERSION}"
if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
  success "NVM already installed at ${NVM_DIR}"
else
  info "Installing NVM..."
  # Deliberately still a download-piped-into-a-shell here (ticket
  # improvements-2/17): the URL is pinned to an exact nvm release tag
  # (NVM_VERSION), so the bytes are immutable and changing them requires an
  # explicit version bump — the property the hf.co/cli, herdr.dev and
  # lmstudio.ai installers did NOT have, and which fetch_and_run now provides.
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | bash
fi

# Add NVM configuration to ~/.profile
step "Configuring NVM in ~/.profile"
PROFILE="$HOME/.profile"
NVM_CONFIG="
# NVM configuration
export NVM_DIR=\"${NVM_DIR}\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\"  # This loads nvm
[ -s \"\$NVM_DIR/bash_completion\" ] && \\. \"\$NVM_DIR/bash_completion\"  # This loads nvm bash_completion
"

if [[ ! -s "${PROFILE}" ]] || ! grep -q "export NVM_DIR=" "${PROFILE}"; then
  echo "${NVM_CONFIG}" >> "${PROFILE}"
  info "NVM configuration added to ${PROFILE}"
else
  info "NVM configuration already present in ${PROFILE}"
fi

# Load NVM into current session
# shellcheck disable=SC1091
if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
  export NVM_DIR
  \. "${NVM_DIR}/nvm.sh"
  info "NVM loaded into current session"
fi

# Configure stable nvm
info "Configuring stable node version for nvm"
nvm install stable
nvm use stable

# Install huggingface-cli
step "Installing huggingface-cli"
if command -v hf &>/dev/null; then
  success "huggingface-cli already installed"
else
  info "Installing huggingface-cli..."
  fetch_and_run "https://hf.co/cli/install.sh" "${HF_CLI_INSTALL_SHA256}"
fi

# Install herdr
step "Installing herdr"
if command -v herdr &>/dev/null; then
  success "herdr already installed. Updating version to latest..."
  herdr update
else
  info "Installing herdr..."
  fetch_and_run "https://herdr.dev/install.sh" "${HERDR_INSTALL_SHA256}"
fi

# Install hunk
step "Installing hunk"
if command -v hunk &>/dev/null; then
  success "hunk already installed. Updating to latest..."
  npm update -g hunkdiff
else
  info "Installing hunk..."
  npm i -g hunkdiff
fi

success "Development basics installed successfully"
