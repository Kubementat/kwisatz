#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-samba.sh — Configure Samba file sharing
# =============================================================================
#
# Description:
#   Automates the installation and configuration of a Samba file sharing server.
#
# Environment Variables (optional):
#   BASE_SHARE_PATH      - Root directory for Samba shares (default: /home/samba)
#   SAMBA_SHARE_NAME     - Name of the share (default: shared)
#   SAMBA_USER           - System user for Samba auth (default: sambauser)
#   DEVELOPER_GROUP_NAME - Group with share access (default: devs)
#
# Usage:
#   ./setup-samba.sh
#   ./setup-samba.sh --help
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

Installs and configures a Samba file sharing server: creates the share
directory, system user and developer group, installs Samba, and adds the
share definition to /etc/samba/smb.conf. Uses sudo internally.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  BASE_SHARE_PATH       Root directory for Samba shares (default: /home/samba)
  SAMBA_SHARE_NAME      Name of the share (default: shared)
  SAMBA_USER            System user for Samba auth (default: sambauser)
  DEVELOPER_GROUP_NAME  Group with share access (default: devs)
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
: "${BASE_SHARE_PATH:=/home/samba}"
: "${SAMBA_SHARE_NAME:=shared}"
: "${SAMBA_USER:=sambauser}"
: "${DEVELOPER_GROUP_NAME:=devs}"
SHARE_PATH="${BASE_SHARE_PATH}/${SAMBA_SHARE_NAME}"
SMB_CONF="/etc/samba/smb.conf"

# Validate configuration values to prevent injection in config files
# Share name: alphanumeric and underscores only
if [[ ! "${SAMBA_SHARE_NAME}" =~ ^[a-zA-Z0-9_]+$ ]]; then
  error "SAMBA_SHARE_NAME contains invalid characters. Only alphanumeric and underscores allowed."
fi

# Share path: must be absolute and not contain dangerous characters
# Check: starts with /, no spaces, no shell metacharacters
if [[ ! "${SHARE_PATH}" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
  error "SHARE_PATH must be an absolute path containing only alphanumeric, underscore, dot, slash, or hyphen."
fi

# Samba user: alphanumeric and underscores only
if [[ ! "${SAMBA_USER}" =~ ^[a-zA-Z0-9_]+$ ]]; then
  error "SAMBA_USER contains invalid characters. Only alphanumeric and underscores allowed."
fi

# =============================================================================
# Main
# =============================================================================

step "Setting up Samba file sharing"

# Check if already configured
if grep -q "^\[${SAMBA_SHARE_NAME}\]" "${SMB_CONF}" 2>/dev/null; then
  success "Samba share '${SAMBA_SHARE_NAME}' already configured in ${SMB_CONF}"
  info "Share path: ${SHARE_PATH}"
  exit 0
fi

info "Configuring Samba..."

# Create developer group (idempotent)
if ! getent group "${DEVELOPER_GROUP_NAME}" >/dev/null 2>&1; then
  step "Creating developer group '${DEVELOPER_GROUP_NAME}'"
  sudo groupadd "${DEVELOPER_GROUP_NAME}"
else
  info "Group '${DEVELOPER_GROUP_NAME}' already exists"
fi

# Create Samba user (idempotent)
if ! id -u "${SAMBA_USER}" >/dev/null 2>&1; then
  step "Creating Samba user '${SAMBA_USER}'"
  sudo adduser --no-create-home --disabled-password --gecos "" "${SAMBA_USER}"
else
  info "User '${SAMBA_USER}' already exists"
fi

# Add users to developer group (idempotent)
step "Adding users to group '${DEVELOPER_GROUP_NAME}'"
sudo usermod -aG "${DEVELOPER_GROUP_NAME}" "${SAMBA_USER}"
sudo usermod -aG "${DEVELOPER_GROUP_NAME}" "${USER}"

# Create share directory
step "Creating share directory"
sudo mkdir -p "${SHARE_PATH}"
sudo chown "${SAMBA_USER}:${DEVELOPER_GROUP_NAME}" "${SHARE_PATH}"
sudo chmod -R 770 "${SHARE_PATH}"

# Install Samba
step "Installing Samba"
sudo apt update
sudo apt install -y samba

# Enable and start service
step "Enabling and starting Samba service"
sudo systemctl enable smbd
sudo systemctl start smbd

# Backup config
step "Backing up Samba configuration"
sudo cp "${SMB_CONF}" "${SMB_CONF}.backup"

# Add share definition from template (quoted heredoc → sed substitution)
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/samba"
step "Adding share definition to ${SMB_CONF}"
# Render template with sed (same as original quoted heredoc + sed pipeline)
sed \
  -e "s/\${SAMBA_SHARE_NAME}/${SAMBA_SHARE_NAME}/g" \
  -e "s|\${SHARE_PATH}|${SHARE_PATH}|g" \
  "${TEMPLATE_DIR}/share.conf.template" | sudo tee -a "${SMB_CONF}" > /dev/null

# Restart Samba
sudo systemctl restart smbd

# Set Samba password — non-interactive. The secret lives in a .env under
# the share root (mode 600) so re-runs never rotate a credential, per
# "Secrets and templating" in specification/project/conventions.md.
step "Setting Samba password for user '${SAMBA_USER}'"
SMB_ENV_FILE="${BASE_SHARE_PATH}/.samba.env"
if sudo pdbedit -L | grep -q "^${SAMBA_USER}:"; then
  info "Samba password already set for '${SAMBA_USER}'"
else
  samba_pass="${SAMBA_PASSWORD:-}"
  [[ -n "${samba_pass}" ]] || samba_pass="$(env_file_get "${SMB_ENV_FILE}" SAMBA_PASSWORD 2>/dev/null || true)"
  if [[ -z "${samba_pass}" ]]; then
    samba_pass="$(openssl rand -base64 12)"
    info "Generated a new Samba password (see ${SMB_ENV_FILE})"
  fi
  printf 'SAMBA_PASSWORD=%s\n' "${samba_pass}" | env_file_write "${SMB_ENV_FILE}"
  printf '%s\n%s\n' "${samba_pass}" "${samba_pass}" | sudo smbpasswd -a -s "${SAMBA_USER}"
fi

success "Samba configured successfully"
info "Share path: ${SHARE_PATH}"
printf "Access it on the network as: \\\\\\\\%s\\\\%s\n" "$(hostname -I | awk '{print $1}')" "${SAMBA_SHARE_NAME}"