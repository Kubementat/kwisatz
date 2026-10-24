#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-music-gen.sh — Install ACE-Step 1.5 song generation (GPU) or CPU preview
# =============================================================================
#
# Description:
#   server mode  (default): installs ACE-Step 1.5 natively into /opt/ace-step
#     for GPU hosts and runs its async REST API (`acestep-api`) as the
#     systemd service `ace-step.service`. The GPU vendor is auto-detected:
#       AMD (ROCm, e.g. Strix Halo / gfx1151): ROCm torch wheels; docker is
#         deliberately NOT used because on gfx1151 the container ROCm
#         userland must match the host driver stack (same pattern as
#         llama-swap).
#       NVIDIA (e.g. DGX Spark): CUDA torch wheels — default cu126 on x86_64,
#       cu128 on arm64 (Blackwell/GB10 need it); override with
#       MUSIC_GEN_TORCH_INDEX when your driver needs another CUDA build.
#
#   preview mode  (MUSIC_GEN_MODE=preview): CPU-only musicgen-small in a uv
#     venv under ~/music-gen-preview plus a tiny `~/music-preview` CLI, for
#     non-GPU boxes. The model downloads lazily on the first CLI run, so the
#     install itself stays cheap.
#
# Options:
#   --force     Reinstall even when the version marker matches
#   --help      Display this help message
#
# Usage:
#   ./setup-music-gen.sh                        # server mode (AMD or NVIDIA GPU host)
#   MUSIC_GEN_MODE=preview ./setup-music-gen.sh # CPU preview on a non-GPU box
#   ./setup-music-gen.sh --force                # force full reinstall
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
MUSIC_GEN_MODE="${MUSIC_GEN_MODE:-server}"
MUSIC_GEN_PORT="${MUSIC_GEN_PORT:-9294}"
# Pinned ACE-Step 1.5 release tag (git tag format used by the repo).
ACESTEP_VERSION="${ACESTEP_VERSION:-v1.5}"
ACESTEP_CHECKPOINTS_DIR="${ACESTEP_CHECKPOINTS_DIR:-/opt/ace-step/models}"
MUSICGEN_MODEL_DIR="${MUSICGEN_MODEL_DIR:-$HOME/music-gen-preview/models}"
# Interpreter the uv venv is seeded from (also an escape hatch for hosts
# where the default system python is not what you want).
MUSIC_GEN_PYTHON="${MUSIC_GEN_PYTHON:-/usr/bin/python3}"
MUSIC_GEN_OPEN_LAN="${MUSIC_GEN_OPEN_LAN:-false}"
MUSIC_GEN_SMOKE_TEST="${MUSIC_GEN_SMOKE_TEST:-true}"
# GPU vendor wheels: 'auto' (default) detects amd (ROCm) or nvidia (CUDA);
# 'amd'/'nvidia' force a flavor. MUSIC_GEN_TORCH_INDEX overrides the derived
# PyTorch wheel index (e.g. https://download.pytorch.org/whl/cu128).
MUSIC_GEN_GPU_VENDOR="${MUSIC_GEN_GPU_VENDOR:-auto}"
MUSIC_GEN_TORCH_INDEX="${MUSIC_GEN_TORCH_INDEX:-}"
# ROCm wheel index used on AMD hosts (gfx1151 needs ROCm >= 7.x).
ROCM_TORCH_INDEX="${ROCM_TORCH_INDEX:-https://download.pytorch.org/whl/rocm7.1}"
# Opt-in LD_PRELOAD of the host HSA runtime (vault ROCm pitfall #2): set to
# 'true' ONLY if the torch smoke test segfaults.
ACESTEP_LD_PRELOAD="${ACESTEP_LD_PRELOAD:-false}"

ACESTEP_REPO_URL="https://github.com/ACE-Step/ACE-Step-1.5.git"
ACESTEP_DIR="/opt/ace-step/ACE-Step-1.5"
ENV_FILE="${ACESTEP_DIR}/.env"
VERSION_MARKER_PATH="${ACESTEP_DIR}/.installed-version"
SERVICE_NAME="ace-step"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# LAN subnet the server-mode port is opened for (lab LAN).
MUSIC_GEN_LAN_SUBNET="192.168.122.0/24"

PREVIEW_DIR="$HOME/music-gen-preview"
PREVIEW_CLI="$HOME/music-preview"

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
  cat << 'EOF'
Usage: setup-music-gen.sh [OPTIONS]

Install ACE-Step 1.5 text-to-song generation (server mode, AMD ROCm or
NVIDIA GPU hosts) or a CPU-only musicgen-small preview CLI (preview mode,
non-GPU boxes). Uses sudo internally; run as a regular user.

Options:
  --force    Reinstall even when the version marker matches
  --help     Display this help message (-h)

Environment variables (all optional):
  MUSIC_GEN_MODE          'server' (default; ACE-Step 1.5 + systemd, requires
                          an AMD or NVIDIA GPU host) or 'preview'
                          (CPU-only musicgen-small CLI in $HOME).
  MUSIC_GEN_GPU_VENDOR    'auto' (default: detect /dev/kfd vs NVIDIA), 'amd',
                          or 'nvidia' — picks the torch wheel flavor.
  MUSIC_GEN_TORCH_INDEX   Override the PyTorch wheel index URL. Empty
                          (default) derives it: ROCm index on AMD; cu126 on
                          NVIDIA x86_64; cu128 on NVIDIA arm64 (DGX Spark /
                          GB10 Blackwell). Set e.g. .../whl/cu129 when a
                          newer CUDA build is required.
  ROCM_TORCH_INDEX        ROCm wheel index on AMD hosts (default:
                          https://download.pytorch.org/whl/rocm7.1)
  MUSIC_GEN_PORT          acestep-api listen port (default: 9294)
  ACESTEP_VERSION         Pinned ACE-Step 1.5 git tag (default: v1.5)
  ACESTEP_CHECKPOINTS_DIR Where model checkpoints live (default: /opt/ace-step/models)
  MUSICGEN_MODEL_DIR      HF cache dir the musicgen-small weights are
                          downloaded into (also the default output dir for
                          generated WAVs, default: ~/music-gen-preview/models)
  MUSIC_GEN_PYTHON        Interpreter the preview uv venv is seeded from
                          (default: /usr/bin/python3)
  MUSIC_GEN_OPEN_LAN      'true' = open MUSIC_GEN_PORT/tcp to the lab LAN
                          (192.168.122.0/24) via ufw (default: false)
  MUSIC_GEN_SMOKE_TEST    'false' = skip the built-in HTTP + 10 s DiT-only
                          generation smoke test (default: true). Output is
                          always FLAC — MP3 export is broken on ROCm builds.
  ACESTEP_LD_PRELOAD      'true' = add LD_PRELOAD of the host HSA runtime to
                          the service unit (default: false). Only if the
                          torch smoke test segfaults.
  HSA_OVERRIDE_GFX_VERSION  NOT honored. Server mode refuses to run with it
                          set on a gfx1151 host (it breaks the native
                          gfx1151 kernels: "no matching kernel image").

Examples:
  ./setup-music-gen.sh                        # server mode (AMD or NVIDIA GPU host)
  MUSIC_GEN_MODE=preview ./setup-music-gen.sh # CPU preview CLI
  MUSIC_GEN_OPEN_LAN=true ./setup-music-gen.sh
  MUSIC_GEN_TORCH_INDEX=https://download.pytorch.org/whl/cu129 ./setup-music-gen.sh

The API key is generated once into /opt/ace-step/ACE-Step-1.5/.env (mode 600)
and reused on re-runs; re-runs converge (unit re-rendered, service restarted).
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

# Regular user expected; privileged operations go through sudo.
if [[ $(id -u) -ne 0 ]]; then
  command -v sudo &>/dev/null \
    || error "Running as a regular user but sudo is not available — privileged steps (systemd, /opt/ace-step) cannot be performed."
else
  warn "Running as root — a regular user with sudo privileges is expected."
fi
for tool in curl git openssl; do
  command -v "$tool" &>/dev/null \
    || error "$tool is not installed — required by this task."
done
if ! [[ "$MUSIC_GEN_PORT" =~ ^[0-9]+$ ]] || (( 10#$MUSIC_GEN_PORT < 1 || 10#$MUSIC_GEN_PORT > 65535 )); then
  error "MUSIC_GEN_PORT must be a number between 1 and 65535 (got: ${MUSIC_GEN_PORT})"
fi
MUSIC_GEN_PORT=$((10#$MUSIC_GEN_PORT))

case "$MUSIC_GEN_MODE" in
  server|preview) ;;
  *) error "MUSIC_GEN_MODE must be 'server' or 'preview' (got: ${MUSIC_GEN_MODE})" ;;
esac

# Service runtime user (invoking user by default; SUDO_USER-aware).
SERVICE_USER="${SUDO_USER:-$(id -un)}"

success "Pre-flight checks passed (mode: ${MUSIC_GEN_MODE})"

# ---------------------------------------------------------------------------
# ensure_uv — bootstrap uv once if missing
# ---------------------------------------------------------------------------
ensure_uv() {
  if command -v uv &>/dev/null; then
    return 0
  fi
  step "Installing uv (bootstrap)"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # The installer lands uv in ~/.local/bin, which is not on PATH yet in this shell.
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv &>/dev/null \
    || error "uv installation failed or $HOME/.local/bin is not usable."
  success "uv installed: $(uv --version)"
}

# ---------------------------------------------------------------------------
# ROCm pitfall guard: HSA_OVERRIDE_GFX_VERSION breaks gfx1151
#
# gfx1151 (Strix Halo) is a NATIVE target in ROCm 7.x. The repo's
# start_*_rocm scripts set HSA_OVERRIDE_GFX_VERSION for RDNA2/3 consumer
# cards — on gfx1151 it poisons kernel selection and fails with
# "no matching kernel image". Refuse to start a service with it in the
# environment rather than serve a broken stack.
# ---------------------------------------------------------------------------
check_gfx1151_hsa_guard() {
  # NVIDIA hosts have no HSA; the guard is AMD-only.
  [[ "${TORCH_FLAVOR:-amd}" == "amd" ]] || return 0
  if [[ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]] \
    && command -v rocminfo &>/dev/null \
    && rocminfo 2>/dev/null | grep -q gfx1151; then
    error "HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION} is set, but this host is gfx1151 — that override targets RDNA2/3 cards and breaks the native gfx1151 kernels ('no matching kernel image'). Unset it and re-run (the ACE-Step start_*_rocm scripts set it; do not copy it into the service environment)."
  fi
}

# ---------------------------------------------------------------------------
# detect_gpu_vendor — set TORCH_FLAVOR (amd|nvidia) and TORCH_INDEX (wheel
# index URL). AMD is preferred when both are present (ROCm stack installed);
# MUSIC_GEN_GPU_VENDOR overrides detection. Returns non-zero (message
# printed) when no GPU is visible so server mode can refuse and suggest
# preview mode.
# ---------------------------------------------------------------------------
detect_gpu_vendor() {
  local want="${MUSIC_GEN_GPU_VENDOR}"
  local has_amd=false has_nvidia=false
  if [[ -c /dev/kfd ]] || command -v rocminfo &>/dev/null; then
    has_amd=true
  fi
  if command -v nvidia-smi &>/dev/null || compgen -G '/dev/nvidia*' >/dev/null; then
    has_nvidia=true
  fi

  case "$want" in
    amd)
      [[ "$has_amd" == "true" ]] || { err_msg "MUSIC_GEN_GPU_VENDOR=amd but no /dev/kfd or rocminfo found."; return 1; }
      TORCH_FLAVOR="amd" ;;
    nvidia)
      [[ "$has_nvidia" == "true" ]] || { err_msg "MUSIC_GEN_GPU_VENDOR=nvidia but neither nvidia-smi nor /dev/nvidia* found."; return 1; }
      TORCH_FLAVOR="nvidia" ;;
    auto)
      if [[ "$has_amd" == "true" ]]; then
        TORCH_FLAVOR="amd"
        [[ "$has_nvidia" == "true" ]] && warn "Both AMD and NVIDIA devices found — using ROCm wheels (MUSIC_GEN_GPU_VENDOR=nvidia to override)."
      elif [[ "$has_nvidia" == "true" ]]; then
        TORCH_FLAVOR="nvidia"
      else
        err_msg "No GPU detected: no /dev/kfd (AMD) and no nvidia-smi or /dev/nvidia* (NVIDIA)."
        return 1
      fi ;;
    *)
      err_msg "MUSIC_GEN_GPU_VENDOR must be 'auto', 'amd' or 'nvidia' (got: ${want})"
      return 1 ;;
  esac

  # NVIDIA wheel index: cu126 is x86_64-safe (driver forward-compat covers
  # CUDA 12.6 requests); arm64 (DGX Spark / GB10 Blackwell) requires the
  # cu128 wheels. MUSIC_GEN_TORCH_INDEX overrides either.
  if [[ -n "$MUSIC_GEN_TORCH_INDEX" ]]; then
    TORCH_INDEX="$MUSIC_GEN_TORCH_INDEX"
  elif [[ "$TORCH_FLAVOR" == "amd" ]]; then
    TORCH_INDEX="$ROCM_TORCH_INDEX"
  elif [[ "$(uname -m)" == "aarch64" ]]; then
    TORCH_INDEX="https://download.pytorch.org/whl/cu128"
  else
    TORCH_INDEX="https://download.pytorch.org/whl/cu126"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# SERVER MODE — ACE-Step 1.5 native install + systemd
# ---------------------------------------------------------------------------
setup_server() {
  # Refuse hosts without a GPU: server mode needs ROCm (AMD) or CUDA (NVIDIA).
  if ! detect_gpu_vendor; then
    error "This host has no usable GPU. Server mode needs AMD ROCm (/dev/kfd) or NVIDIA (nvidia-smi). On non-GPU machines run: MUSIC_GEN_MODE=preview ./setup-music-gen.sh"
  fi
  info "GPU vendor flavor: ${TORCH_FLAVOR} (torch wheel index: ${TORCH_INDEX})"
  if [[ "$TORCH_FLAVOR" == "amd" ]] && ! groups | grep -qE '(^|[[:space:]])(render|video)([[:space:]]|$)'; then
    warn "Current user is not in the 'render'/'video' groups — GPU access for the service user (${SERVICE_USER}) may fail. Add the user (and confirm the unit's SupplementaryGroups) and re-login."
  fi

  check_gfx1151_hsa_guard

  step "Preparing /opt/ace-step"
  sudo mkdir -p /opt/ace-step
  sudo chown "$(id -un)" /opt/ace-step
  sudo mkdir -p "${ACESTEP_CHECKPOINTS_DIR}"
  info "Checkpoints dir: ${ACESTEP_CHECKPOINTS_DIR}"

  ensure_uv

  # --- Clone (or reuse) the repo, pinned to ACESTEP_VERSION ---
  if [[ ! -d "${ACESTEP_DIR}/.git" ]]; then
    step "Cloning ${ACESTEP_REPO_URL} @ ${ACESTEP_VERSION}"
    git clone --branch "${ACESTEP_VERSION}" --depth 1 "${ACESTEP_REPO_URL}" "${ACESTEP_DIR}"
  else
    info "Repository already present at ${ACESTEP_DIR}"
  fi

  # --- venv + dependencies (skipped when the version marker matches) ---
  local need_install=true
  if [[ "$FORCE_INSTALL" != "true" && -f "${VERSION_MARKER_PATH}" \
    && "$(cat "${VERSION_MARKER_PATH}")" == "${ACESTEP_VERSION}" \
    && -d "${ACESTEP_DIR}/.venv" && -f "${SERVICE_FILE}" ]]; then
    info "Version marker matches ${ACESTEP_VERSION} — skipping venv/dependency install (unit and .env are still re-converged)."
    need_install=false
  fi

  if [[ "$need_install" == "true" ]]; then
    step "Creating uv venv (python 3.12) in ${ACESTEP_DIR}"
    (
      cd "${ACESTEP_DIR}"
      uv venv --python 3.12
      # Vendor torch wheels FIRST, from the vendor wheel index — see below why
      # uv must not manage the torch/torchaudio pair afterwards.
      info "Installing ${TORCH_FLAVOR} torch wheels (${TORCH_INDEX}) — this is a large download"
      uv pip install torch torchaudio --index-url "${TORCH_INDEX}"
      # WHY --no-install-package: uv sync would resolve torch/torchaudio from
      # the repo's default index and REPLACE the vendor wheels — on AMD with
      # CUDA ones that cannot see the GPU (on NVIDIA with a CPU/other-CUDA
      # build). Keep uv from touching them.
      uv sync --no-install-package torch --no-install-package torchaudio
    )
    success "ACE-Step ${ACESTEP_VERSION} installed"
  fi

  # --- .env (mode 600; API key generated once, never rotated on re-run) ---
  step "Writing ${ENV_FILE} (mode 600)"
  local api_key=""
  if [[ -f "${ENV_FILE}" ]]; then
    api_key="$(env_file_get "${ENV_FILE}" ACESTEP_API_KEY)"
  fi
  if [[ -z "${api_key}" ]]; then
    api_key="$(openssl rand -hex 32)"
    info "Generated a new ACESTEP_API_KEY (first run — store it where your clients can read it)."
  else
    info "Reusing existing ACESTEP_API_KEY from ${ENV_FILE}"
  fi
  env_file_write "${ENV_FILE}" <<EOF
# ACE-Step service environment (mode 600). Managed by setup-music-gen.sh.
# ACESTEP_API_KEY is generated once and reused on re-runs — never rotate it
# without re-distributing the key to all clients.
# PITFALL: do NOT add HSA_OVERRIDE_GFX_VERSION here — gfx1151 is native and
# the override breaks it ("no matching kernel image").
ACESTEP_LM_BACKEND=pt
MIOPEN_FIND_MODE=FAST
ACESTEP_CHECKPOINTS_DIR=${ACESTEP_CHECKPOINTS_DIR}
ACESTEP_API_KEY=${api_key}
ACESTEP_OFFLOAD_TO_CPU=false
EOF
  success "Environment file in place at ${ENV_FILE}"

  # --- Version marker (installed dependencies) ---
  echo "${ACESTEP_VERSION}" > "${VERSION_MARKER_PATH}"

  # --- GPU verification before enabling the service ---
  step "Verifying PyTorch sees the AMD GPU"
  local gpu_check_file
  gpu_check_file="$(mktemp -t acestep-gpu-check.XXXX)"
  if ! (
    cd "${ACESTEP_DIR}"
    # --no-sync: plain `uv run` syncs the project first, which reinstalls torch
    # from the index pinned in the repo's [tool.uv.sources] (CUDA) and clobbers
    # the ROCm/CUDA vendor wheels installed above.
    uv run --no-sync python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
  ) > "${gpu_check_file}"; then
    rm -f "${gpu_check_file}"
    error "GPU smoke test failed to run (uv run python / import torch) — check the ${TORCH_FLAVOR} driver stack (ROCm: /dev/kfd, /dev/dri, render+video groups; NVIDIA: nvidia-smi) for ${SERVICE_USER}."
  fi
  cat "${gpu_check_file}"
  if ! grep -q "True" "${gpu_check_file}"; then
    rm -f "${gpu_check_file}"
    error "PyTorch does not report a usable GPU — check the ${TORCH_FLAVOR} driver stack (ROCm: /dev/kfd, /dev/dri, render+video groups; NVIDIA: nvidia-smi), and that MUSIC_GEN_TORCH_INDEX matches the installed driver (e.g. cu128 on DGX Spark)."
  fi
  rm -f "${gpu_check_file}"
  success "GPU is visible to PyTorch"

  render_and_install_unit
  enable_and_restart_service
  open_lan_rule
  if [[ "$MUSIC_GEN_SMOKE_TEST" == "true" ]]; then
    run_smoke_test
  else
    warn "Smoke test skipped (MUSIC_GEN_SMOKE_TEST=false)."
  fi

  success "ACE-Step 1.5 is running (${TORCH_FLAVOR} wheels) at http://127.0.0.1:${MUSIC_GEN_PORT} (API key in ${ENV_FILE}, mode 600)"
  info "Gradio UI on demand: cd ${ACESTEP_DIR} && uv run --no-sync acestep"
  if [[ "$MUSIC_GEN_OPEN_LAN" != "true" ]]; then
    info "Port ${MUSIC_GEN_PORT} is not exposed to the LAN (MUSIC_GEN_OPEN_LAN=false). Reach it via a tunnel or set MUSIC_GEN_OPEN_LAN=true."
  fi
}

# ---------------------------------------------------------------------------
# Render and install the systemd unit (re-rendered every run: converge)
# ---------------------------------------------------------------------------
render_and_install_unit() {
  step "Rendering ${SERVICE_FILE}"

  # PYTORCH_HIP_ALLOC_CONF must be UNSET for ACE-Step (UnsetEnvironment= line;
  # `Environment=-VAR` is NOT a thing — systemd logs "Invalid environment
  # assignment, ignoring" for it, and the variable stays set. UnsetEnvironment=
  # exists since systemd 235, i.e. on every supported Ubuntu).
  # LD_PRELOAD of the host HSA runtime is an AMD/ROCm-only fix, added only
  # when the torch smoke test segfaults (vault ROCm pitfall #2,
  # ACESTEP_LD_PRELOAD=true). It has no meaning on NVIDIA hosts.
  local ld_preload_line=""
  if [[ "${ACESTEP_LD_PRELOAD}" == "true" ]]; then
    if [[ "${TORCH_FLAVOR:-amd}" != "amd" ]]; then
      warn "ACESTEP_LD_PRELOAD=true is an AMD/ROCm HSA workaround — ignored on this NVIDIA host."
    else
      ld_preload_line="Environment=LD_PRELOAD=/opt/rocm/lib/libhsa-runtime64.so.1"
    fi
  fi

  # ExecStart target. `uv venv` does NOT put a uv binary inside .venv/bin, so
  # the unit must never reference .venv/bin/uv — systemd would fail the start
  # with 203/EXEC. Use the console script that `uv sync` installs from
  # ACE-Step's [project.scripts] (acestep-api = acestep.api_server:main); fall
  # back to the real uv binary, and keep --no-sync there so a boot-time start
  # cannot sync the project and replace the vendor torch wheels with the CUDA
  # build pinned in the repo's [tool.uv.sources].
  local exec_start="--host 0.0.0.0 --port ${MUSIC_GEN_PORT} --config_path acestep-v15-xl-turbo --lm_model_path acestep-5Hz-lm-1.7B"
  if [[ -x "${ACESTEP_DIR}/.venv/bin/acestep-api" ]]; then
    exec_start="${ACESTEP_DIR}/.venv/bin/acestep-api ${exec_start}"
  else
    local uv_bin
    uv_bin="$(command -v uv || true)"
    [[ -n "${uv_bin}" ]] \
      || error "Cannot render ExecStart: no ${ACESTEP_DIR}/.venv/bin/acestep-api and uv is not on PATH — re-run the install (or use --force)."
    exec_start="${uv_bin} run --no-sync acestep-api ${exec_start}"
  fi

  local unit_tmp
  unit_tmp="$(mktempfile "${SERVICE_NAME}.service")"
  cat > "${unit_tmp}" <<EOF
# Managed by setup-music-gen.sh — do not edit by hand (re-run the script).
# PYTORCH_HIP_ALLOC_CONF is unset via UnsetEnvironment=; the LD_PRELOAD of
# the host HSA runtime appears only when the torch smoke test segfaults
# (vault ROCm pitfall #2, ACESTEP_LD_PRELOAD=true).
[Unit]
Description=ACE-Step 1.5 text-to-song generation REST API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
SupplementaryGroups=render video
WorkingDirectory=${ACESTEP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=ACESTEP_LM_BACKEND=pt
UnsetEnvironment=PYTORCH_HIP_ALLOC_CONF
${ld_preload_line}
ExecStart=${exec_start}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  UNIT_CHANGED=false
  if [[ -f "${SERVICE_FILE}" ]] && diff -q <(sudo cat "${SERVICE_FILE}") "${unit_tmp}" &>/dev/null; then
    info "Service file unchanged."
  else
    # Rendered as the invoking user, installed root-owned 644 — no secrets in
    # the unit; the .env (mode 600) is resolved at runtime via EnvironmentFile.
    sudo install -m 644 -o root -g root "${unit_tmp}" "${SERVICE_FILE}"
    UNIT_CHANGED=true
    success "Service file installed at ${SERVICE_FILE}"
  fi
  rm -f "${unit_tmp}"
}

# ---------------------------------------------------------------------------
# Enable and (re)start the service
# ---------------------------------------------------------------------------
enable_and_restart_service() {
  step "Enabling ${SERVICE_NAME}.service"
  command -v systemctl &>/dev/null || error "systemctl not found — a systemd host is required."

  sudo systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo systemctl enable "${SERVICE_NAME}.service"

  local state
  state="$(sudo systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
  if [[ "${UNIT_CHANGED}" == "true" || "$state" != "active" ]]; then
    sudo systemctl restart "${SERVICE_NAME}.service"
    success "Service restarted"
  else
    info "Service already active with the current configuration — left untouched."
  fi
}

# ---------------------------------------------------------------------------
# Open the API port to the lab LAN (only when requested; ufw helpers)
# ---------------------------------------------------------------------------
open_lan_rule() {
  if [[ "${MUSIC_GEN_OPEN_LAN}" != "true" ]]; then
    return 0
  fi
  if ! ufw_available; then
    warn "MUSIC_GEN_OPEN_LAN=true but ufw is not installed — skipping firewall rule for ${MUSIC_GEN_PORT}/tcp."
    return 0
  fi
  step "Opening ${MUSIC_GEN_PORT}/tcp to ${MUSIC_GEN_LAN_SUBNET}"
  if ufw_rule_exists "${MUSIC_GEN_PORT}" tcp IN; then
    info "Inbound rule for ${MUSIC_GEN_PORT}/tcp already exists, skipping."
    return 0
  fi
  sudo ufw allow in from "${MUSIC_GEN_LAN_SUBNET}" to any port "${MUSIC_GEN_PORT}" proto tcp comment "music-gen"
  _ufw_invalidate_status_cache
  success "UFW rule added: ${MUSIC_GEN_PORT}/tcp from ${MUSIC_GEN_LAN_SUBNET}"
}

# ---------------------------------------------------------------------------
# Smoke test: health endpoint + one cheap DiT-only generation.
#
# CRITICAL PITFALL (ROCm builds): MP3 export can fail (torchcodec/ffmpeg
# linkage) — the service and every client must use FLAC or WAV only. The
# smoke test therefore requests audio_format=flac and never mp3.
# ---------------------------------------------------------------------------
run_smoke_test() {
  local base_url="http://127.0.0.1:${MUSIC_GEN_PORT}"
  local api_key="${ACESTEP_API_KEY:-}"
  if [[ -z "${api_key}" ]]; then
    api_key="$(env_file_get "${ENV_FILE}" ACESTEP_API_KEY || true)"
  fi
  [[ -n "${api_key}" ]] || error "Could not read ACESTEP_API_KEY from ${ENV_FILE}."

  step "Smoke test: waiting for ${SERVICE_NAME} API (bounded, 300 s)"
  local waited=0
  while (( waited < 300 )); do
    if curl -fsS -o /dev/null --max-time 5 "${base_url}/health" 2>/dev/null; then
      break
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  if (( waited >= 300 )); then
    error "API did not come up on ${base_url} within 300s — check: sudo journalctl -u ${SERVICE_NAME}.service -n 50"
  fi
  success "API is up at ${base_url}"

  step "Smoke test: generating one 10 s DiT-only track (thinking=false, FLAC)"
  local task
  task="$(curl -fsS -X POST "${base_url}/release_task" \
    -H "Authorization: Bearer ${api_key}" -H 'Content-Type: application/json' \
    -d '{"prompt":"instrumental jazz fusion, upright bass, Rhodes","audio_duration":10,"thinking":false,"audio_format":"flac"}' \
    | jq -r '.data.task_id')"
  [[ -n "${task}" && "${task}" != "null" ]] \
    || error "release_task did not return a task_id — check the API key and journal logs."
  info "Task submitted: ${task}"

  local status="" result="" gen_waited=0
  while (( gen_waited < 600 )); do
    result="$(curl -fsS -X POST "${base_url}/query_result" \
      -H "Authorization: Bearer ${api_key}" -H 'Content-Type: application/json' \
      -d "{\"task_ids\":[\"${task}\"]}")"
    status="$(jq -r '.data[0].status // empty' <<<"${result}")"
    if [[ "$status" == "1" || "$status" == "2" ]]; then
      break
    fi
    sleep 10
    gen_waited=$(( gen_waited + 10 ))
  done

  if [[ "$status" != "1" ]]; then
    error "Generation finished with status '${status:-timeout}' (expected 1) — check: sudo journalctl -u ${SERVICE_NAME}.service -n 50"
  fi
  local audio
  audio="$(jq -r '.data[0].audio // empty' <<<"${result}")"
  [[ -n "${audio}" ]] || error "Generation succeeded but returned no audio URL."

  local audio_path
  audio_path="$(mktemp -t acestep-smoke.XXXX)"
  if [[ "${audio}" == http* ]]; then
    curl -fsSL --max-time 120 -o "${audio_path}" "${audio}"
  else
    curl -fsSL --max-time 120 -o "${audio_path}" "${base_url}${audio#/}"
  fi
  if [[ ! -s "${audio_path}" ]]; then
    rm -f "${audio_path}"
    error "Audio file at ${audio} is empty — generation did not produce audio."
  fi
  info "Non-empty audio received ($(wc -c < "${audio_path}") bytes)."
  rm -f "${audio_path}"
  success "Smoke test passed — the service generated a 10 s DiT-only FLAC track."
}

# ---------------------------------------------------------------------------
# PREVIEW MODE — CPU-only musicgen-small + tiny CLI
# ---------------------------------------------------------------------------
setup_preview() {
  step "Setting up CPU preview in ${PREVIEW_DIR}"
  if [[ ! -x "${MUSIC_GEN_PYTHON}" ]]; then
    error "MUSIC_GEN_PYTHON='${MUSIC_GEN_PYTHON}' is not an executable python — set it to a valid interpreter."
  fi
  mkdir -p "${PREVIEW_DIR}"
  mkdir -p "${MUSICGEN_MODEL_DIR}"

  ensure_uv

  local need_install=true
  if [[ "$FORCE_INSTALL" != "true" && -d "${PREVIEW_DIR}/.venv" \
    && -x "${PREVIEW_DIR}/.venv/bin/python" && -f "${PREVIEW_DIR}/.installed" ]] \
    && "${PREVIEW_DIR}/.venv/bin/python" -c "import torch, transformers, soundfile" 2>/dev/null; then
    info "Preview venv already healthy — skipping package install (re-run converges)."
    need_install=false
  fi

  if [[ "$need_install" == "true" ]]; then
    (
      cd "${PREVIEW_DIR}"
      uv venv --python "${MUSIC_GEN_PYTHON}"
      # CPU torch wheels (no GPU needed on these boxes); model weights stay
      # out of the install — they download lazily on the first CLI run into
      # MUSICGEN_MODEL_DIR.
      uv pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu
      uv pip install transformers soundfile
    )
    date -u +%Y-%m-%dT%H:%M:%SZ > "${PREVIEW_DIR}/.installed"
    success "Preview venv installed (CPU torch + transformers + soundfile)"
  fi

  # The CLI is re-rendered on every run so content changes propagate
  # (converge by default); it is user-owned in $HOME.
  step "Writing ${PREVIEW_CLI}"
  local cli_tmp
  cli_tmp="$(mktempfile music-preview)"
  cat > "${cli_tmp}" <<'PYEOF'
#!/usr/bin/env bash
# music-preview — generate a short instrumental WAV with musicgen-small (CPU).
set -euo pipefail
set -a
# shellcheck disable=SC1091  # generated at install time
source "$(dirname "$0")/music-gen-preview/preview.env"
set +a

usage() {
  cat <<USAGE
Usage: music-preview [OPTIONS] "PROMPT"

Generate a short instrumental WAV with facebook/musicgen-small (CPU, slow).

Options:
  -l SECONDS  Audio length in seconds (default: 10, max ~30)
  -o PATH     Output WAV path (default: <MUSICGEN_MODEL_DIR>/preview-<ts>.wav)
  -h          Show this help
USAGE
}

LENGTH=10
OUT=""
PROMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -l) LENGTH="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) PROMPT="$1"; shift ;;
  esac
done
[[ -n "$PROMPT" ]] || { echo "ERROR: a prompt is required" >&2; usage; exit 1; }

# MusicGen generates in 30 s chunks (offset by 5 s).
if ! [[ "$LENGTH" =~ ^[0-9]+$ ]] || (( LENGTH < 1 || LENGTH > 30 )); then
  echo "ERROR: -l must be an integer number of seconds between 1 and 30" >&2
  exit 1
fi
[[ -n "$OUT" ]] || OUT="${MUSICGEN_MODEL_DIR}/preview-$(date +%Y%m%d-%H%M%S).wav"

exec "${MUSICGEN_PYTHON}" - "$PROMPT" "$LENGTH" "$OUT" <<'PY'
import os
import sys

import soundfile as sf
from transformers import pipeline

prompt, length, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]

# cache_dir: the weights are downloaded once (first run) into
# MUSICGEN_MODEL_DIR and reused afterwards, so re-runs never hit the network.
# NOTE: `AudioGenerator` (and from_pretrained's local_dir kwargs) were removed
# from transformers — the supported entry point for musicgen is the
# "text-to-audio" pipeline.
pipe = pipeline(
    task="text-to-audio",
    model="facebook/musicgen-small",
    device="cpu",
    cache_dir=os.environ["MUSICGEN_MODEL_DIR"],
)
# MusicGen produces 50 tokens per second of audio.
audio = pipe(prompt, forward_params={"max_new_tokens": length * 50})
sf.write(out, audio["audio"], samplerate=audio["sampling_rate"])
print(f"Wrote {out}")
PY
PYEOF
  install -m 755 -o "$(id -un)" -g "$(id -gn)" "${cli_tmp}" "${PREVIEW_CLI}"
  rm -f "${cli_tmp}"

  # Non-secret config the CLI resolves at run time (paths/interpreter only;
  # installed mode 600 via env_file_write — it holds no secrets).
  env_file_write "${PREVIEW_DIR}/preview.env" <<EOF
MUSICGEN_MODEL_DIR=${MUSICGEN_MODEL_DIR}
MUSICGEN_PYTHON=${PREVIEW_DIR}/.venv/bin/python
EOF

  success "CPU music preview is ready (musicgen-small; weights download on first run, ~2 GB)"
  info "Try: ${PREVIEW_CLI} 'lo-fi jazz with upright bass'"
  info "Model dir: ${MUSICGEN_MODEL_DIR} (set MUSICGEN_MODEL_DIR to move it)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "${MUSIC_GEN_MODE}" == "server" ]]; then
  setup_server
else
  setup_preview
fi
