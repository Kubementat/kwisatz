#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-music-gen.sh — Install Music Generation (ACE-Step 1.5 / MusicGen)
# =============================================================================
#
# Description:
#   Installs a music-generation stack in two modes:
#     server  — ACE-Step 1.5 song-generation REST API on AMD GPU hosts
#               (native systemd, ROCm 7.x, gfx1151 / Strix Halo)
#     preview — CPU-only MusicGen small CLI for non-GPU machines
#
# Options:
#   --force     Reinstall even if already installed at the expected version
#   --help      Display this help message
#
# Usage:
#   ./setup-music-gen.sh              # Install in server mode (default)
#   ./setup-music-gen.sh --force      # Reinstall / force reconfigure
#
# Environment variables:
#   MUSIC_GEN_MODE            'server' or 'preview' (default: server)
#   MUSIC_GEN_PORT            Port for the server API (default: 9294)
#   MUSIC_GEN_OPEN_LAN        Open firewall to LAN? true/false (default: false)
#   MUSIC_GEN_SMOKE_TEST      Run smoke test? true/false (default: true)
#   MUSIC_GEN_PYTHON          Python interpreter for uv venv (default: /usr/bin/python3)
#   ACESTEP_VERSION           Git tag to pin (default: v1.5)
#   ACESTEP_CHECKPOINTS_DIR   Where to store model checkpoints (default: /opt/ace-step/models)
#   ACESTEP_API_KEY           API key for the REST API — generated if empty
#   ACESTEP_OFFLOAD_TO_CPU    Enable CPU offload? true/false (default: false; 128 GB unified)
#   ACESTEP_LD_PRELOAD        LD_PRELOAD ROCm hsa runtime lib? true/false (default: false)
#   MUSICGEN_MODEL_DIR        Model dir for preview mode (default: ~/music-gen-preview/models)
#
# Examples:
#   ./setup-music-gen.sh                     # server mode, default port 9294
#   ./setup-music-gen.sh --force             # force reinstall
#   MUSIC_GEN_MODE=preview ./setup-music-gen.sh  # CPU preview mode
#   MUSIC_GEN_MODE=server MUSIC_GEN_PORT=8001 ./setup-music-gen.sh
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
# Configuration
# =============================================================================

# Mode: server (ACE-Step 1.5) or preview (MusicGen CPU)
MUSIC_GEN_MODE="${MUSIC_GEN_MODE:-server}"

# Server-mode defaults
MUSIC_GEN_PORT="${MUSIC_GEN_PORT:-9294}"
MUSIC_GEN_OPEN_LAN="${MUSIC_GEN_OPEN_LAN:-false}"
MUSIC_GEN_SMOKE_TEST="${MUSIC_GEN_SMOKE_TEST:-true}"
MUSIC_GEN_PYTHON="${MUSIC_GEN_PYTHON:-/usr/bin/python3}"
ACESTEP_VERSION="${ACESTEP_VERSION:-v1.5}"
ACESTEP_CHECKPOINTS_DIR="${ACESTEP_CHECKPOINTS_DIR:-/opt/ace-step/models}"
ACESTEP_API_KEY="${ACESTEP_API_KEY:-}"
ACESTEP_OFFLOAD_TO_CPU="${ACESTEP_OFFLOAD_TO_CPU:-false}"
ACESTEP_LD_PRELOAD="${ACESTEP_LD_PRELOAD:-false}"

# Preview-mode defaults
MUSICGEN_MODEL_DIR="${MUSICGEN_MODEL_DIR:-${HOME}/music-gen-preview/models}"

# Directories
ACE_STEP_DIR="/opt/ace-step/ACE-Step-1.5"
ACE_STEP_ENV="${ACE_STEP_DIR}/.env"
ACE_STEP_MARKER="/opt/ace-step/.installed-version"

PREVIEW_VENV_DIR="${HOME}/music-gen-preview"
PREVIEW_MARKER="${PREVIEW_VENV_DIR}/.installed-version"

# =============================================================================
# Help
# =============================================================================

show_help() {
  cat << 'EOF'
Usage: setup-music-gen.sh [OPTIONS]

Install a music-generation stack in two modes:

  server  — ACE-Step 1.5 song-generation REST API on AMD GPU hosts
            (native systemd, ROCm 7.x, gfx1151 / Strix Halo)
  preview — CPU-only MusicGen small CLI for non-GPU machines

Options:
  --force    Reinstall even if already installed at the expected version
  --help     Display this help message

Environment variables:
  MUSIC_GEN_MODE            'server' or 'preview' (default: server)
  MUSIC_GEN_PORT            Port for the server API (default: 9294)
  MUSIC_GEN_OPEN_LAN        Open firewall to LAN? true/false (default: false)
  MUSIC_GEN_SMOKE_TEST      Run smoke test? true/false (default: true)
  MUSIC_GEN_PYTHON          Python interpreter for uv venv (default: /usr/bin/python3)
  ACESTEP_VERSION           Git tag to pin (default: v1.5)
  ACESTEP_CHECKPOINTS_DIR   Where to store model checkpoints (default: /opt/ace-step/models)
  ACESTEP_API_KEY           API key for the REST API — generated if empty
  ACESTEP_OFFLOAD_TO_CPU    Enable CPU offload? true/false (default: false; 128 GB unified)
  ACESTEP_LD_PRELOAD        LD_PRELOAD ROCm hsa runtime lib? true/false (default: false)
  MUSICGEN_MODEL_DIR        Model dir for preview mode (default: ~/music-gen-preview/models)

Examples:
  ./setup-music-gen.sh                     # server mode, default port 9294
  ./setup-music-gen.sh --force             # force reinstall
  MUSIC_GEN_MODE=preview ./setup-music-gen.sh  # CPU preview mode
  MUSIC_GEN_MODE=server MUSIC_GEN_PORT=8001 ./setup-music-gen.sh
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
# Server mode: ACE-Step 1.5
# =============================================================================

install_server() {
  step "Setting up ACE-Step 1.5 server mode on ${ACE_STEP_DIR}"

  # --- Prerequisite: /dev/kfd must exist (ROCm device) -----------------------
  if [[ ! -e /dev/kfd ]]; then
    error "/dev/kfd not found — this host lacks ROCm device support. Use MUSIC_GEN_MODE=preview for CPU-only mode."
  fi

  # --- gfx1151 guard: refuse HSA_OVERRIDE_GFX_VERSION ------------------------
  # The repo's start_*_rocm scripts set HSA_OVERRIDE_GFX_VERSION for RDNA2/3
  # consumer cards. On gfx1151 (Strix Halo) this breaks ("no matching kernel
  # image"). Detect and abort if it is set.
  if rocminfo 2>/dev/null | grep -q gfx1151; then
    if [[ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]]; then
      error "HSA_OVERRIDE_GFX_VERSION is set (${HSA_OVERRIDE_GFX_VERSION}) but this host is gfx1151 (Strix Halo). The override targets RDNA2/3 consumer cards and breaks gfx1151. Unset HSA_OVERRIDE_GFX_VERSION and re-run."
    fi
  fi

  # --- Prepare install directory ---------------------------------------------
  step "Preparing install directory ${ACE_STEP_DIR}"
  if [[ ! -d "${ACE_STEP_DIR}" ]]; then
    sudo mkdir -p "$(dirname "${ACE_STEP_DIR}")"
    sudo chown "${USER}" "$(dirname "${ACE_STEP_DIR}")"
  else
    info "Install directory already exists at ${ACE_STEP_DIR}"
  fi

  # --- Bootstrap uv (astral.sh installer) ------------------------------------
  step "Ensuring uv is available"
  if ! command -v uv &>/dev/null; then
    step "Installing uv via astral.sh"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Source the newly installed uv into PATH
    export PATH="${HOME}/.local/bin:${PATH}"
    if ! command -v uv &>/dev/null; then
      error "uv installation failed — could not find uv after astral.sh install"
    fi
    success "uv installed to ${HOME}/.local/bin/uv"
  else
    info "uv already available: $(uv --version)"
  fi

  # --- Idempotency check: version marker ------------------------------------
  INSTALLED_VERSION=""
  if [[ -f "${ACE_STEP_MARKER}" ]]; then
    INSTALLED_VERSION="$(cat "${ACE_STEP_MARKER}")"
  fi

  if [[ "${INSTALLED_VERSION}" == "${ACESTEP_VERSION}" ]] && [[ "${FORCE_INSTALL}" != "true" ]]; then
    success "ACE-Step ${ACESTEP_VERSION} already installed (marker: ${ACE_STEP_MARKER}). Skipping clone and dependency install."
    info "Re-rendering configuration and restarting service..."
  else
    if [[ -n "${INSTALLED_VERSION}" ]]; then
      info "Installed version (${INSTALLED_VERSION}) differs from target (${ACESTEP_VERSION}), upgrading."
    else
      info "No version marker found — performing fresh install."
    fi

    # --- Clone the repo (if not already cloned) ----------------------------
    if [[ ! -d "${ACE_STEP_DIR}/.git" ]]; then
      step "Cloning ACE-Step-1.5 (tag: ${ACESTEP_VERSION})"
      git clone "https://github.com/ACE-Step/ACE-Step-1.5.git" "${ACE_STEP_DIR}"
    fi
    step "Checking out tag ${ACESTEP_VERSION}"
    cd "${ACE_STEP_DIR}"
    git fetch --all 2>/dev/null || true
    git checkout "${ACESTEP_VERSION}" 2>/dev/null || git checkout -b "${ACESTEP_VERSION}" "${ACESTEP_VERSION}"
    cd - >/dev/null

    # --- Create uv venv ----------------------------------------------------
    step "Creating uv venv with Python ${MUSIC_GEN_PYTHON}"
    cd "${ACE_STEP_DIR}"
    uv venv --python "${MUSIC_GEN_PYTHON}"
    cd - >/dev/null

    # --- Install ROCm PyTorch FIRST, then ACE-Step deps -------------------
    # uv must not replace ROCm torch with a CUDA wheel.
    step "Installing ROCm PyTorch and torchaudio"
    cd "${ACE_STEP_DIR}"
    uv pip install torch torchaudio --index-url https://download.pytorch.org/whl/rocm7.1
    uv sync --no-install-package torch --no-install-package torchaudio
    cd - >/dev/null

    # --- Write version marker ---------------------------------------------
    step "Writing version marker"
    echo "${ACESTEP_VERSION}" > "${ACE_STEP_MARKER}"
  fi

  # --- GPU smoke test -------------------------------------------------------
  step "Verifying GPU detection"
  cd "${ACE_STEP_DIR}"
  GPU_INFO="$(uv run python -c "
import torch
print(torch.__version__)
print(torch.cuda.is_available())
print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')
" 2>&1)" || {
    error "GPU smoke test failed — PyTorch/ROCm cannot detect the GPU. Check ROCm installation and groups (render, video)."
  }
  GPU_IS_AVAILABLE="$(echo "${GPU_INFO}" | sed -n '2p')"
  if [[ "${GPU_IS_AVAILABLE}" != "True" ]]; then
    error "GPU smoke test: torch.cuda.is_available() returned False. ROCm PyTorch is not detecting the GPU."
  fi
  info "GPU smoke test passed: ${GPU_INFO}"
  cd - >/dev/null

  # --- Write .env (never clobber existing ACESTEP_API_KEY) ------------------
  step "Writing .env configuration"
  # Read back any existing API key — never clobber it on re-run
  EXISTING_KEY="$(env_file_get "${ACE_STEP_ENV}" "ACESTEP_API_KEY" 2>/dev/null || echo "")"
  if [[ -z "${EXISTING_KEY}" ]]; then
    ACESTEP_API_KEY="$(openssl rand -hex 32)"
    info "Generated new ACESTEP_API_KEY"
  else
    ACESTEP_API_KEY="${EXISTING_KEY}"
    info "Reusing existing ACESTEP_API_KEY from .env"
  fi

  # Render env file to a mktemp, then install with correct ownership/permissions
  env_file_write "${ACE_STEP_ENV}" <<EOF
# ACE-Step 1.5 server configuration
# Generated by setup-music-gen.sh — re-rendered on every run

# vLLM LM backend is CUDA-only; use PyTorch
ACESTEP_LM_BACKEND=pt

# MIOpen search strategy
MIOPEN_FIND_MODE=FAST

# Where to store model checkpoints (override via ACESTEP_CHECKPOINTS_DIR env)
ACESTEP_CHECKPOINTS_DIR=${ACESTEP_CHECKPOINTS_DIR}

# API authentication key — generated on first install, reused on re-runs
ACESTEP_API_KEY=${ACESTEP_API_KEY}

# 128 GB unified memory: XL fits without offload
ACESTEP_OFFLOAD_TO_CPU=${ACESTEP_OFFLOAD_TO_CPU}
EOF

  # --- Write systemd service unit -------------------------------------------
  step "Configuring ace-step.service"
  UNIT_FILE="/etc/systemd/system/ace-step.service"
  unit_tmp="$(mktempfile ace-step.service)"

  # Build LD_PRELOAD line (optional, only when explicitly enabled)
  LD_PRELOAD_LINE=""
  if [[ "${ACESTEP_LD_PRELOAD}" == "true" ]]; then
    LD_PRELOAD_LINE="Environment=LD_PRELOAD=/opt/rocm/lib/libhsa-runtime64.so.1  # only if the torch smoke test segfaults"
  fi

  cat > "${unit_tmp}" <<EOF
[Unit]
Description=ACE-Step 1.5 song generation REST API
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${ACE_STEP_DIR}
EnvironmentFile=${ACE_STEP_ENV}
Environment=ACESTEP_LM_BACKEND=pt
Environment=-PYTORCH_HIP_ALLOC_CONF  # unset it, HIP alloc conf breaks ROCm here
${LD_PRELOAD_LINE}
ExecStart=${ACE_STEP_DIR}/.venv/bin/uv run acestep-api --host 0.0.0.0 --port ${MUSIC_GEN_PORT} --config_path acestep-v15-xl-turbo --lm_model_path acestep-5Hz-lm-1.7B
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ace-step
SupplementaryGroups=render video

[Install]
WantedBy=multi-user.target
EOF

  # Install (always re-render; enable on first run, restart on converge)
  if [[ ! -f "${UNIT_FILE}" ]]; then
    sudo install -m 644 "${unit_tmp}" "${UNIT_FILE}"
    sudo systemctl daemon-reload
    sudo systemctl enable --now ace-step.service >/dev/null 2>&1 || \
      sudo systemctl enable ace-step.service >/dev/null 2>&1 || true
    info "New service file installed — enabled."
  elif ! cmp -s "${unit_tmp}" "${UNIT_FILE}"; then
    sudo install -m 644 "${unit_tmp}" "${UNIT_FILE}"
    sudo systemctl daemon-reload
    if sudo systemctl is-active ace-step.service &>/dev/null; then
      sudo systemctl restart ace-step.service
      info "Service restarted (unit file changed)."
    else
      sudo systemctl start ace-step.service
      info "Service started (unit file changed)."
    fi
  fi
  rm -f "${unit_tmp}"

  # --- UFW firewall rule (optional, LAN access) -----------------------------
  if [[ "${MUSIC_GEN_OPEN_LAN}" == "true" ]] && ufw_available; then
    if ! ufw_rule_exists "${MUSIC_GEN_PORT}" tcp; then
      ufw_add_rule "${MUSIC_GEN_PORT}" tcp
    else
      info "UFW rule for port ${MUSIC_GEN_PORT}/tcp already exists, skipping."
    fi
  fi

  # --- Smoke test -----------------------------------------------------------
  if [[ "${MUSIC_GEN_SMOKE_TEST}" == "true" ]]; then
    step "Running smoke test (polling http://127.0.0.1:${MUSIC_GEN_PORT}/docs)"
    local smoke_timeout="${SMOKE_TEST_TIMEOUT:-300}"
    local elapsed=0
    while ! curl -fsSL "http://127.0.0.1:${MUSIC_GEN_PORT}/docs" >/dev/null 2>&1; do
      sleep 2
      elapsed=$((elapsed + 2))
      if (( elapsed >= smoke_timeout )); then
        error "Smoke test: service did not become ready at http://127.0.0.1:${MUSIC_GEN_PORT}/docs after ${smoke_timeout}s"
      fi
    done
    success "Service is responding at http://127.0.0.1:${MUSIC_GEN_PORT}/docs"

    # Submit a generation task
    info "Submitting test generation (10s audio, FLAC)"
    local task_id
    task_id="$(curl -fsSL -X POST "http://127.0.0.1:${MUSIC_GEN_PORT}/release_task" \
      -H "Authorization: Bearer ${ACESTEP_API_KEY}" \
      -H 'Content-Type: application/json' \
      -d '{"prompt":"test","thinking":false,"audio_duration":10,"audio_format":"flac"}' \
      | jq -r '.data.task_id')" || {
      error "Smoke test: failed to submit generation task"
    }
    if [[ -z "${task_id}" || "${task_id}" == "null" ]]; then
      error "Smoke test: /release_task did not return a task_id"
    fi
    info "Task submitted: ${task_id}"

    # Poll for completion
    local poll_elapsed=0
    local poll_timeout=600  # 10 minutes max for generation
    while true; do
      sleep 5
      poll_elapsed=$((poll_elapsed + 5))
      if (( poll_elapsed >= poll_timeout )); then
        error "Smoke test: generation did not complete within ${poll_timeout}s"
      fi
      local status
      status="$(curl -fsSL -X POST "http://127.0.0.1:${MUSIC_GEN_PORT}/query_result" \
        -H "Authorization: Bearer ${ACESTEP_API_KEY}" \
        -H 'Content-Type: application/json' \
        -d "{\"task_ids\":[\"${task_id}\"]}" \
        | jq -r '.data[0].status' 2>/dev/null || echo "")"
      if [[ "${status}" == "1" ]]; then
        success "Smoke test passed: generation completed (status=1)"
        break
      elif [[ "${status}" == "2" ]]; then
        error "Smoke test: generation failed (status=2)"
      fi
      info "Generation in progress (status=${status}, elapsed=${poll_elapsed}s)..."
    done
  else
    info "Smoke test skipped (MUSIC_GEN_SMOKE_TEST=false)"
  fi

  success "ACE-Step 1.5 server mode installed successfully"
  info "Service: ace-step.service (port ${MUSIC_GEN_PORT})"
  info "API docs: http://127.0.0.1:${MUSIC_GEN_PORT}/docs"
}

# =============================================================================
# Preview mode: CPU-only MusicGen CLI
# =============================================================================

install_preview() {
  step "Setting up MusicGen preview mode (CPU) at ${PREVIEW_VENV_DIR}"

  # --- Bootstrap uv if needed -----------------------------------------------
  step "Ensuring uv is available"
  if ! command -v uv &>/dev/null; then
    step "Installing uv via astral.sh"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${HOME}/.local/bin:${PATH}"
    if ! command -v uv &>/dev/null; then
      error "uv installation failed — could not find uv after astral.sh install"
    fi
    success "uv installed to ${HOME}/.local/bin/uv"
  else
    info "uv already available: $(uv --version)"
  fi

  # --- Idempotency check: version marker ------------------------------------
  INSTALLED_VERSION=""
  if [[ -f "${PREVIEW_MARKER}" ]]; then
    INSTALLED_VERSION="$(cat "${PREVIEW_MARKER}")"
  fi

  if [[ "${INSTALLED_VERSION}" == "musicgen-small" ]] && [[ "${FORCE_INSTALL}" != "true" ]]; then
    success "MusicGen preview already installed (marker: ${PREVIEW_MARKER}). Skipping venv creation."
    info "Re-creating CLI wrapper and ensuring model dir..."
  else
    if [[ -n "${INSTALLED_VERSION}" ]]; then
      info "Installed version (${INSTALLED_VERSION}) differs from expected, recreating."
    else
      info "No version marker found — performing fresh install."
    fi

    # --- Create venv and install deps --------------------------------------
    step "Creating uv venv at ${PREVIEW_VENV_DIR}"
    mkdir -p "${PREVIEW_VENV_DIR}"
    cd "${PREVIEW_VENV_DIR}"
    uv venv --python "${MUSIC_GEN_PYTHON}"

    # CPU PyTorch wheels
    step "Installing CPU PyTorch, torchaudio, transformers, soundfile"
    uv pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu
    uv pip install transformers soundfile
    cd - >/dev/null

    # --- Write version marker ---------------------------------------------
    step "Writing version marker"
    echo "musicgen-small" > "${PREVIEW_MARKER}"
  fi

  # --- Write CLI wrapper ----------------------------------------------------
  step "Installing CLI wrapper at ~/music-preview"
  cat > "${HOME}/music-preview" <<'EOF'
#!/usr/bin/env bash
# shellcheck shell=bash
# music-preview — Generate audio from text using MusicGen small (CPU)
#
# Usage: music-preview [OPTIONS] "text prompt"
#   --length SECONDS   Audio length in seconds (default: 10)
#   -o FILE            Output file path (default: ~/music-gen-preview/preview.wav)
set -euo pipefail

PROMPT=""
LENGTH=10
OUTPUT="${HOME}/music-gen-preview/preview.wav"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --length)
      LENGTH="$2"; shift 2 ;;
    -o)
      OUTPUT="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: music-preview [OPTIONS] \"text prompt\""
      echo ""
      echo "Options:"
      echo "  --length SECONDS   Audio length in seconds (default: 10)"
      echo "  -o FILE            Output file path (default: ~/music-gen-preview/preview.wav)"
      echo "  --help             Show this help message"
      exit 0
      ;;
    *)
      PROMPT="$1"; shift ;;
  esac
done

if [[ -z "${PROMPT}" ]]; then
  echo "Error: text prompt is required" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT}")"

# Resolve model dir
MODEL_DIR="${MUSICGEN_MODEL_DIR:-${HOME}/music-gen-preview/models}"

# Run the generation via the uv venv
exec "${HOME}/music-gen-preview/.venv/bin/python" - "${PROMPT}" "${LENGTH}" "${OUTPUT}" "${MODEL_DIR}" <<'PYEOF'
import sys
import soundfile as sf
import torch
from transformers import AutoProcessor, MusicgenForConditionalGeneration

prompt = sys.argv[1]
duration = int(sys.argv[2])
output_path = sys.argv[3]
model_dir = sys.argv[4]

print(f"Loading model from {model_dir}...")
processor = AutoProcessor.from_pretrained(
    "facebook/musicgen-small",
    local_dir=model_dir,
)
model = MusicgenForConditionalGeneration.from_pretrained(
    "facebook/musicgen-small",
    local_dir=model_dir,
)

print(f"Generating {duration}s of audio from: {prompt}")
inputs = processor(text=[prompt], return_tensors="pt", padding=True)

with torch.no_grad():
    audio_values = model.generate(**inputs, max_new_tokens=duration * 50)

audio = audio_values.cpu().numpy().squeeze()
sample_rate = model.config.audio_encoder.sampling_rate
sf.write(output_path, audio, sample_rate)
print(f"Saved to {output_path}")
PYEOF
EOF
  chmod +x "${HOME}/music-preview"

  # --- Ensure model directory exists ----------------------------------------
  mkdir -p "${MUSICGEN_MODEL_DIR}"

  success "MusicGen preview mode installed successfully"
  info "CLI: ~/music-preview \"your prompt\" --length 10 -o output.wav"
  info "Model downloads lazily on first CLI run to ${MUSICGEN_MODEL_DIR}"
}

# =============================================================================
# Main
# =============================================================================

case "${MUSIC_GEN_MODE}" in
  server)
    install_server
    ;;
  preview)
    install_preview
    ;;
  *)
    error "Unknown MUSIC_GEN_MODE='${MUSIC_GEN_MODE}'. Must be 'server' or 'preview'."
    ;;
esac
