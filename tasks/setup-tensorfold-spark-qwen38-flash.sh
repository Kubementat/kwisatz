#!/usr/bin/env bash
# shellcheck disable=SC1091
# =============================================================================
# setup-tensorfold-spark-qwen38-flash.sh
# Installs Qwen3.8 Flash Next on one NVIDIA DGX Spark (GB10, 128 GB unified
# memory) via TensorFold's Zig engine (tensorfold-native), managed by
# llama-swap. There is no standalone stack: llama-swap owns the container
# lifecycle (serve.cmd runs the upstream start.sh, cmdStop stops it) and
# proxies the OpenAI API from port 9292 to TensorFold on TENSORFOLD_PORT
# (default 8888).
#
# Upstream recipe (pinned):
#   https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
#   recipe commit ${TENSORFOLD_RECIPE_REF} (commit date 2026-10-12); the TensorFold
#   engine itself is pinned inside the recipe (TF_REF db281878, image
#   tensorfold-qwen38:zig-db28187) and applied by scripts/prepare.sh.
#
# Workflow (all steps idempotent, converge on re-run):
#   1. pre-flight: docker, CDI GPU spec, DGX Spark, hf CLI, llama-swap; then
#      *what still needs downloading* — checkpoint present? engine image
#      present? — and only if something is missing, the free-disk check. A
#      re-run with both already on disk converges on a full disk.
#   2. clone the recipe into /srv/tensorfold (re-run: fetch + checkout pin)
#   3. run upstream scripts/prepare.sh (image + ~122 GB checkpoint)
#   4. merge the qwen3.8-flash-next entry into models.yml (additive; the
#      entry is replaced if the rendered template changed)
#   5. run tasks/sync-models.py (merge into llama-swap config.yaml, restart
#      only on change, poll /health)
#   6. smoke test through llama-swap (first load is a ~122 GB weight load)
#
# Usage:
#   ./setup-tensorfold-spark-qwen38-flash.sh            # install / converge
#   ./setup-tensorfold-spark-qwen38-flash.sh --check    # show status and exit
#   ./setup-tensorfold-spark-qwen38-flash.sh --force    # stop the running model, force re-merge
#   ./setup-tensorfold-spark-qwen38-flash.sh --help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/tensorfold-spark-qwen38-flash"
REPO_ROOT="${SCRIPT_DIR}/.."

# shellcheck source=../lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"
# shellcheck source=../lib/tensorfold-helper.sh
source "${SCRIPT_DIR}/../lib/tensorfold-helper.sh"

# ── Pinned upstream recipe ────────────────────────────────────────────────────
TENSORFOLD_REPO="https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold"
# Recipe repo commit (commit date 2026-10-12). Note: the often-quoted pin
# db281878ddb836fd0df510d8771ecb7e0fe47d26 is the TensorFold ENGINE commit
# (TF_REF in the recipe's scripts/config.sh), not a recipe-repo commit.
TENSORFOLD_RECIPE_REF="4e1239ddb9d9a4cc3c748e771ae4725335c46a95"
# Free disk, per piece that still has to be downloaded — the pre-flight demands
# only what is actually missing (upstream: MIN_FREE_GB=140 + IMAGE_FREE_GB=40,
# checked again, precisely, inside scripts/prepare.sh):
#   TENSORFOLD_MODEL_GB    ~122 GiB checkpoint + margin
#   TENSORFOLD_IMAGE_GB    the engine image
#   TENSORFOLD_MIN_FREE_GB the total for a cold install (nothing downloaded yet)
TENSORFOLD_MIN_FREE_GB="${TENSORFOLD_MIN_FREE_GB:-160}"
TENSORFOLD_IMAGE_GB="${TENSORFOLD_IMAGE_GB:-40}"
TENSORFOLD_MODEL_GB=$(( TENSORFOLD_MIN_FREE_GB - TENSORFOLD_IMAGE_GB ))
# The engine image scripts/prepare.sh leaves behind (its scripts/config.sh:
# IMAGE=tensorfold-qwen38:zig-<TF_REF:0:7>; a pulled ghcr.io/miaai-lab/… image
# is tagged with it). Keep in step with the TensorFold pin inside the recipe.
TENSORFOLD_IMAGE="tensorfold-qwen38:zig-db28187"

TENSORFOLD_MODEL_NAME="qwen3.8-flash-next"
TENSORFOLD_CONTAINER="qwen38-flash-next-tf"

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_DIR="${PROJECT_DIR:-/srv/tensorfold}"
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"
KERNEL_CACHE_DIR="${KERNEL_CACHE_DIR:-${HOME}/.cache/tensorfold-qwen38}"
TENSORFOLD_PORT="${TENSORFOLD_PORT:-8888}"
LLAMA_SWAP_PORT="${LLAMA_SWAP_PORT:-9292}"
LLAMA_SWAP_DIR="${LLAMA_SWAP_DIR:-/srv/llama-swap}"
# Writable by the llama-swap service (ProtectHome=read-only): start.sh flocks
# $STATE_DIR/start.lock and writes $LOG_DIR there at load time, so both must
# live outside $HOME. /srv is not protected by ProtectSystem=full.
TENSORFOLD_STATE_DIR="${TENSORFOLD_STATE_DIR:-${PROJECT_DIR}/.state}"
SKIP_SMOKE=0
# Seconds for llama-swap to wait for a first load (122 GiB weight load).
TENSORFOLD_HEALTH_TIMEOUT="${TENSORFOLD_HEALTH_TIMEOUT:-900}"

FORCE=0
CHECK_ONLY=0

# ── Input validation ──────────────────────────────────────────────────────────

validate_port() {
  local name="$1" port="$2"
  if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
    error "${name} must be a number between 1 and 65535 (got: ${port})."
  fi
}

validate_port TENSORFOLD_PORT "$TENSORFOLD_PORT"
validate_port LLAMA_SWAP_PORT "$LLAMA_SWAP_PORT"
if [[ ! "$TENSORFOLD_HEALTH_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  error "TENSORFOLD_HEALTH_TIMEOUT must be a positive integer (seconds)."
fi

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
  echo -e "${BOLD}Usage:${RESET} $0 [OPTIONS]"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo "  --port <n>               TensorFold API port the container binds on the"
  echo "                           host network; llama-swap proxies to it (default: 8888)"
  echo "  --health-timeout <s>     Seconds a first model load may take (122 GiB"
  echo "                           weight load; default: 900). Raises llama-swap's"
  echo "                           global healthCheckTimeout to at least this value"
  echo "                           (the field is global in llama-swap, not per-model)"
  echo "                           and bounds the smoke-test wait."
  echo "  --dir <path>             Recipe checkout + service dir (default: /srv/tensorfold)"
  echo "  --hf-cache <path>        Host HuggingFace cache dir (default: ~/.cache/huggingface)"
  echo "  --force                  Stop the running model first (upstream stop.sh) and"
  echo "                           force the catalog re-merge even if unchanged"
  echo "  --skip-smoke             Skip the post-install smoke test through llama-swap"
  echo "  --check                  Show installation status and exit"
  echo "  --help                   Show this help"
  echo ""
  echo -e "${BOLD}Environment variables${RESET} (all flags above have env-var equivalents):"
  echo "  TENSORFOLD_PORT, TENSORFOLD_HEALTH_TIMEOUT, PROJECT_DIR, HF_CACHE_DIR,"
  echo "  KERNEL_CACHE_DIR, TENSORFOLD_STATE_DIR, LLAMA_SWAP_PORT, LLAMA_SWAP_DIR,"
  echo "  TENSORFOLD_MIN_FREE_GB, TENSORFOLD_IMAGE_GB"
  echo ""
  echo -e "${BOLD}Requirements:${RESET}"
  echo "  One DGX Spark (GB10, 128 GB unified memory) with nothing else large on"
  echo "  the GPU (~103 GiB at startup with the recipe defaults), Docker with the"
  echo "  NVIDIA container toolkit (setup-nvidia-container.sh first), llama-swap"
  echo "  (setup-llama-swap.sh first), ~160 GB free disk for a cold install, 'hf' CLI"
  echo "  (pip install -U \"huggingface_hub[cli]\")."
  echo ""
  echo -e "${BOLD}Free disk:${RESET}"
  echo "  A cold install needs ~${TENSORFOLD_MIN_FREE_GB} GB free under HF_CACHE_DIR (~122 GiB"
  echo "  checkpoint + the engine image). That check runs only while the checkpoint"
  echo "  or the engine image is still missing — a re-run with both present needs no"
  echo "  free space at all and converges (scripts/prepare.sh re-checks the exact"
  echo "  download itself). Tune with TENSORFOLD_MIN_FREE_GB / TENSORFOLD_IMAGE_GB."
  echo ""
  echo -e "${BOLD}Runtime model:${RESET}"
  echo "  The model is NOT a standalone stack. llama-swap starts the container"
  echo "  on demand (serve.cmd = upstream start.sh, blocking) and stops it via"
  echo "  cmdStop; the OpenAI API is consumed through llama-swap:"
  echo "    http://localhost:${LLAMA_SWAP_PORT}/v1  (model: ${TENSORFOLD_MODEL_NAME})"
  echo "  Serve levers (context, parallel, KV dtype, vision, ...) are upstream"
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
    --port)             shift; TENSORFOLD_PORT="$1" ;;
    --health-timeout)   shift; TENSORFOLD_HEALTH_TIMEOUT="$1" ;;
    --dir)              shift; PROJECT_DIR="$1" ;;
    --hf-cache)         shift; HF_CACHE_DIR="$1" ;;
    --force)            FORCE=1 ;;
    --skip-smoke)       SKIP_SMOKE=1 ;;
    --check)            CHECK_ONLY=1 ;;
    --help|-h)          usage ;;
    *) error "Unknown option: $1  (use --help for usage)" ;;
  esac
  shift
done

# HF cache layout of the pinned checkpoint (…/hub/models--<org>--<repo>),
# resolved after argument parsing so --check and the pre-flight probe the same
# path. The revision is NOT part of the probe (see path_has_hf_snapshot).
MODEL_CACHE_DIR="${HF_CACHE_DIR}/hub/models--azampatti--Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound"

# ── --check ───────────────────────────────────────────────────────────────────

check_status() {
  echo ""
  echo -e "${BOLD}tensorfold status${RESET}"
  echo ""
  if [[ -d "${PROJECT_DIR}/.git" ]]; then
    local head
    head="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
    if [[ "$head" == "${TENSORFOLD_RECIPE_REF:0:7}" ]]; then
      echo -e "  ${BOLD}Recipe:${RESET}      ${GREEN}pinned${RESET} (${head})"
    else
      echo -e "  ${BOLD}Recipe:${RESET}      ${YELLOW}${head}${RESET} (expected ${TENSORFOLD_RECIPE_REF:0:7} — re-run without --check to converge)"
    fi
  else
    echo -e "  ${BOLD}Recipe:${RESET}      ${YELLOW}not installed${RESET} (${PROJECT_DIR})"
  fi
  if [[ -f "${TENSORFOLD_STATE_DIR}/prepared" ]]; then
    echo -e "  ${BOLD}Prepared:${RESET}    ${GREEN}image + checkpoint ready${RESET}"
  else
    echo -e "  ${BOLD}Prepared:${RESET}    ${YELLOW}no — prepare.sh has not completed${RESET}"
  fi
  # Same signals as the pre-flight: presence of checkpoint and image first,
  # then free disk — and what a re-run would still have to download.
  local pending="" need=0 free
  if path_has_hf_snapshot "$MODEL_CACHE_DIR"; then
    echo -e "  ${BOLD}Checkpoint:${RESET}   ${GREEN}present${RESET} (${MODEL_CACHE_DIR})"
  else
    echo -e "  ${BOLD}Checkpoint:${RESET}   ${YELLOW}not cached${RESET} (${MODEL_CACHE_DIR})"
    pending="checkpoint ~${TENSORFOLD_MODEL_GB} GB"
    need=$(( need + TENSORFOLD_MODEL_GB ))
  fi
  if docker image inspect "$TENSORFOLD_IMAGE" &>/dev/null; then
    echo -e "  ${BOLD}Image:${RESET}        ${GREEN}${TENSORFOLD_IMAGE}${RESET}"
  else
    echo -e "  ${BOLD}Image:${RESET}        ${YELLOW}missing${RESET} (${TENSORFOLD_IMAGE})"
    [[ -n "$pending" ]] && pending="$pending and "
    pending="${pending}image ~${TENSORFOLD_IMAGE_GB} GB"
    need=$(( need + TENSORFOLD_IMAGE_GB ))
  fi
  free="$(df -BG --output=avail "$HF_CACHE_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')"
  echo -e "  ${BOLD}Disk:${RESET}        ${free:-?} GB free under ${HF_CACHE_DIR} (still to download: ${pending:-nothing})"
  if (( need > 0 )) && [[ -n "$free" ]] && (( free < need )); then
    echo -e "                 ${YELLOW}below the ~${need} GB that download would need${RESET}"
  fi
  local catalog="${REPO_ROOT}/models.yml"
  # -A1: require 'type: local' right after — a same-named remote entry must not
  # count as the local tensorfold entry.
  if [[ -f "$catalog" ]] && grep -A1 -q "name: ${TENSORFOLD_MODEL_NAME}" "$catalog" \
     && grep -A1 "name: ${TENSORFOLD_MODEL_NAME}" "$catalog" | grep -q "type: local"; then
    echo -e "  ${BOLD}Catalog:${RESET}     ${GREEN}entry in ${catalog}${RESET}"
  else
    echo -e "  ${BOLD}Catalog:${RESET}     ${YELLOW}no ${TENSORFOLD_MODEL_NAME} entry in ${catalog}${RESET}"
  fi
  if [[ -f "${LLAMA_SWAP_DIR}/config/config.yaml" ]] \
     && grep -qE "^[[:space:]]+${TENSORFOLD_MODEL_NAME//./\\.}:" "${LLAMA_SWAP_DIR}/config/config.yaml"; then
    echo -e "  ${BOLD}llama-swap:${RESET}  ${GREEN}entry in config.yaml${RESET}"
  else
    echo -e "  ${BOLD}llama-swap:${RESET}  ${YELLOW}no entry in config.yaml${RESET}"
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$TENSORFOLD_CONTAINER"; then
    local state
    state="$(docker inspect -f '{{.State.Status}}' "$TENSORFOLD_CONTAINER" 2>/dev/null || echo '?')"
    echo -e "  ${BOLD}Container:${RESET}   ${TENSORFOLD_CONTAINER} (${state})"
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
  error "This recipe is sized for one DGX Spark (GB10, 128 GB unified memory): ~103 GiB at startup with the defaults."
fi
success "DGX Spark (GB10, sm_121) detected."

# The container requests the GPU via the CDI device nvidia.com/gpu=all.
if ! command -v nvidia-ctk &>/dev/null; then
  error "nvidia-ctk is not installed. Run setup-nvidia-container.sh first."
fi
if ! nvidia-ctk cdi list 2>/dev/null | grep -q "nvidia.com/gpu=all"; then
  error "No CDI spec for nvidia.com/gpu=all. Run setup-nvidia-container.sh — it generates
  the spec and installs an apt hook that regenerates it after every driver upgrade.
  Manual equivalent: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
fi
success "CDI device nvidia.com/gpu=all is available."

# ── Pre-flight: what still needs to be downloaded? ────────────────────────────
# Presence first, disk second, and disk only for what is missing — a re-run on a
# nearly full machine where the checkpoint and the engine image are already on
# disk must converge and download nothing (conventions.md → Re-run policy:
# converge by default). A cold install still pays the full TENSORFOLD_MIN_FREE_GB
# requirement, and prepare.sh re-checks it precisely on its own.

# (a) Checkpoint — any usable cached snapshot counts, not one pinned revision.
NEEDS_MODEL=1
if path_has_hf_snapshot "$MODEL_CACHE_DIR"; then
  NEEDS_MODEL=0
  success "Checkpoint already present under ${MODEL_CACHE_DIR}"
fi

# (b) Engine image — prepared by the recipe, tagged locally.
NEEDS_IMAGE=1
if docker image inspect "$TENSORFOLD_IMAGE" &>/dev/null; then
  NEEDS_IMAGE=0
  success "Engine image already present (${TENSORFOLD_IMAGE})"
fi

# (c) Free disk, only for the pieces that are still missing.
if [[ "$NEEDS_MODEL" -eq 1 || "$NEEDS_IMAGE" -eq 1 ]]; then
  NEEDED_GB=0
  MISSING=""
  if [[ "$NEEDS_MODEL" -eq 1 ]]; then
    NEEDED_GB=$(( NEEDED_GB + TENSORFOLD_MODEL_GB ))
    MISSING="the ~${TENSORFOLD_MODEL_GB} GB checkpoint"
  fi
  if [[ "$NEEDS_IMAGE" -eq 1 ]]; then
    NEEDED_GB=$(( NEEDED_GB + TENSORFOLD_IMAGE_GB ))
    [[ -n "$MISSING" ]] && MISSING="$MISSING and "
    MISSING="${MISSING}the ~${TENSORFOLD_IMAGE_GB} GB engine image"
  fi
  require_free_space "$NEEDED_GB" "$HF_CACHE_DIR" "$MISSING"
else
  info "Checkpoint and engine image already on disk — nothing to download, free-disk check skipped."
fi

# ── --force: stop the running model first ─────────────────────────────────────
if [[ "$FORCE" -eq 1 && -x "${PROJECT_DIR}/stop.sh" ]]; then
  info "--force: stopping the running model (upstream stop.sh)…"
  (cd "$PROJECT_DIR" && bash stop.sh) || true
fi

# ── Clone upstream (pinned) ───────────────────────────────────────────────────
step "Upstream recipe: ${PROJECT_DIR}"

if [[ -d "${PROJECT_DIR}/.git" ]]; then
  info "Converging existing checkout (fetch + checkout ${TENSORFOLD_RECIPE_REF:0:7})…"
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" checkout --quiet "$TENSORFOLD_RECIPE_REF"
else
  if [[ -e "$PROJECT_DIR" ]]; then
    error "${PROJECT_DIR} exists but is not a git checkout — move it aside and re-run."
  fi
  # Create the service dir with user ownership; never chown /srv itself.
  sudo mkdir -p "$(dirname "$PROJECT_DIR")"
  sudo install -d -m 755 -o "$(id -un)" -g "$(id -gn)" "$PROJECT_DIR"
  git clone --quiet "$TENSORFOLD_REPO" "$PROJECT_DIR"
  git -C "$PROJECT_DIR" checkout --quiet "$TENSORFOLD_RECIPE_REF"
fi
success "Recipe at $(git -C "$PROJECT_DIR" rev-parse --short HEAD)"

# ── Write /srv/tensorfold/.env (upstream settings file) ───────────────────────
step "Writing ${PROJECT_DIR}/.env"

_SERVE_ENV="$(mktempfile serve.env)"
# shellcheck disable=SC2016  # envsubst expects the literal variable list
(
  export PORT="$TENSORFOLD_PORT"
  envsubst '${PORT}' < "${TEMPLATE_DIR}/serve.env"
) > "$_SERVE_ENV"
install -m 644 -o "$(id -un)" -g "$(id -gn)" "$_SERVE_ENV" "${PROJECT_DIR}/.env"
success ".env written: FOREGROUND=1, PORT=${TENSORFOLD_PORT}"

# ── Prepare: image + checkpoint (idempotent upstream) ─────────────────────────
step "Preparing TensorFold (image + ~122 GB checkpoint — idempotent, can take a while)"

# STATE_DIR/LOG_DIR must match the catalog entry (templates/tensorfold-spark-qwen38-flash/models-entry.yml):
# the llama-swap service runs with ProtectHome=read-only, so the prepared marker
# and the runtime lock/log files live under /srv/tensorfold, not $HOME.
(cd "$PROJECT_DIR" && HF_CACHE="$HF_CACHE_DIR" KERNEL_CACHE="$KERNEL_CACHE_DIR" \
  STATE_DIR="$TENSORFOLD_STATE_DIR" LOG_DIR="${TENSORFOLD_STATE_DIR}/logs" bash scripts/prepare.sh)
success "Prepare complete."

# ── Merge the catalog entry into models.yml ───────────────────────────────────
step "Merging catalog entry '${TENSORFOLD_MODEL_NAME}' into models.yml"

export TENSORFOLD_PORT LLAMA_SWAP_PORT HF_CACHE_DIR KERNEL_CACHE_DIR TENSORFOLD_HEALTH_TIMEOUT TENSORFOLD_STATE_DIR
_ENTRY="$(mktempfile models-entry.yml)"
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${TENSORFOLD_PORT} ${LLAMA_SWAP_PORT} ${HF_CACHE_DIR} ${KERNEL_CACHE_DIR} ${TENSORFOLD_HEALTH_TIMEOUT} ${TENSORFOLD_STATE_DIR}' \
  < "${TEMPLATE_DIR}/models-entry.yml" > "$_ENTRY"

MERGE_ARGS=(
  --catalog "${REPO_ROOT}/models.yml"
  --default "${REPO_ROOT}/models.yml.default"
  --entry "$_ENTRY"
  --name "$TENSORFOLD_MODEL_NAME"
  --provider local
)
[[ "$FORCE" -eq 1 ]] && MERGE_ARGS+=(--force)
python3 "${SCRIPT_DIR}/merge-model-entry.py" "${MERGE_ARGS[@]}"
rm -f -- "$_ENTRY"
success "Catalog merged."

# llama-swap's healthCheckTimeout is GLOBAL (top-level config key, default 600) —
# a per-model value is accepted but ignored. Raise it to cover the 122 GiB
# first load; sync-models.py below restarts llama-swap when the file changed.
step "Ensuring llama-swap healthCheckTimeout >= ${TENSORFOLD_HEALTH_TIMEOUT}s"
CONFIG_FILE="${LLAMA_SWAP_DIR}/config/config.yaml"
if [[ -f "$CONFIG_FILE" ]]; then
  python3 - "$CONFIG_FILE" "$TENSORFOLD_HEALTH_TIMEOUT" <<'PYEOF'
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
  info "First load pulls ~66 GiB of weights into the GPU — up to ${TENSORFOLD_HEALTH_TIMEOUT}s."

_smoke_body="{\"model\": \"${TENSORFOLD_MODEL_NAME}\", \"max_tokens\": 32, \"temperature\": 0, \"chat_template_kwargs\": {\"enable_thinking\": false}, \"messages\": [{\"role\": \"user\", \"content\": \"Reply with OK.\"}]}"
if _smoke_resp="$(curl -s --max-time $(( TENSORFOLD_HEALTH_TIMEOUT + 60 )) \
     "http://localhost:${LLAMA_SWAP_PORT}/v1/chat/completions" \
     -H 'Content-Type: application/json' -d "${_smoke_body}")" \
   && python3 -c 'import json,sys; r=json.loads(sys.argv[1]); c=r["choices"][0]["message"].get("content") or ""; sys.exit(0 if c.strip() else 1)' "${_smoke_resp}" 2>/dev/null; then
  success "Smoke test passed — the model answers through llama-swap."
else
  error "Smoke test failed — the model is not answering through llama-swap."
  error "Check: curl http://localhost:${LLAMA_SWAP_PORT}/running | jq .  and  docker logs -f ${TENSORFOLD_CONTAINER}"
  error "Retry:   curl -s http://localhost:${LLAMA_SWAP_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"${TENSORFOLD_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK.\"}],\"max_tokens\":32}'"
  error "Re-run $0 (or use --skip-smoke if you will fix this manually)."
fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║     tensorfold installation complete!        ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Recipe:${RESET}        ${PROJECT_DIR} ($(git -C "$PROJECT_DIR" rev-parse --short HEAD))"
echo -e "  ${BOLD}HF cache:${RESET}      ${HF_CACHE_DIR}"
echo -e "  ${BOLD}TensorFold port:${RESET} ${TENSORFOLD_PORT} (fixed, host network — via /srv/tensorfold/.env)"
echo -e "  ${BOLD}Model:${RESET}         ${TENSORFOLD_MODEL_NAME} (aliases: Qwen3.8-Flash-Next, qwen3.8-flash, qwen3.8)"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Status:       $0 --check"
echo -e "  Load model:   curl -s -X POST http://localhost:${LLAMA_SWAP_PORT}/v1/models/${TENSORFOLD_MODEL_NAME}/load"
echo -e "  Unload model: curl -s -X POST http://localhost:${LLAMA_SWAP_PORT}/v1/models/${TENSORFOLD_MODEL_NAME}/unload"
echo -e "  Logs:         docker logs -f ${TENSORFOLD_CONTAINER}"
echo -e "  llama-swap:   journalctl -u llama-swap -f"
echo ""
echo -e "  ${BOLD}API (through llama-swap):${RESET} http://localhost:${LLAMA_SWAP_PORT}/v1  (model: ${TENSORFOLD_MODEL_NAME})"
echo ""
echo -e "  ${BOLD}Note:${RESET} the model loads on demand and is never auto-unloaded (ttl: 0)."
echo -e "  If llama-swap restarts while the container is running, the next load"
echo -e "  fails until the stale container is removed: docker rm -f ${TENSORFOLD_CONTAINER}"
echo ""
