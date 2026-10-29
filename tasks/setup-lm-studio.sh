#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-lm-studio.sh — Install LM Studio
# =============================================================================
#
# Description:
#   Installs LM Studio on Linux systems with AppImage and optionally installs
#   the llmster CLI tool (lms).
#
# Environment Variables (optional):
#   LM_STUDIO_VERSION       - Specific version (default: auto-detect latest)
#   INSTALL_LLMSTER_ENABLED - Install llmster CLI (default: true)
#   LMSTUDIO_INSTALL_SHA256 - expected SHA-256 of https://lmstudio.ai/install.sh
#                             (optional; the digest is always logged)
#
# Usage:
#   ./setup-lm-studio.sh
#   LM_STUDIO_VERSION=0.4.5-2 ./setup-lm-studio.sh
#   INSTALL_LLMSTER_ENABLED=false ./setup-lm-studio.sh
#   ./setup-lm-studio.sh --force   # Re-install even if already installed
#   ./setup-lm-studio.sh --help    # Show help and exit
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

Installs LM Studio on Linux systems with AppImage and optionally installs
the llmster CLI tool (lms).

${BOLD}Options:${RESET}
  --force     Re-install even if already installed
  -h, --help  Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  LM_STUDIO_VERSION       Specific version (default: auto-detect latest)
  INSTALL_LLMSTER_ENABLED Install llmster CLI (default: true)
  LMSTUDIO_INSTALL_SHA256 Pin the SHA-256 of the llmster installer
                          (default: unset — the digest is logged every run)
  DESKTOP_LINK_TARGET_PATH  Desktop shortcut location
                            (default: $HOME/Desktop/LM-Studio.desktop)
  START_SCRIPT_TARGET_PATH  Start script location (default: $HOME/lmstudio)
  APP_IMAGE_TARGET_PATH     AppImage location (default: $HOME/lmstudio_bin)
  APP_IMAGE_BACKUP_PATH     Backup location for replaced AppImage
                            (default: $HOME/lmstudio_bin_backup)
EOF
}

# Parse command-line arguments
FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown argument: $1 (see --help)"
      ;;
  esac
done

# Configuration
: "${INSTALL_LLMSTER_ENABLED:=true}"

# Checksum of the llmster installer (ticket improvements-2/17): it is downloaded
# to a file, its SHA-256 logged, and only then executed — never piped from curl
# into bash. Upstream publishes a .sha512 next to the AppImage the installer
# fetches, but no digest for the installer script itself (verified 2026-08-31:
# https://lmstudio.ai/install.sh.sha256 serves the website HTML, not a digest),
# so the default stays empty and the run log records the digest. Review the
# installer and pin it deliberately if you want it enforced:
#   LMSTUDIO_INSTALL_SHA256=<64 hex> ./setup-lm-studio.sh
: "${LMSTUDIO_INSTALL_SHA256:=}"

# versions.yml key lm-studio (datasource custom: the vendor site has no API
# Renovate knows). Left at this default, the run installs the latest release.
DEFAULT_LM_STUDIO_VERSION="$(kw_version lm-studio)"
: "${LM_STUDIO_VERSION:=${DEFAULT_LM_STUDIO_VERSION}}"

DESKTOP_LINK_TARGET_PATH="${DESKTOP_LINK_TARGET_PATH:-$HOME/Desktop/LM-Studio.desktop}"
START_SCRIPT_TARGET_PATH="${START_SCRIPT_TARGET_PATH:-$HOME/lmstudio}"
APP_IMAGE_TARGET_PATH="${APP_IMAGE_TARGET_PATH:-$HOME/lmstudio_bin}"
APP_IMAGE_BACKUP_PATH="${APP_IMAGE_BACKUP_PATH:-$HOME/lmstudio_bin_backup}"

# Architecture detection
LATEST_URL_AMD64="https://lmstudio.ai/download/latest/linux/x64"
LATEST_URL_ARM64="https://lmstudio.ai/download/latest/linux/arm64"

ARCH=$(uname -m)
case "${ARCH}" in
  x86_64)
    ARCH_TYPE="x64"
    LATEST_URL="${LATEST_URL_AMD64}"
    ;;
  aarch64|arm64)
    ARCH_TYPE="arm64"
    LATEST_URL="${LATEST_URL_ARM64}"
    ;;
  *)
    error "Unsupported architecture: ${ARCH}. Only amd64 and arm64 are supported."
    ;;
esac

# =============================================================================
# Main
# =============================================================================

# Check if LM Studio is already installed
LM_STUDIO_ALREADY_INSTALLED=false
if [[ -f "${APP_IMAGE_TARGET_PATH}" ]]; then
  LM_STUDIO_ALREADY_INSTALLED=true
  info "LM Studio AppImage already installed at: ${APP_IMAGE_TARGET_PATH}"
else
  info "LM Studio AppImage not found at: ${APP_IMAGE_TARGET_PATH}"
fi

# Check if llmster (lms) is already installed
LLMSTER_ALREADY_INSTALLED=false
if command -v lms &>/dev/null; then
  LLMSTER_ALREADY_INSTALLED=true
  info "llmster (lms) already installed: $(lms --version 2>/dev/null || echo 'unknown')"
else
  info "llmster (lms) not found"
fi

if [[ "${FORCE}" == "true" ]]; then
  info "--force flag set, will re-install even if already present"
fi

if [[ "${FORCE}" == "true" || "${LM_STUDIO_ALREADY_INSTALLED}" == "false" ]]; then
  step "Setting up LM Studio"
  info "Detected architecture: ${ARCH} (${ARCH_TYPE})"

  # Auto-detect version if using default
  if [[ "${LM_STUDIO_VERSION}" == "${DEFAULT_LM_STUDIO_VERSION}" ]]; then
    step "Detecting latest version"
    FINAL_URL=$(curl -sI -L "${LATEST_URL}" -o /dev/null -w '%{url_effective}')
    LM_STUDIO_VERSION=$(echo "${FINAL_URL}" | grep -oP -m1 '[\d]+\.[\d]+\.[\d]+-[\d]+' | head -1)
    info "Latest version: ${LM_STUDIO_VERSION}"
  fi

  SOURCE_URL="https://installers.lmstudio.ai/linux/${ARCH_TYPE}/${LM_STUDIO_VERSION}/LM-Studio-${LM_STUDIO_VERSION}-${ARCH_TYPE}.AppImage"
  info "Download URL: ${SOURCE_URL}"

  # Create start script
  if [[ -f "${START_SCRIPT_TARGET_PATH}" ]]; then
    info "Start script exists at: ${START_SCRIPT_TARGET_PATH}"
  else
    step "Creating start script"
    cat > "${START_SCRIPT_TARGET_PATH}" << 'EOF'
#!/usr/bin/env bash
cd "$HOME"
./lmstudio_bin --no-sandbox
EOF
  fi

  chmod +x "${START_SCRIPT_TARGET_PATH}"

  # Create desktop link
  if [[ -f "${DESKTOP_LINK_TARGET_PATH}" ]]; then
    info "Desktop link exists at: ${DESKTOP_LINK_TARGET_PATH}"
  else
    step "Creating desktop shortcut"
    cat > "${DESKTOP_LINK_TARGET_PATH}" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Terminal=false
Name=LM Studio
Comment=LM Studio
Icon=utilities-terminal
Exec=${START_SCRIPT_TARGET_PATH}
EOF
  fi

  chmod +x "${DESKTOP_LINK_TARGET_PATH}"

  # Handle existing binary
  if [[ -f "${APP_IMAGE_TARGET_PATH}" ]]; then
    info "Existing binary found: ${APP_IMAGE_TARGET_PATH}"
    info "Backing up to: ${APP_IMAGE_BACKUP_PATH}"
    mv "${APP_IMAGE_TARGET_PATH}" "${APP_IMAGE_BACKUP_PATH}"
  fi

  # Download AppImage
  step "Downloading LM Studio v${LM_STUDIO_VERSION}"
  wget --output-document "${APP_IMAGE_TARGET_PATH}" "${SOURCE_URL}"
  chmod +x "${APP_IMAGE_TARGET_PATH}"
  success "Installed version: ${LM_STUDIO_VERSION}"
else
  success "LM Studio already installed, skipping (use --force to reinstall)"
fi

# Install llmster CLI
if [[ "${INSTALL_LLMSTER_ENABLED}" == "true" ]]; then
  if [[ "${FORCE}" == "true" || "${LLMSTER_ALREADY_INSTALLED}" == "false" ]]; then
    step "Installing llmster CLI"
    # Don't fail script on errors for this command
    set +e
    fetch_and_run "https://lmstudio.ai/install.sh" "${LMSTUDIO_INSTALL_SHA256}" \
      || warn "llmster installer did not run — see the download/checksum messages above"
    if command -v lms &>/dev/null; then
      info "lms version: $(lms --version 2>/dev/null || echo 'unknown')"
    fi
    set -e
  else
    info "llmster (lms) already installed, skipping (use --force to reinstall)"
  fi
else
  info "llmster install disabled"
fi

success "LM Studio setup complete"
info "Run '${START_SCRIPT_TARGET_PATH}' to start the application"