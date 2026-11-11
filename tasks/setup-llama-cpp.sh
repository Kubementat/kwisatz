#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-llama-cpp.sh — Install llama.cpp
# =============================================================================
#
# Description:
#   Installs llama.cpp on Ubuntu with auto or manual GPU backend selection.
#   Supports: NVIDIA (CUDA) | AMD (Vulkan) | CPU fallback
#
# Options:
#   --nvidia          Force NVIDIA CUDA backend
#   --amd             Force AMD Vulkan backend
#   --cpu             Force CPU-only build
#   --dir <path>      Install source to <path>
#   --jobs <n>        Parallel build jobs
#   --force           Reinstall even if already present
#   --check           Check installation status and exit
#   --help            Show help
#
# Environment Variables (optional):
#   LLAMA_CPP_REF - source ref to build (default: versions.yml key llama-cpp);
#                   "latest" resolves at run time to the most recently
#                   published tag; any other tag/branch name is built as-is
#   LLAMA_CPP_REPO_URL - upstream git URL to clone/fetch from
#                        (default: https://github.com/ggml-org/llama.cpp)
#
# Usage:
#   ./setup-llama-cpp.sh              # auto-detect GPU, skip if installed
#   ./setup-llama-cpp.sh --check      # check status
#   ./setup-llama-cpp.sh --force --nvidia  # force CUDA build
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
INSTALL_DIR="${INSTALL_DIR:-/opt/llama.cpp}"
# Canonical upstream repo. The project moved from github.com/ggerganov/llama.cpp
# to ggml-org/llama.cpp (the old URL no longer serves the repo).
LLAMA_CPP_REPO_URL="${LLAMA_CPP_REPO_URL:-https://github.com/ggml-org/llama.cpp}"
# Source ref to build. The default is the build tag pinned in versions.yml (key
# llama-cpp, kept current by Renovate), so a run is reproducible. "latest"
# resolves at run time to the most recently published tag in the source repo
# (newest tag-creation date, via `git for-each-ref --sort=-creatordate
# refs/tags` after the tag fetch); any other tag or branch name is built as-is.
LLAMA_CPP_REF="${LLAMA_CPP_REF:-$(kw_version llama-cpp)}"
# Refs reach git as --branch/checkout arguments — keep them ref-shaped so a stray
# option (a leading '-') or shell metacharacter can never reach git.
if [[ ! "${LLAMA_CPP_REF}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
  error "LLAMA_CPP_REF '${LLAMA_CPP_REF}' is not a valid tag/branch name (letters, digits, dot, underscore, slash, hyphen; must not start with '-')"
fi
BACKEND=""          # nvidia | amd | cpu
FORCE=0
CHECK_ONLY=0
JOBS=$(nproc)

# Parse arguments
usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

${BOLD}Options:${RESET}
  --nvidia          Force NVIDIA CUDA backend
  --amd             Force AMD Vulkan backend
  --cpu             Force CPU-only build
  --dir <path>      Install source to <path>  (default: /opt/llama.cpp)
  --jobs <n>        Parallel build jobs        (default: nproc)
  --force           Reinstall even if llama.cpp is already present
  --check           Check installation status and exit
  --help            Show this help

${BOLD}Environment variables${RESET} (all optional):
  LLAMA_CPP_REF     Source ref to build. "latest" builds the most recently
                    published tag, resolved at run time; any other tag or
                    branch name is built as-is.
                    (default: $(kw_version llama-cpp))
  LLAMA_CPP_REPO_URL Upstream git URL to clone/fetch from.
                     (default: https://github.com/ggml-org/llama.cpp)
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nvidia)         BACKEND="nvidia" ;;
    --amd)            BACKEND="amd"    ;;
    --cpu)            BACKEND="cpu"    ;;
    --force)          FORCE=1          ;;
    --check)          CHECK_ONLY=1     ;;
    --dir)            shift; INSTALL_DIR="$1" ;;
    --jobs)           shift; JOBS="$1"        ;;
    --help|-h)        usage ;;
    *) error "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

# Sanity checks
[[ "$(id -u)" -eq 0 ]] && warn "Running as root – not recommended."
if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu. Continuing anyway…"
fi

# Installation detection
LLAMA_BINARY=""
LLAMA_VERSION=""
LLAMA_FOUND_VIA=""

SEARCH_PATHS=(
  "${INSTALL_DIR}/build/bin"
  "${HOME}/.local/bin"
  "/usr/local/bin"
  "/usr/bin"
  "/opt/llama.cpp/build/bin"
)

IFS=':' read -ra _PATH_DIRS <<< "${PATH}"
for _d in "${_PATH_DIRS[@]}"; do
  SEARCH_PATHS+=("${_d}")
done

find_llama_binary() {
  for dir in "${SEARCH_PATHS[@]}"; do
    for bin in llama-cli llama-server llama-bench llama-run; do
      if [[ -x "${dir}/${bin}" ]]; then
        LLAMA_BINARY="${dir}/${bin}"
        LLAMA_FOUND_VIA="${dir}"
        LLAMA_VERSION=$("${LLAMA_BINARY}" --version 2>&1 | head -1 || true)
        return 0
      fi
    done
  done
  return 1
}

print_found_status() {
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║     llama.cpp is already installed ✓         ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Binary found:${RESET}  ${LLAMA_BINARY}"
  echo -e "  ${BOLD}Location:${RESET}      ${LLAMA_FOUND_VIA}"
  [[ -n "$LLAMA_VERSION" ]] && echo -e "  ${BOLD}Version:${RESET}       ${LLAMA_VERSION}"
  echo ""
  echo -e "  ${BOLD}Binaries in ${LLAMA_FOUND_VIA}:${RESET}"
  for bin in llama-cli llama-server llama-bench llama-run llama-quantize llama-perplexity; do
    if [[ -x "${LLAMA_FOUND_VIA}/${bin}" ]]; then
      echo -e "    ${GREEN}✓${RESET} ${bin}"
    fi
  done
  echo ""
}

# =============================================================================
# Main
# =============================================================================

step "Checking for existing llama.cpp installation"

if find_llama_binary; then
  print_found_status

  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    info "Run with --force to reinstall, or --check just checks status."
    exit 0
  fi

  if [[ "${FORCE}" -eq 0 ]]; then
    warn "Nothing to do. Use --force to reinstall anyway."
    exit 0
  fi

  warn "--force specified – proceeding with reinstall."
else
  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    echo ""
    warn "llama.cpp does not appear to be installed."
    info "Run the script without --check to install it."
    exit 0
  fi
  info "No existing installation found – proceeding."
fi

# Ensure install directory exists with proper ownership
if [[ ! -d "${INSTALL_DIR}" ]]; then
  sudo mkdir -p "${INSTALL_DIR}"
fi
# Ensure the directory is owned by a group all users can access (needed for /opt)
if [[ "${INSTALL_DIR}" != "${HOME}"* ]]; then
  sudo chown -R root:users "${INSTALL_DIR}" 2>/dev/null || true
  sudo chmod -R g+rw "${INSTALL_DIR}" 2>/dev/null || true
  sudo find "${INSTALL_DIR}" -type d -exec chmod g+s {} + 2>/dev/null || true
fi

# Auto-detect GPU backend
detect_gpu() {
  step "Auto-detecting GPU"

  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    info "NVIDIA GPU detected via nvidia-smi."
    BACKEND="nvidia"
    return
  fi

  if command -v lspci &>/dev/null; then
    if lspci 2>/dev/null | grep -qi "NVIDIA"; then
      info "NVIDIA GPU detected via lspci."
      BACKEND="nvidia"
      return
    fi
    if lspci 2>/dev/null | grep -Eqi "AMD|Radeon"; then
      info "AMD GPU detected via lspci."
      BACKEND="amd"
      return
    fi
  fi

  if ls /dev/dri/renderD* &>/dev/null; then
    if command -v vulkaninfo &>/dev/null; then
      GPU_INFO=$(vulkaninfo 2>/dev/null || true)
      if echo "$GPU_INFO" | grep -qi "NVIDIA"; then
        info "NVIDIA GPU detected via vulkaninfo."
        BACKEND="nvidia"
        return
      fi
      if echo "$GPU_INFO" | grep -Eqi "AMD|Radeon"; then
        info "AMD GPU detected via vulkaninfo."
        BACKEND="amd"
        return
      fi
    fi
  fi

  warn "No supported GPU detected – falling back to CPU-only build."
  BACKEND="cpu"
}

[[ -z "${BACKEND}" ]] && detect_gpu

info "Selected backend: ${BACKEND^^}"

# Install base dependencies
step "Installing base dependencies"
sudo apt-get update -qq
sudo apt-get install -y \
  build-essential cmake git curl wget pkg-config \
  libcurl4-openssl-dev ca-certificates
success "Base dependencies installed."

# Backend-specific dependencies
case "${BACKEND}" in
  nvidia)
    step "Installing NVIDIA / CUDA dependencies"
    # Prefer NVIDIA repo CUDA toolkit (e.g. /usr/local/cuda-13.0/bin/nvcc)
    # over the broken apt nvidia-cuda-toolkit which includes ARM64 SVE headers
    # that conflict with nvcc on aarch64.
    CUDA_NVCC=""
    CUDA_FOUND=0
    for _cuda_dir in /usr/local/cuda-13.0/bin /usr/local/cuda-13/bin /usr/local/cuda/bin; do
      if [[ -x "${_cuda_dir}/nvcc" ]]; then
        export PATH="${_cuda_dir}:${PATH}"
        CUDA_NVCC="${_cuda_dir}/nvcc"
        CUDA_VER=$("${_cuda_dir}/nvcc" --version | grep -oP 'release \K[0-9.]+')
        info "Using CUDA toolkit from ${_cuda_dir} (version ${CUDA_VER})."
        CUDA_FOUND=1
        break
      fi
    done
    # If not found in preferred dirs, accept nvcc from PATH (unless it's the broken apt one)
    if [[ "${CUDA_FOUND}" -eq 0 ]] && command -v nvcc &>/dev/null; then
      _NVCC_PATH=$(command -v nvcc)
      if [[ "${_NVCC_PATH}" == "/usr/bin/nvcc" || "${_NVCC_PATH}" == /usr/lib/nvidia-cuda-toolkit/* ]]; then
        warn "nvcc found at ${_NVCC_PATH} appears to be the broken apt nvidia-cuda-toolkit (ARM64 SVE header conflict)."
        warn "Make sure the NVIDIA CUDA repo toolkit is installed and in PATH."
      else
        CUDA_NVCC="${_NVCC_PATH}"
        CUDA_VER=$(nvcc --version | grep -oP 'release \K[0-9.]+')
        info "Using CUDA toolkit from PATH: ${_NVCC_PATH} (version ${CUDA_VER})."
        CUDA_FOUND=1
      fi
    fi
    # Fail early if no valid CUDA toolkit
    if [[ "${CUDA_FOUND}" -eq 0 ]]; then
      error "No valid CUDA toolkit (nvcc) found for NVIDIA backend."
      error "Install the NVIDIA CUDA toolkit (e.g. from https://developer.nvidia.com/cuda-downloads)"
      error "and ensure nvcc is in PATH, or set BACKEND=cpu for a CPU-only build."
      exit 1
    fi
    if ! command -v nvidia-smi &>/dev/null; then
      warn "nvidia-smi not found. Make sure NVIDIA drivers are installed."
    else
      nvidia-smi --query-gpu=name,driver_version,memory.total \
                 --format=csv,noheader | while IFS=',' read -r name drv mem; do
        info "GPU: ${name} | Driver: ${drv} | VRAM:${mem}"
      done
    fi
    ;;
  amd)
    step "Installing AMD / Vulkan dependencies"
    sudo apt-get install -y \
      libvulkan-dev vulkan-tools glslc \
      mesa-vulkan-drivers libglfw3-dev
    success "Vulkan dependencies installed."
    if command -v vulkaninfo &>/dev/null; then
      GPU_NAME=$(vulkaninfo 2>/dev/null | grep -i "deviceName" | head -1 | awk -F'=' '{print $2}' | xargs || echo "unknown")
      info "Vulkan device: ${GPU_NAME}"
    fi
    ;;
  cpu)
    info "CPU-only build – no extra GPU deps needed."
    ;;
esac

# Clone / update repo. LLAMA_CPP_REF=latest builds the most
# recently published tag, resolved after the tag fetch below; a concrete
# tag/branch name is built as-is.
step "Fetching llama.cpp source (ref: ${LLAMA_CPP_REF})"
REQUESTED_REF="${LLAMA_CPP_REF}"
# INSTALL_DIR defaults to /opt (created root-owned earlier). Cloning as the
# invoking user fails there on a fresh host — run git privileged in that
# case, then hand the tree back to the user so the build stays unprivileged.
git_clone_into() {
  if [[ -w "${INSTALL_DIR}" ]]; then
    git "$@"
  else
    sudo git "$@"
  fi
}
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  # Fix dubious ownership for existing repos
  if [[ "${INSTALL_DIR}" != "${HOME}"* ]]; then
    git config --global --add safe.directory "${INSTALL_DIR}"
  fi
  info "Existing repo found at ${INSTALL_DIR} – fetching refs and tags…"
else
  if [[ "${LLAMA_CPP_REF}" == "latest" ]]; then
    info "Cloning into ${INSTALL_DIR} (newest tag is resolved after the tag fetch)…"
    git_clone_into clone "${LLAMA_CPP_REPO_URL}" "${INSTALL_DIR}"
  else
    info "Cloning into ${INSTALL_DIR} at ${LLAMA_CPP_REF}…"
    # --branch pins the starting point; --depth 1 is deliberately NOT used: a
    # shallow clone of a single ref rewrites the fetch refspec to just that ref
    # (verified: remote.origin.fetch becomes
    # +refs/tags/<ref>:refs/tags/<ref>), so a later change of LLAMA_CPP_REF could
    # never be fetched. A full --branch clone keeps every branch and tag.
    git_clone_into clone --branch "${LLAMA_CPP_REF}" \
      "${LLAMA_CPP_REPO_URL}" "${INSTALL_DIR}"
  fi
  # Drop ownership from the privileged clone so fetch/build/run are unprivileged
  if ! [[ -w "${INSTALL_DIR}" ]]; then
    sudo chown -R "$(id -un):$(id -gn)" "${INSTALL_DIR}"
  fi
fi

# Fix dubious ownership when directory was created with sudo
if [[ "${INSTALL_DIR}" != "${HOME}"* ]]; then
  git config --global --add safe.directory "${INSTALL_DIR}"
fi

if ! git -C "${INSTALL_DIR}" fetch --tags --force; then
  error "git fetch from ${LLAMA_CPP_REPO_URL} failed."
  error "If the error mentions authentication (HTTP 401, 'Username for ...'), git needs a GitHub credential for this URL — e.g. 'gh auth setup-git' or a PAT in a git credential helper — then re-run."
fi

# Resolve "latest" to the most recently published tag: the newest tag-creation
# date among the fetched refs (annotated tag = tagger date, lightweight tag =
# commit date). Resolved AFTER the fetch so tags reachable only via non-default
# branches are included too.
if [[ "${LLAMA_CPP_REF}" == "latest" ]]; then
  LATEST_TAG="$(git -C "${INSTALL_DIR}" for-each-ref --sort=-creatordate --count=1 --format='%(refname:short)' refs/tags)"
  if [[ -z "${LATEST_TAG}" ]]; then
    error "LLAMA_CPP_REF=latest but no tags were found in ${LLAMA_CPP_REPO_URL} — pin a concrete tag/branch via LLAMA_CPP_REF instead"
  fi
  info "'latest' resolved to most recently published tag: ${LATEST_TAG}"
  LLAMA_CPP_REF="${LATEST_TAG}"
fi

# Checkout the resolved ref (tag → detached HEAD, branch → local branch).
info "Checking out ${LLAMA_CPP_REF}…"
if ! git -C "${INSTALL_DIR}" checkout "${LLAMA_CPP_REF}"; then
  # A branch ref may exist only as a remote-tracking ref (no local copy yet).
  if ! git -C "${INSTALL_DIR}" checkout -B "${LLAMA_CPP_REF}" "origin/${LLAMA_CPP_REF}"; then
    error "LLAMA_CPP_REF '${LLAMA_CPP_REF}' not found in ${INSTALL_DIR} — list refs with: git -C ${INSTALL_DIR} ls-remote --tags origin, or point LLAMA_CPP_REF at an existing tag/branch"
  fi
fi
git -C "${INSTALL_DIR}" clean -fd
git -C "${INSTALL_DIR}" submodule update --init --recursive
BUILT_REF="$(git -C "${INSTALL_DIR}" describe --tags --always --dirty)"
success "Source ready at ${INSTALL_DIR} (ref: ${LLAMA_CPP_REF}, describe: ${BUILT_REF})."

# Configure & build
step "Configuring CMake (backend: ${BACKEND^^})"
BUILD_DIR="${INSTALL_DIR}/build"
# Wipe stale build dir – ExternalProject fails with "Operation not permitted"
# when CMake cache state is corrupted (common after git clean + tag checkout)
if [[ -d "${BUILD_DIR}" ]]; then
  info "Removing stale build directory…"
  rm -rf "${BUILD_DIR}"
fi

CMAKE_OPTS=(-DLLAMA_CURL=ON)

case "${BACKEND}" in
  nvidia)
    CMAKE_OPTS+=(-DGGML_CUDA=ON)
    if [[ -n "${CUDA_NVCC}" ]]; then
      CMAKE_OPTS+=(-DCMAKE_CUDA_COMPILER:PATH="${CUDA_NVCC}")
      info "CUDA compiler: ${CUDA_NVCC}"
    fi
    info "CUDA acceleration: ON"
    ;;
  amd)
    CMAKE_OPTS+=(-DGGML_VULKAN=ON)
    info "Vulkan acceleration: ON"
    ;;
  cpu)
    info "No GPU acceleration flags set."
    ;;
esac

cmake -S "${INSTALL_DIR}" -B "${BUILD_DIR}" "${CMAKE_OPTS[@]}"
success "CMake configuration complete."

step "Building llama.cpp (using ${JOBS} parallel jobs)"
cmake --build "${BUILD_DIR}" --config Release -j"${JOBS}"
success "Build complete."

# System-wide install (binaries go to /usr/local/bin)
step "Installing system-wide"
sudo cmake --install "${BUILD_DIR}"

# Refresh ldconfig so shared libraries are discoverable
step "Updating shared library cache"
if [[ -f /usr/local/lib/libllama.so ]]; then
  sudo bash -c 'echo "/usr/local/lib" > /etc/ld.so.conf.d/llama-cpp.conf'
  sudo ldconfig
  success "Shared library cache updated."
else
  info "No shared libraries found – ldconfig refresh skipped."
fi

# Summary
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║        llama.cpp installation complete!      ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Backend:${RESET}    ${GREEN}${BACKEND^^}${RESET}"
echo -e "  ${BOLD}Source:${RESET}     ${INSTALL_DIR}"
BUILT_REF_LABEL="${LLAMA_CPP_REF}"
[[ "${REQUESTED_REF}" == "latest" ]] && BUILT_REF_LABEL="${LLAMA_CPP_REF} (requested: latest)"
echo -e "  ${BOLD}Built ref:${RESET}  ${BUILT_REF_LABEL} (${BUILT_REF})"
echo -e "  ${BOLD}Binaries:${RESET}   /usr/local/bin"
echo ""
echo -e "  ${BOLD}Key binaries:${RESET}"
echo -e "    llama-cli     – interactive CLI"
echo -e "    llama-server  – OpenAI-compatible HTTP server"
echo -e "    llama-bench   – benchmarking"
echo ""
echo -e "  ${BOLD}Quick start:${RESET}"
echo -e "    llama-cli -m /path/to/model.gguf -p \"Hello!\" -n 128"
echo ""
echo -e "  ${BOLD}Run as server:${RESET}"
echo -e "    llama-server -m /path/to/model.gguf --host 0.0.0.0 --port 8080"
