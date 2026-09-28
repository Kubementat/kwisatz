#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# =============================================================================
# setup-laya.sh — Install Laya (System 1 decision model) for llama-swap
# =============================================================================
#
# DESCRIPTION:
#   Installs "laya[serve]" (the official PyTorch + FastAPI server, see
#   docs/research/laya-system1-model-research.md §6.1) into an isolated
#   Python venv. Laya is not a llama.cpp/GGUF model — it is a Python package
#   exposing a `laya-serve` binary. llama-swap spawns it the same way it
#   spawns llama-server: on demand, via a `cmd` entry in config.yaml. This
#   script only installs the package; it prints the model block to paste
#   into config.yaml because setup-llama-swap.sh never touches an existing
#   config (manual edits are preserved by design — see its header).
#
# KEY ACTIONS:
#   1. Pre-flight checks: python3, pip, venv module
#   2. Creates/reuses a venv at LAYA_DIR/venv
#   3. Installs (or upgrades, with --force) laya[serve] into the venv
#   4. Writes/prints the llama-swap model YAML block to
#      LAYA_DIR/llama-swap-configuration.yml, to paste into config.yaml
#   5. Writes a convenience start script to LAYA_DIR/start-laya.sh for
#      running laya-serve directly (without llama-swap)
#
# IMPORTANT VARIABLES:
#   LAYA_DIR      - Install directory for the venv (default: /srv/laya)
#   LAYA_VERSION  - laya[serve] version to pin (default: 0.3.19)
#   LAYA_MODEL_ID - Model ID to use in the llama-swap config (default: laya)
#   LAYA_DEVICE   - cpu|cuda for LAYA_DEVICE env var (default: auto-detect)
#
# USAGE:
#   ./setup-laya.sh                # install/reuse venv, print config snippet
#   ./setup-laya.sh --check        # check installation status only
#   ./setup-laya.sh --force        # reinstall/upgrade the package
#   ./setup-laya.sh --help         # show help and exit
#
# REFERENCE:
#   docs/research/laya-system1-model-research.md
#   https://huggingface.co/convaiinnovations/laya
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/laya")"

# shellcheck source=../lib/helpers.sh
source "${LIB_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

LAYA_DIR="${LAYA_DIR:-/srv/laya}"
LAYA_VERSION="${LAYA_VERSION:-0.3.19}"
LAYA_MODEL_ID="${LAYA_MODEL_ID:-laya}"
LAYA_DEVICE="${LAYA_DEVICE:-}"   # empty = auto-detect below

CHECK_ONLY=0
FORCE=0

VENV_DIR="${LAYA_DIR}/venv"
VENV_PIP="${VENV_DIR}/bin/pip"
VENV_LAYA_SERVE="${VENV_DIR}/bin/laya-serve"

# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs "laya[serve]" (self-hosted Laya System 1 decision model server,
see docs/research/laya-system1-model-research.md) into an isolated Python
venv, writes a convenience start script (LAYA_DIR/start-laya.sh) to run the
server directly, and prints the llama-swap model block to paste into
config.yaml so llama-swap spawns and proxies it like any other backend.

${BOLD}Options:${RESET}
  --check        Check installation status only (no changes)
  --force        Reinstall/upgrade the laya[serve] package
  -h, --help     Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  LAYA_DIR       Install directory for the venv (default: /srv/laya)
  LAYA_VERSION   laya[serve] version to pin (default: 0.3.19)
  LAYA_MODEL_ID  Model ID to use in the llama-swap config (default: laya)
  LAYA_DEVICE    cpu|cuda for the LAYA_DEVICE env var (default: auto-detect
                 via nvidia-smi)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

if ! command -v python3 &>/dev/null; then
  error "python3 is not installed. Run tasks/setup-basics.sh first."
fi
if ! python3 -m venv --help &>/dev/null; then
  error "python3 'venv' module is not available. Install with: sudo apt-get install python3-venv"
fi
success "python3 $(python3 --version | awk '{print $2}') detected."

if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Required for template rendering. Install with: sudo apt-get install gettext-base"
fi

if [[ -z "$LAYA_DEVICE" ]]; then
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    LAYA_DEVICE="cuda"
  else
    LAYA_DEVICE="cpu"
  fi
fi
info "LAYA_DEVICE=${LAYA_DEVICE}"

# ─────────────────────────────────────────────────────────────────────────────
# CHECK-ONLY MODE
# ─────────────────────────────────────────────────────────────────────────────

print_status() {
  if [[ -x "$VENV_LAYA_SERVE" ]]; then
    success "Venv found at ${VENV_DIR}"
    "$VENV_PIP" show laya 2>/dev/null | grep -E '^(Name|Version)' | sed 's/^/    /'
    if [[ -f "${LAYA_DIR}/llama-swap-configuration.yml" ]]; then
      success "llama-swap snippet at ${LAYA_DIR}/llama-swap-configuration.yml"
    fi
    if [[ -x "${LAYA_DIR}/start-laya.sh" ]]; then
      success "Start script at ${LAYA_DIR}/start-laya.sh"
    fi
  else
    warn "No laya[serve] install found at ${VENV_DIR}."
    info "Run without --check to install."
  fi
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  step "Checking for existing Laya installation"
  print_status
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# CREATE VENV
# ─────────────────────────────────────────────────────────────────────────────

step "Setting up venv at ${VENV_DIR}"

if [[ ! -d "$LAYA_DIR" ]]; then
  sudo mkdir -p "$LAYA_DIR"
  sudo chown "$(id -u):$(id -g)" "$LAYA_DIR"
fi

if [[ -x "${VENV_DIR}/bin/python" ]]; then
  success "Venv already exists."
else
  python3 -m venv "$VENV_DIR"
  success "Venv created."
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL laya[serve]
# ─────────────────────────────────────────────────────────────────────────────

step "Installing laya[serve]==${LAYA_VERSION}"

INSTALLED_VERSION="$("$VENV_PIP" show laya 2>/dev/null | sed -n 's/^Version: //p')"

if [[ -x "$VENV_LAYA_SERVE" && "$INSTALLED_VERSION" == "$LAYA_VERSION" && "$FORCE" -eq 0 ]]; then
  success "laya[serve] ${INSTALLED_VERSION} already installed. Use --force to reinstall."
else
  "$VENV_PIP" install --upgrade pip --quiet
  "$VENV_PIP" install "laya[serve]==${LAYA_VERSION}"
  success "laya[serve] ${LAYA_VERSION} installed at ${VENV_DIR}."
fi

[[ -x "$VENV_LAYA_SERVE" ]] || error "Install finished but ${VENV_LAYA_SERVE} is missing — check pip output above."

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY — llama-swap wiring
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Laya installed!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Venv${RESET}   ${VENV_DIR}"
echo -e "  ${BOLD}Binary${RESET} ${VENV_LAYA_SERVE}"
echo -e "  ${BOLD}Start${RESET}  ${LAYA_DIR}/start-laya.sh  (run laya-serve directly, without llama-swap)"
echo ""
SNIPPET_FILE="${LAYA_DIR}/llama-swap-configuration.yml"

export LAYA_MODEL_ID VENV_LAYA_SERVE LAYA_DEVICE
# '${PORT}' is left un-substituted (not in this list) — it stays a literal
# llama-swap macro, resolved per-model when llama-swap itself spawns cmd.
envsubst '${LAYA_MODEL_ID} ${VENV_LAYA_SERVE} ${LAYA_DEVICE}' \
  < "${TEMPLATE_DIR}/llama-swap-configuration.yml" \
  > "$SNIPPET_FILE"
success "Snippet written to ${SNIPPET_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# CONVENIENCE START SCRIPT
# ─────────────────────────────────────────────────────────────────────────────

START_SCRIPT="${LAYA_DIR}/start-laya.sh"
envsubst '${VENV_LAYA_SERVE} ${LAYA_DEVICE}' \
  < "${TEMPLATE_DIR}/start-laya.sh" \
  > "$START_SCRIPT"
chmod 755 "$START_SCRIPT"
success "Start script written to ${START_SCRIPT}"
echo ""
echo -e "${YELLOW}  Next step:${RESET} add this model to llama-swap's config.yaml"
echo -e "  (setup-llama-swap.sh never touches an existing config — add it by hand):"
echo ""
cat "$SNIPPET_FILE"
echo ""
echo -e "  Then: sudo systemctl restart llama-swap"
echo -e "  Test: curl http://localhost:9292/v1/models"
echo ""
echo -e "  Or skip llama-swap entirely: ${LAYA_DIR}/start-laya.sh"
echo -e "  (foreground, 127.0.0.1:8000 by default — override with LAYA_HOST/LAYA_PORT/LAYA_DEVICE)"
echo ""
echo -e "  Laya answers on POST /v1/systemone (typed choice/score/noul questions,"
echo -e "  not chat completions) — see docs/research/laya-system1-model-research.md."
echo -e "  checkEndpoint uses FastAPI's default /docs page since laya-serve does"
echo -e "  not document a dedicated /health route; adjust if that changes."
