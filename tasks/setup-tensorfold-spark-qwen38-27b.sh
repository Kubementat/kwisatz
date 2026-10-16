#!/usr/bin/env bash
# shellcheck disable=SC1091
# =============================================================================
# setup-tensorfold-spark-qwen38-27b.sh
# Installs Qwen3.8-27B on one NVIDIA DGX Spark (GB10, 128 GB unified memory)
# via TensorFold v0.6.0 (Python engine, tensorfold-qwen38-27b), managed by
# llama-swap. There is no standalone stack: llama-swap owns the container
# lifecycle (serve.cmd runs the upstream start.sh, cmdStop stops it) and
# proxies the OpenAI API from port 9292 to TensorFold on TENSORFOLD_27B_PORT
# (default 8889 — Flash Next holds 8888).
#
# Upstream recipe (pinned):
#   https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-TensorFold
#   recipe commit ${TENSORFOLD_27B_RECIPE_REF} (main @ 2026-10-01); the
#   TensorFold engine is pinned inside the recipe (TF_VERSION v0.6.0, patches
#   hash fb91a0019fdc, image tensorfold-qwen38-27b:v0.6.0) and applied by
#   scripts/prepare.sh. NOTE: the checkpoints (Vontra/Qwen3.8-27B-MLX-4bit,
#   z-lab/Qwen3.8-27B-DFlash2) are NOT revision-pinned — prepare.sh downloads
#   the latest revision.
#
# Workflow (all steps idempotent, converge on re-run):
#   1. pre-flight: docker, CDI GPU spec, DGX Spark, disk, hf CLI, llama-swap
#   2. clone the recipe into /srv/tensorfold-27b (re-run: fetch + checkout pin)
#   3. run upstream scripts/prepare.sh (prebuilt image + ~19 GB checkpoints)
#   4. merge the qwen3.8-27b-tf entry into models.yml (additive; the entry is
#      replaced if the rendered template changed)
#   5. run tasks/sync-models.py (merge into llama-swap config.yaml, restart
#      only on change, poll /health)
#   6. smoke test through llama-swap (first load: 19 GB weights + one-time
#      CUDA kernel compile)
#
# Usage:
#   ./setup-tensorfold-spark-qwen38-27b.sh            # install / converge
#   ./setup-tensorfold-spark-qwen38-27b.sh --check    # show status and exit
#   ./setup-tensorfold-spark-qwen38-27b.sh --force    # stop the running model, force re-merge
#   ./setup-tensorfold-spark-qwen38-27b.sh --help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/tensorfold-spark-qwen38-27b"
REPO_ROOT="${SCRIPT_DIR}/.."

# shellcheck source=../lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

# ── Pinned upstream recipe ────────────────────────────────────────────────────
TENSORFOLD_27B_REPO="https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-TensorFold"
TENSORFOLD_27B_RECIPE_REF="c11ff138871cf43d12898d79dbfa4dc952d17ca4"
# Free disk needed before the checkpoint download: ~19 GiB checkpoints +
# ~35 GiB image + margin (upstream: MIN_FREE_GB=25 + IMAGE_FREE_GB=35).
TENSORFOLD_27B_MIN_FREE_GB=60

# Named -tf: qwen3.8-27b is already taken by the llama.cpp GGUF entry in
# models.yml.default — both runtimes of the same model coexist in llama-swap.
TENSORFOLD_27B_MODEL_NAME="qwen3.8-27b-tf"
TENSORFOLD_27B_CONTAINER="qwen38-27b-tf"

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_DIR="${PROJECT_DIR:-/srv/tensorfold-27b}"
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"
# Kernel cache + lock files + prepared marker. NOT $HOME: llama-swap runs
# start.sh as root with ProtectHome=read-only, and the 27B recipe flocks
# $KERNEL_CACHE/.start.lock and writes $KERNEL_CACHE/.prepared at load time.
KERNEL_CACHE_DIR="${KERNEL_CACHE_DIR:-${PROJECT_DIR}/.cache}"
TENSORFOLD_27B_PORT="${TENSORFOLD_27B_PORT:-8889}"
LLAMA_SWAP_PORT="${LLAMA_SWAP_PORT:-9292}"
LLAMA_SWAP_DIR="${LLAMA_SWAP_DIR:-/srv/llama-swap}"
SKIP_SMOKE=0
# Seconds for llama-swap to wait for a first load (19 GB weights + one-time
# CUDA kernel compile).
TENSORFOLD_27B_HEALTH_TIMEOUT="${TENSORFOLD_27B_HEALTH_TIMEOUT:-600}"

FORCE=0
CHECK_ONLY=0

# ── Input validation ──────────────────────────────────────────────────────────

validate_port() {
  local name="$1" port="$2"
  if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
    error "${name} must be a number between 1 and 65535 (got: ${port})."
  fi
}

validate_port TENSORFOLD_27B_PORT "$TENSORFOLD_27B_PORT"
validate_port LLAMA_SWAP_PORT "$LLAMA_SWAP_PORT"
if [[ ! "$TENSORFOLD_27B_HEALTH_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  error "TENSORFOLD_27B_HEALTH_TIMEOUT must be a positive integer (seconds)."
fi

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
  echo -e "${BOLD}Usage:${RESET} $0 [OPTIONS]"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo "  --port <n>               TensorFold API port the container binds on the"
  echo "                           host network; llama-swap proxies to it (default: 8889)"
  echo "  --health-timeout <s>     Seconds a first model load may take (19 GB"
  echo "                           weights + one-time kernel compile; default: 600). Raises"
  echo "                           llama-swap's global healthCheckTimeout to at least this"
  echo "                           value (the field is global in llama-swap, not per-model)"
  echo "                           and bounds the smoke-test wait."
  echo "  --dir <path>             Recipe checkout + service dir (default: /srv/tensorfold-27b)"
  echo "  --hf-cache <path>        Host HuggingFace cache dir (default: ~/.cache/huggingface)"
  echo "  --kernel-cache <path>    Kernel cache + lock files + prepared marker"
  echo "                           (default: /srv/tensorfold-27b/.cache)"
  echo "  --force                  Stop the running model first (upstream stop.sh) and"
  echo "                           force the catalog re-merge even if unchanged"
  echo "  --skip-smoke             Skip the post-install smoke test through llama-swap"
  echo "  --check                  Show installation status and exit"
  echo "  --help                   Show this help"
  echo ""
  echo -e "${BOLD}Environment variables${RESET} (all flags above have env-var equivalents):"
  echo "  TENSORFOLD_27B_PORT, TENSORFOLD_27B_HEALTH_TIMEOUT, PROJECT_DIR, HF_CACHE_DIR,"
  echo "  KERNEL_CACHE_DIR, LLAMA_SWAP_PORT, LLAMA_SWAP_DIR"
  echo ""
  echo -e "${BOLD}Requirements:${RESET}"
  echo "  One DGX Spark (GB10, 128 GB unified memory) with nothing else large on"
  echo "  the GPU (~97 GiB resident at the full auto KV pool), Docker with the"
  echo "  NVIDIA container toolkit (setup-nvidia-container.sh first), llama-swap"
  echo "  (setup-llama-swap.sh first), ~60 GB free disk, 'hf' CLI"
  echo "  (pip install -U \"huggingface_hub[cli]\"). Does NOT coexist with"
  echo "  Flash Next (setup-tensorfold-spark-qwen38-flash.sh) at defaults — use llama-swap's"
  echo "  one-model-at-a-time swap."
  echo ""
  echo -e "${BOLD}Runtime model:${RESET}"
  echo "  The model is NOT a standalone stack. llama-swap starts the container"
  echo "  on demand (serve.cmd = upstream start.sh, blocking) and stops it via"
  echo "  cmdStop; the OpenAI API is consumed through llama-swap:"
  echo "    http://localhost:${LLAMA_SWAP_PORT}/v1  (model: ${TENSORFOLD_27B_MODEL_NAME})"
  echo "  Serve levers (context, parallel, KV pool, YaRN, vision, ...) are upstream"
  echo "  settings: add them to ${PROJECT_DIR}/.env (see scripts/config.sh there)."
  echo ""
  echo -e "${BOLD}Re-run policy${RESET} (converge by default):"
  echo "  Re-running converges: the checkout is re-pinned (fetch + checkout), the"
  echo "  .env is re-rendered, prepare.sh is a no-op when ready, the catalog"
  echo "  entry is replaced only if the rendered template changed, and"
  echo "  sync-models.py restarts llama-swap only when its config changed."
  echo "  Changing --port on an existing install does NOT converge the llama-swap"
  echo "  config entry (add-only sync): delete the entry from ${LLAMA_SWAP_DIR}/config/config.yaml"
  echo "  and re-run."
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)             shift; TENSORFOLD_27B_PORT="$1" ;;
    --health-timeout)   shift; TENSORFOLD_27B_HEALTH_TIMEOUT="$1" ;;
    --dir)              shift; PROJECT_DIR="$1" ;;
    --hf-cache)         shift; HF_CACHE_DIR="$1" ;;
    --kernel-cache)     shift; KERNEL_CACHE_DIR="$1" ;;
    --force)            FORCE=1 ;;
    --skip-smoke)       SKIP_SMOKE=1 ;;
    --check)            CHECK_ONLY=1 ;;
    --help|-h)          usage ;;
    *) error "Unknown option: $1  (use --help for usage)" ;;
  esac
  shift
done

# ── --check ───────────────────────────────────────────────────────────────────

check_status() {
  echo ""
  echo -e "${BOLD}tensorfold-27b status${RESET}"
  echo ""
  if [[ -d "${PROJECT_DIR}/.git" ]]; then
    local head
    head="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
    if [[ "$head" == "${TENSORFOLD_27B_RECIPE_REF:0:7}" ]]; then
      echo -e "  ${BOLD}Recipe:${RESET}      ${GREEN}pinned${RESET} (${head})"
    else
      echo -e "  ${BOLD}Recipe:${RESET}      ${YELLOW}${head}${RESET} (expected ${TENSORFOLD_27B_RECIPE_REF:0:7} — re-run without --check to converge)"
    fi
  else
    echo -e "  ${BOLD}Recipe:${RESET}      ${YELLOW}not installed${RESET} (${PROJECT_DIR})"
  fi
  if [[ -f "${KERNEL_CACHE_DIR}/.prepared" ]]; then
    echo -e "  ${BOLD}Prepared:${RESET}    ${GREEN}image + checkpoints ready${RESET}"
  else
    echo -e "  ${BOLD}Prepared:${RESET}    ${YELLOW}no — prepare.sh has not completed${RESET}"
  fi
  local catalog="${REPO_ROOT}/models.yml"
  # -A1: require 'type: local' right after — a same-named remote entry must not
  # count as the local tensorfold entry.
  if [[ -f "$catalog" ]] && grep -A1 -q "name: ${TENSORFOLD_27B_MODEL_NAME}" "$catalog" \
     && grep -A1 "name: ${TENSORFOLD_27B_MODEL_NAME}" "$catalog" | grep -q "type: local"; then
    echo -e "  ${BOLD}Catalog:${RESET}     ${GREEN}entry in ${catalog}${RESET}"
  else
    echo -e "  ${BOLD}Catalog:${RESET}     ${YELLOW}no ${TENSORFOLD_27B_MODEL_NAME} entry in ${catalog}${RESET}"
  fi
  if [[ -f "${LLAMA_SWAP_DIR}/config/config.yaml" ]] \
     && grep -qE "^[[:space:]]+${TENSORFOLD_27B_MODEL_NAME//./\\.}:" "${LLAMA_SWAP_DIR}/config/config.yaml"; then
    echo -e "  ${BOLD}llama-swap:${RESET}  ${GREEN}entry in config.yaml${RESET}"
  else
    echo -e "  ${BOLD}llama-swap:${RESET}  ${YELLOW}no entry in config.yaml${RESET}"
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$TENSORFOLD_27B_CONTAINER"; then
    local state
    state="$(docker inspect -f '{{.State.Status}}' "$TENSORFOLD_27B_CONTAINER" 2>/dev/null || echo '?')"
    echo -e "  ${BOLD}Container:${RESET}   ${TENSORFOLD_27B_CONTAINER} (${state})"
  else
    echo -e "  ${BOLD}Container:${RESET}   ${YELLOW}not running${RESET} (llama-swap starts it on demand)"
  fi
  if curl -sf --max-time 3 "http://localhost:${LLAMA_SWAP_PORT}/health" &>/dev/null; then
    echo -e "  ${BOLD}Proxy:${RESET}       ${GREEN}llama-swap healthy on port ${LLAMA_SWAP_PORT}${RESET}"
  else
    echo -e "  ${BOLD}Proxy:${RESET}       ${YELLOW}llama-swap not answering on port ${LLAMA_SWAP_PORT}${RESET}"
  fi
  echo ""
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  check_status
  exit 0
fi

# ── Pre-flight: sanity ────────────────────────────────────────────────────────
step "Pre-flight checks"

[[ "$(id -u)" -eq 0 ]] && warn "Running as root – not recommended."

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu. Continuing anyway…"
fi

if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run setup-docker.sh first."
fi
if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi
success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."

if ! command -v envsubst &>/dev/null; then
  error "envsubst is not installed. Install with: sudo apt-get install gettext-base"
fi
if ! command -v python3 &>/dev/null; then
  error "python3 is not installed. Required for the catalog merge and sync-models.py."
fi
if ! python3 -c 'import yaml' &>/dev/null; then
  error "PyYAML is not installed. Install with: sudo apt install python3-yaml"
fi
if ! command -v hf &>/dev/null; then
  error "The 'hf' CLI is not installed. Install with: pip install -U \"huggingface_hub[cli]\""
fi
success "Tooling: envsubst, python3 + PyYAML, hf CLI."

# llama-swap is the runtime owner of the model — hard requirement.
if [[ ! -d "$LLAMA_SWAP_DIR" ]] || ! systemctl cat llama-swap &>/dev/null; then
  error "llama-swap is not installed. Run tasks/setup-llama-swap.sh first."
fi
success "llama-swap installed (${LLAMA_SWAP_DIR})."

# DGX Spark (GB10) detection: compute capability 12.1 (sm_121). nvidia-smi
# reports N/A for memory fields on Spark (UMA) — compute capability is the
# reliable signal. This recipe is Spark-sized (128 GB unified memory), so a
# Spark is hard-required.
is_spark() {
  nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | grep -qi "12\.1"
}
if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null; then
  error "No working NVIDIA GPU (nvidia-smi missing or failing). This recipe requires a DGX Spark (GB10)."
fi
if ! is_spark; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
  error "Not a DGX Spark (found: ${GPU_NAME:-unknown GPU})."
  error "This recipe is sized for one DGX Spark (GB10, 128 GB unified memory): ~97 GiB resident at the full auto KV pool."
fi
success "DGX Spark (GB10, sm_121) detected."

# The container runs with --gpus all (NVIDIA runtime); the toolkit + CDI spec
# are the pre-flight prerequisites (same check as the Flash Next sibling).
if ! command -v nvidia-ctk &>/dev/null; then
  error "nvidia-ctk is not installed. Run setup-nvidia-container.sh first."
fi
if ! nvidia-ctk cdi list 2>/dev/null | grep -q "nvidia.com/gpu=all"; then
  error "No CDI spec for nvidia.com/gpu=all. Run setup-nvidia-container.sh — it generates
  the spec and installs an apt hook that regenerates it after every driver upgrade.
  Manual equivalent: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
fi
success "CDI device nvidia.com/gpu=all is available."

# Disk: only enforced while the checkpoints are missing (prepare.sh re-checks
# precisely on its own). The recipe does not pin revisions — presence of any
# snapshot is the "already downloaded" signal.
MODEL_CACHE_DIR="${HF_CACHE_DIR}/hub/models--Vontra--Qwen3.8-27B-MLX-4bit"
DRAFT_CACHE_DIR="${HF_CACHE_DIR}/hub/models--z-lab--Qwen3.8-27B-DFlash2"
if ! ls -d "${MODEL_CACHE_DIR}"/snapshots/*/ &>/dev/null \
   || ! ls -d "${DRAFT_CACHE_DIR}"/snapshots/*/ &>/dev/null; then
  mkdir -p "$HF_CACHE_DIR"  # fresh machine: df needs the dir to exist
  FREE_GB=$(df -BG --output=avail "$HF_CACHE_DIR" 2>/dev/null | tail -1 | tr -dc '0-9' || true)
  if [[ -z "$FREE_GB" ]]; then
    error "Could not determine free disk space under ${HF_CACHE_DIR} (df failed)."
  fi
  if (( FREE_GB < TENSORFOLD_27B_MIN_FREE_GB )); then
    error "Only ${FREE_GB} GB free under ${HF_CACHE_DIR}; the download needs ~${TENSORFOLD_27B_MIN_FREE_GB} GB (~19 GiB checkpoints + image + margin)."
  fi
  info "Disk: ${FREE_GB} GB free under ${HF_CACHE_DIR} (need ~${TENSORFOLD_27B_MIN_FREE_GB})"
else
  success "Checkpoints already present under ${MODEL_CACHE_DIR} and ${DRAFT_CACHE_DIR}"
fi

# ── --force: stop the running model first ─────────────────────────────────────
if [[ "$FORCE" -eq 1 && -x "${PROJECT_DIR}/stop.sh" ]]; then
  info "--force: stopping the running model (upstream stop.sh)…"
  (cd "$PROJECT_DIR" && bash stop.sh) || true
fi

# ── Clone upstream (pinned) ───────────────────────────────────────────────────
step "Upstream recipe: ${PROJECT_DIR}"

if [[ -d "${PROJECT_DIR}/.git" ]]; then
  info "Converging existing checkout (fetch + checkout ${TENSORFOLD_27B_RECIPE_REF:0:7})…"
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" checkout --quiet "$TENSORFOLD_27B_RECIPE_REF"
else
  if [[ -e "$PROJECT_DIR" ]]; then
    error "${PROJECT_DIR} exists but is not a git checkout — move it aside and re-run."
  fi
  # Create the service dir with user ownership; never chown /srv itself.
  sudo mkdir -p "$(dirname "$PROJECT_DIR")"
  sudo install -d -m 755 -o "$(id -un)" -g "$(id -gn)" "$PROJECT_DIR"
  git clone --quiet "$TENSORFOLD_27B_REPO" "$PROJECT_DIR"
  git -C "$PROJECT_DIR" checkout --quiet "$TENSORFOLD_27B_RECIPE_REF"
fi
success "Recipe at $(git -C "$PROJECT_DIR" rev-parse --short HEAD)"

# ── Write /srv/tensorfold-27b/.env (upstream settings file) ───────────────────
step "Writing ${PROJECT_DIR}/.env"

_SERVE_ENV="$(mktempfile serve.env)"
# shellcheck disable=SC2016  # envsubst expects the literal variable list
(
  export PORT="$TENSORFOLD_27B_PORT"
  envsubst '${PORT}' < "${TEMPLATE_DIR}/serve.env"
) > "$_SERVE_ENV"
install -m 644 -o "$(id -un)" -g "$(id -gn)" "$_SERVE_ENV" "${PROJECT_DIR}/.env"
success ".env written: FOREGROUND=1, PORT=${TENSORFOLD_27B_PORT}"

# ── Prepare: image + checkpoints (idempotent upstream) ────────────────────────
step "Preparing TensorFold (prebuilt image + ~19 GB checkpoints — idempotent, can take a while)"

# KERNEL_CACHE must match the catalog entry (templates/tensorfold-spark-qwen38-27b/models-entry.yml):
# the llama-swap service runs with ProtectHome=read-only, so the lock files and
# the prepared marker live under /srv/tensorfold-27b, not $HOME.
(cd "$PROJECT_DIR" && HF_CACHE="$HF_CACHE_DIR" KERNEL_CACHE="$KERNEL_CACHE_DIR" bash scripts/prepare.sh)
success "Prepare complete."

# ── Merge the catalog entry into models.yml ───────────────────────────────────
step "Merging catalog entry '${TENSORFOLD_27B_MODEL_NAME}' into models.yml"

export TENSORFOLD_27B_PORT LLAMA_SWAP_PORT HF_CACHE_DIR KERNEL_CACHE_DIR TENSORFOLD_27B_HEALTH_TIMEOUT
_ENTRY="$(mktempfile models-entry.yml)"
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${TENSORFOLD_27B_PORT} ${LLAMA_SWAP_PORT} ${HF_CACHE_DIR} ${KERNEL_CACHE_DIR} ${TENSORFOLD_27B_HEALTH_TIMEOUT}' \
  < "${TEMPLATE_DIR}/models-entry.yml" > "$_ENTRY"

MERGE_ARGS=(
  --catalog "${REPO_ROOT}/models.yml"
  --default "${REPO_ROOT}/models.yml.default"
  --entry "$_ENTRY"
  --name "$TENSORFOLD_27B_MODEL_NAME"
  --provider local
)
[[ "$FORCE" -eq 1 ]] && MERGE_ARGS+=(--force)
python3 "${SCRIPT_DIR}/merge-model-entry.py" "${MERGE_ARGS[@]}"
rm -f -- "$_ENTRY"
success "Catalog merged."

# llama-swap's healthCheckTimeout is GLOBAL (top-level config key, default 600) —
# a per-model value is accepted but ignored. Raise it to cover the first load
# (19 GB weights + one-time kernel compile); sync-models.py below restarts
# llama-swap when the file changed.
step "Ensuring llama-swap healthCheckTimeout >= ${TENSORFOLD_27B_HEALTH_TIMEOUT}s"
CONFIG_FILE="${LLAMA_SWAP_DIR}/config/config.yaml"
if [[ -f "$CONFIG_FILE" ]]; then
  python3 - "$CONFIG_FILE" "$TENSORFOLD_27B_HEALTH_TIMEOUT" <<'PYEOF'
import sys, yaml
path, need = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
cur = int(cfg.get("healthCheckTimeout", 600))
if cur < need:
    cfg["healthCheckTimeout"] = need
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f, sort_keys=False, default_flow_style=False)
    print(f"healthCheckTimeout raised {cur} -> {need} (global; comments in config.yaml are not preserved)")
else:
    print(f"healthCheckTimeout already {cur} >= {need}")
PYEOF
fi

# ── Sync llama-swap ───────────────────────────────────────────────────────────
step "Syncing llama-swap (tasks/sync-models.py)"

python3 "${SCRIPT_DIR}/sync-models.py"
success "llama-swap in sync."

# ── Smoke test through llama-swap ─────────────────────────────────────────────
if [[ "$SKIP_SMOKE" -eq 1 ]]; then
  warn "Smoke test skipped (--skip-smoke)."
else
  step "Smoke test through llama-swap (http://localhost:${LLAMA_SWAP_PORT})"
  info "First load pulls ~19 GB of weights into the GPU and compiles CUDA kernels once — up to ${TENSORFOLD_27B_HEALTH_TIMEOUT}s."

# enable_thinking: false (a documented per-request parameter of this engine) —
# with the default thinking mode the think block would eat the small token
# budget and leave message.content empty, failing the check below.
_smoke_body="{\"model\": \"${TENSORFOLD_27B_MODEL_NAME}\", \"max_tokens\": 32, \"temperature\": 0, \"chat_template_kwargs\": {\"enable_thinking\": false}, \"messages\": [{\"role\": \"user\", \"content\": \"Reply with OK.\"}]}"
if _smoke_resp="$(curl -s --max-time $(( TENSORFOLD_27B_HEALTH_TIMEOUT + 60 )) \
     "http://localhost:${LLAMA_SWAP_PORT}/v1/chat/completions" \
     -H 'Content-Type: application/json' -d "${_smoke_body}")" \
   && python3 -c 'import json,sys; r=json.loads(sys.argv[1]); c=r["choices"][0]["message"].get("content") or ""; sys.exit(0 if c.strip() else 1)' "${_smoke_resp}" 2>/dev/null; then
  success "Smoke test passed — the model answers through llama-swap."
else
  error "Smoke test failed — the model is not answering through llama-swap."
  error "Check: curl http://localhost:${LLAMA_SWAP_PORT}/running | jq .  and  docker logs -f ${TENSORFOLD_27B_CONTAINER}"
  error "Retry:   curl -s http://localhost:${LLAMA_SWAP_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"${TENSORFOLD_27B_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK.\"}],\"max_tokens\":32}'"
  error "Re-run $0 (or use --skip-smoke if you will fix this manually)."
fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   tensorfold-27b installation complete!      ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Recipe:${RESET}        ${PROJECT_DIR} ($(git -C "$PROJECT_DIR" rev-parse --short HEAD))"
echo -e "  ${BOLD}HF cache:${RESET}      ${HF_CACHE_DIR}"
echo -e "  ${BOLD}Kernel cache:${RESET}  ${KERNEL_CACHE_DIR}"
echo -e "  ${BOLD}TensorFold port:${RESET} ${TENSORFOLD_27B_PORT} (fixed, host network — via /srv/tensorfold-27b/.env)"
echo -e "  ${BOLD}Model:${RESET}         ${TENSORFOLD_27B_MODEL_NAME} (aliases: Qwen3.8-27B, qwen3.8-27)"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Status:       $0 --check"
echo -e "  Load model:   curl -s -X POST http://localhost:${LLAMA_SWAP_PORT}/v1/models/${TENSORFOLD_27B_MODEL_NAME}/load"
echo -e "  Unload model: curl -s -X POST http://localhost:${LLAMA_SWAP_PORT}/v1/models/${TENSORFOLD_27B_MODEL_NAME}/unload"
echo -e "  Logs:         docker logs -f ${TENSORFOLD_27B_CONTAINER}"
echo -e "  llama-swap:   journalctl -u llama-swap -f"
echo ""
echo -e "  ${BOLD}API (through llama-swap):${RESET} http://localhost:${LLAMA_SWAP_PORT}/v1  (model: ${TENSORFOLD_27B_MODEL_NAME})"
echo ""
echo -e "  ${BOLD}Note:${RESET} the model loads on demand and is never auto-unloaded (ttl: 0)."
echo -e "  If llama-swap restarts while the container is running, the next load"
echo -e "  fails until the stale container is removed: docker rm -f ${TENSORFOLD_27B_CONTAINER}"
echo ""
echo -e "  ${BOLD}Coexistence:${RESET} this model does NOT fit alongside Flash Next at"
echo -e "  defaults — use llama-swap's one-model-at-a-time swap. Co-loading needs"
echo -e "  reduced settings on at least one side AND TENSORFOLD_MEMORY_RESERVE_GIB=4"
echo -e "  in both recipes' .env files."
echo ""
