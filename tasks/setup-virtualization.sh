#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-virtualization.sh — Install or update libvirt and virt-manager
# =============================================================================
#
# Description:
#   Installs or updates libvirt (virtualization API) and virt-manager
#   (graphical VM manager) on Debian/Ubuntu-based systems.
#
# Environment Variables (optional):
#   VIRT_USERNAME - Username to add to libvirt group (default: current user)
#
# Usage:
#   ./setup-virtualization.sh
#   ./setup-virtualization.sh --help
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

Installs or updates libvirt (virtualization API) and virt-manager
(graphical VM manager) on Debian/Ubuntu-based systems, and adds the
configured user to the libvirt group. Uses sudo internally.

The QEMU package is chosen by host architecture: qemu-system-x86 on
x86_64, qemu-system-arm (plus qemu-efi-aarch64 firmware) on aarch64.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  VIRT_USERNAME   Username to add to the libvirt group (default: current user)
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
: "${VIRT_USERNAME:="${USER}"}"

# QEMU system emulator package matching the host architecture
ARCH="$(detect_arch)" || exit 1
case "${ARCH}" in
  amd64) QEMU_PACKAGE="qemu-system-x86" ;;
  arm64) QEMU_PACKAGE="qemu-system-arm" ;;
esac

# Packages for libvirt
declare -a LIBVIRT_PACKAGES=(
  libvirt-daemon
  libvirt-daemon-system
  libvirt-clients
  "${QEMU_PACKAGE}"
  bridge-utils
  # virt-runner's 'create --mount' (virtiofs host directory shares)
  virtiofsd
)

# aarch64 guests only boot via UEFI, so the firmware is required there
if [[ "${ARCH}" == "arm64" ]]; then
  LIBVIRT_PACKAGES+=(qemu-efi-aarch64)
fi

# Packages for virt-manager
declare -a VIRT_MANAGER_PACKAGES=(
  virt-manager
)

# =============================================================================
# Helper Functions
# =============================================================================

# Check if a package is installed (delegates to lib/helpers.sh)
is_package_installed() {
  is_apt_package_installed "$1"
}

# Get installed version of a package
get_package_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "unknown"
}

# Check if user is in libvirt group
is_user_in_libvirt_group() {
  groups "$1" 2>/dev/null | grep -q '\blibvirt\b'
}

# =============================================================================
# Main
# =============================================================================

step "Setting up Virtualization (libvirt + virt-manager)"

# Check for root privileges
if [[ "${EUID:-0}" -eq 0 ]]; then
  warn "Running as root. Some checks may be skipped."
fi

# -----------------------------------------------------------------------------
# Check existing installation
# -----------------------------------------------------------------------------
step "Checking existing installation"

LIBVIRT_INSTALLED=false
VIRT_MANAGER_INSTALLED=false

if is_package_installed "${QEMU_PACKAGE}"; then
  LIBVIRT_INSTALLED=true
  info "libvirt is installed (${QEMU_PACKAGE}: $(get_package_version "${QEMU_PACKAGE}"))"
else
  info "libvirt is not installed"
fi

if is_package_installed "virt-manager"; then
  VIRT_MANAGER_INSTALLED=true
  info "virt-manager is installed ($(get_package_version "virt-manager"))"
else
  info "virt-manager is not installed"
fi

# -----------------------------------------------------------------------------
# Update package lists
# -----------------------------------------------------------------------------
step "Updating package lists"
sudo apt update

# -----------------------------------------------------------------------------
# Install or update libvirt
# -----------------------------------------------------------------------------
if [[ "${LIBVIRT_INSTALLED}" == true ]]; then
  step "Updating libvirt packages"
  info "Upgrading existing libvirt packages..."
  sudo apt install -y --upgrade "${LIBVIRT_PACKAGES[@]}"
  success "libvirt packages updated"
else
  step "Installing libvirt packages"
  info "Installing: ${LIBVIRT_PACKAGES[*]}"
  sudo apt install -y "${LIBVIRT_PACKAGES[@]}"
  success "libvirt packages installed"
fi

# -----------------------------------------------------------------------------
# Install or update virt-manager
# -----------------------------------------------------------------------------
if [[ "${VIRT_MANAGER_INSTALLED}" == true ]]; then
  step "Updating virt-manager"
  info "Upgrading virt-manager..."
  sudo apt install -y --upgrade "${VIRT_MANAGER_PACKAGES[@]}"
  success "virt-manager updated"
else
  step "Installing virt-manager"
  info "Installing: ${VIRT_MANAGER_PACKAGES[*]}"
  sudo apt install -y "${VIRT_MANAGER_PACKAGES[@]}"
  success "virt-manager installed"
fi

# -----------------------------------------------------------------------------
# Ensure libvirt daemon is enabled and running
# -----------------------------------------------------------------------------
step "Configuring libvirt daemon"

if command -v libvirtd &>/dev/null; then
  # Enable libvirtd service
  if systemctl is-active --quiet libvirtd; then
    success "libvirtd is already running"
  else
    info "Starting libvirtd..."
    sudo systemctl enable libvirtd
    sudo systemctl start libvirtd
    success "libvirtd started and enabled"
  fi

  # Enable default libvirt networks
  step "Ensuring libvirt networks are configured"
  if sudo virsh net-list --all 2>/dev/null | grep -q "default"; then
    info "Default network already exists"
  else
    info "Defining default network..."
    sudo virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
  fi

  # Auto-start default network
  if sudo virsh net-autostart default &>/dev/null; then
    info "Default network set to autostart"
  fi

  # Start default network if not active
  if sudo virsh net-start default &>/dev/null; then
    info "Default network started"
  fi
else
  warn "libvirtd command not found - skipping daemon configuration"
fi

# -----------------------------------------------------------------------------
# Add user to libvirt group
# -----------------------------------------------------------------------------
step "Configuring user permissions for ${VIRT_USERNAME}"

if is_user_in_libvirt_group "${VIRT_USERNAME}"; then
  success "User '${VIRT_USERNAME}' is already in libvirt group"
else
  if [[ "${EUID:-0}" -eq 0 ]]; then
    sudo usermod -aG libvirt "${VIRT_USERNAME}"
    success "User '${VIRT_USERNAME}' added to libvirt group"
    warn "User must log out and back in for group changes to take effect"
  else
    sudo usermod -aG libvirt "${VIRT_USERNAME}"
    success "User '${VIRT_USERNAME}' added to libvirt group"
    warn "Please log out and log back in for group changes to take effect"
  fi
fi

# -----------------------------------------------------------------------------
# Final verification
# -----------------------------------------------------------------------------
step "Verification"

if command -v virt-manager &>/dev/null; then
  success "virt-manager is available at: $(command -v virt-manager)"
else
  warn "virt-manager command not found in PATH"
fi

if command -v virsh &>/dev/null; then
  success "virsh is available at: $(command -v virsh)"
else
  warn "virsh command not found in PATH"
fi

if is_package_installed "${QEMU_PACKAGE}"; then
  success "KVM modules are installed"
  # Check if kvm kernel modules are loaded
  if lsmod | grep -q "^kvm"; then
    info "KVM kernel modules are loaded"
  else
    warn "KVM kernel modules are not loaded - verify hardware virtualization is enabled"
  fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
success "Virtualization setup completed successfully!"
echo ""
info "Summary:"
info "  - libvirt daemon: $(is_package_installed "${QEMU_PACKAGE}" && echo 'installed' || echo 'not installed')"
info "  - virt-manager: $(is_package_installed 'virt-manager' && echo 'installed' || echo 'not installed')"
info "  - User '${VIRT_USERNAME}' in libvirt group: $(is_user_in_libvirt_group "${VIRT_USERNAME}" && echo 'yes' || echo 'no')"
echo ""
info "Run 'virt-manager' to start the graphical VM manager"
info "Run 'virsh list --all' to list all VMs"