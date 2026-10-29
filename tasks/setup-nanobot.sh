#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-nanobot.sh — Install Nanobot
# =============================================================================
#
# Description:
#   Sets up the nanobot environment by cloning the repository, building Docker
#   images, and initializing the nanobot container.
#
# Environment Variables (optional):
#   NANOBOT_TARGET_REPO_DIRECTORY - Clone destination (default: /srv/nanobot)
#   NANOBOT_VERSION               - Git tag to check out, or latest
#                                   (default: versions.yml key nanobot)
#
# Usage:
#   ./setup-nanobot.sh
#   NANOBOT_TARGET_REPO_DIRECTORY=/opt/nanobot ./setup-nanobot.sh
#   ./setup-nanobot.sh --help
# =============================================================================

set -euo pipefail

# Determine script directory and source shared library
SCRIPT_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_PATH="$(realpath "${SCRIPT_REPO_DIR}/../lib/helpers.sh")"

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

Sets up the nanobot environment by cloning the repository (HKUDS/nanobot),
building Docker images, and initializing the nanobot container.

${BOLD}Options:${RESET}
  -h, --help     Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  NANOBOT_TARGET_REPO_DIRECTORY  Clone destination (default: /srv/nanobot)
  NANOBOT_VERSION                Git tag to check out, or latest for the newest
                                 tag (default: $(kw_version nanobot))

${BOLD}Note:${RESET} A restart_nanobot.sh script (supports --rebuild) is created
in the target directory for managing the container.
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
: "${NANOBOT_TARGET_REPO_DIRECTORY:=/srv/nanobot}"
NANOBOT_VERSION="${NANOBOT_VERSION:-$(kw_version nanobot)}"
NANOBOT_SHARED_DIRECTORY="$HOME/.nanobot"
DOCKERFILE_EXTEND_SRC="${SCRIPT_REPO_DIR}/../templates/nanobot/Dockerfile.extend"

# =============================================================================
# Main
# =============================================================================

step "Setting up Nanobot"

# Pre-flight
if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Please install Docker first."
fi

success "Docker is available"

# Clone or update repository
if [[ ! -d "${NANOBOT_TARGET_REPO_DIRECTORY}" ]]; then
  step "Cloning nanobot repository"
  sudo mkdir -p "${NANOBOT_TARGET_REPO_DIRECTORY}"
  sudo chown "${USER}:${USER}" "${NANOBOT_TARGET_REPO_DIRECTORY}"
  git clone https://github.com/HKUDS/nanobot "${NANOBOT_TARGET_REPO_DIRECTORY}"
else
  step "Updating existing nanobot repository"
  git -C "${NANOBOT_TARGET_REPO_DIRECTORY}" fetch --tags
fi

# Checkout the pinned tag ("latest": the newest tag)
if [[ "${NANOBOT_VERSION}" == "latest" ]]; then
  NANOBOT_VERSION=$(git -C "${NANOBOT_TARGET_REPO_DIRECTORY}" describe --tags \
    "$(git -C "${NANOBOT_TARGET_REPO_DIRECTORY}" rev-list --tags --max-count=1)")
fi
info "Checking out: ${NANOBOT_VERSION}"
git -C "${NANOBOT_TARGET_REPO_DIRECTORY}" checkout "${NANOBOT_VERSION}"

pushd "${NANOBOT_TARGET_REPO_DIRECTORY}"

# Create restart script from template (static quoted heredoc → plain cp)
TEMPLATE_DIR="${SCRIPT_REPO_DIR}/../templates/nanobot"
step "Creating restart script"
cp "${TEMPLATE_DIR}/restart_nanobot.sh" restart_nanobot.sh
chmod +x restart_nanobot.sh

# Build images
step "Building nanobot Docker image"
docker build -t nanobot .

# Copy Dockerfile.extend
if [[ ! -f "${DOCKERFILE_EXTEND_SRC}" ]]; then
  error "Dockerfile.extend not found at ${DOCKERFILE_EXTEND_SRC}"
fi
info "Copying Dockerfile.extend"
cp "${DOCKERFILE_EXTEND_SRC}" Dockerfile.extend

step "Building nanobot-extended image"
docker build -f Dockerfile.extend -t nanobot-extended .

# Write docker-compose.override.yml from template (static quoted heredoc → plain cp)
step "Writing docker-compose.override.yml"
cp "${TEMPLATE_DIR}/docker-compose.override.yml" docker-compose.override.yml

# Initialize
step "Initializing nanobot"
docker compose run --rm nanobot-cli onboard

popd

# Summary
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
success "Nanobot setup complete!"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo "Source:     ${NANOBOT_TARGET_REPO_DIRECTORY}"
echo "Config:     ${NANOBOT_SHARED_DIRECTORY}/config.json"
echo ""
echo "Next steps:"
echo "  cd ${NANOBOT_TARGET_REPO_DIRECTORY}"
echo "  ./restart_nanobot.sh"
echo ""
echo "Test:"
echo "  docker compose -f ${NANOBOT_TARGET_REPO_DIRECTORY}/docker-compose.yml run --rm nanobot-cli agent -m 'Hello!'"