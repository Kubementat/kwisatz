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
#   1. pre-flight: docker, CDI GPU spec, DGX Spark, hf CLI, llama-swap; then
#      *what still needs downloading* — checkpoints present? engine image
#      present? — and only if something is missing, the free-disk check. A
#      re-run with all of it already on disk converges on a full disk.
#   2. clone the recipe into /srv/tensorfold-27b (re-run: fetch + checkout pin)
#   3. run upstream scripts/prepare.sh (prebuilt image + ~19 GB checkpoints)
#   4. merge the qwen3.8-27b-tf entry into models.yml (additive; the entry is
#      replaced if the rendered template changed)
#   5. run tasks/sync-models.py (merge into llama-swap config.yaml, restart
#      only on change, poll /health)
#   6. smoke test through llama-swap (first load: 19 GB weights + one-time
#      CUDA kernel compile)
#
# The steps that are shared with the Flash Next sibling (pre-flight, the
# what-needs-downloading gate, pinned checkout, .env render, catalog merge,
# llama-swap sync/health-timeout/smoke test, --check signals) live in
# lib/tensorfold-helper.sh; this script keeps the recipe-specific constants and
# passes them in.
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
# shellcheck source=../lib/tensorfold-helper.sh
source "${SCRIPT_DIR}/../lib/tensorfold-helper.sh"

# ── Pinned upstream recipe ────────────────────────────────────────────────────
TENSORFOLD_27B_REPO="https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-TensorFold"
TENSORFOLD_27B_RECIPE_REF="c11ff138871cf43d12898d79dbfa4dc952d17ca4"
# Free disk, per piece that still has to be downloaded — the pre-flight demands
# only what is actually missing (upstream: MIN_FREE_GB=25 for the ~19 GiB
# checkpoints + IMAGE_FREE_GB=35 for the image, checked again inside
# scripts/prepare.sh):
#   TENSORFOLD_27B_MODEL_GB   both checkpoints + margin
#   TENSORFOLD_27B_IMAGE_GB   the engine image
#   TENSORFOLD_27B_MIN_FREE_GB the total for a cold install (nothing downloaded)
TENSORFOLD_27B_MIN_FREE_GB="${TENSORFOLD_27B_MIN_FREE_GB:-60}"
TENSORFOLD_27B_IMAGE_GB="${TENSORFOLD_27B_IMAGE_GB:-35}"
TENSORFOLD_27B_MODEL_GB=$(( TENSORFOLD_27B_MIN_FREE_GB - TENSORFOLD_27B_IMAGE_GB ))
# Engine images prepare.sh leaves behind (its scripts/config.sh): the tagged
# local build tensorfold-qwen38-27b:<TF_VERSION>, and — when the pull worked —
# the prebuilt ghcr.io/miaai-lab/qwen3.8-27b-dgx-spark-tensorfold reference it
# tags as the local one. Either counts as "no image download needed".
TENSORFOLD_27B_IMAGE="tensorfold-qwen38-27b:v0.6.0"
TENSORFOLD_27B_IMAGE_PREBUILT="ghcr.io/miaai-lab/qwen3.8-27b-dgx-spark-tensorfold:v0.6.0-fb91a0019fdc"

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
  echo "  TENSORFOLD_27B_MIN_FREE_GB, TENSORFOLD_27B_IMAGE_GB"
  echo ""
  echo -e "${BOLD}Requirements:${RESET}"
  echo "  One DGX Spark (GB10, 128 GB unified memory) with nothing else large on"
  echo "  the GPU (~97 GiB resident at the full auto KV pool), Docker with the"
  echo "  NVIDIA container toolkit (setup-nvidia-container.sh first), llama-swap"
  echo "  (setup-llama-swap.sh first), ~60 GB free disk for a cold install, 'hf' CLI"
  echo "  (pip install -U \"huggingface_hub[cli]\"). Does NOT coexist with"
  echo "  Flash Next (setup-tensorfold-spark-qwen38-flash.sh) at defaults — use llama-swap's"
  echo "  one-model-at-a-time swap."
  echo ""
  echo -e "${BOLD}Free disk:${RESET}"
  echo "  A cold install needs ~${TENSORFOLD_27B_MIN_FREE_GB} GB free under HF_CACHE_DIR (~19 GiB of both"
  echo "  checkpoints + the engine image). That check runs only while a checkpoint"
  echo "  or the engine image is still missing — a re-run with all of it present needs"
  echo "  no free space at all and converges (scripts/prepare.sh re-checks the exact"
  echo "  download itself). Tune with TENSORFOLD_27B_MIN_FREE_GB / TENSORFOLD_27B_IMAGE_GB."
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

# HF cache layout of the two checkpoints (…/hub/models--<org>--<repo>), resolved
# after argument parsing so --check and the pre-flight probe the same paths. The
# recipe pins no revision, so the probe accepts any cached snapshot.
MODEL_CACHE_DIR="${HF_CACHE_DIR}/hub/models--Vontra--Qwen3.8-27B-MLX-4bit"
DRAFT_CACHE_DIR="${HF_CACHE_DIR}/hub/models--z-lab--Qwen3.8-27B-DFlash2"

# ── --check ───────────────────────────────────────────────────────────────────

check_status() {
  echo ""
  echo -e "${BOLD}tensorfold-27b status${RESET}"
  echo ""
  tensorfold_status_recipe "$PROJECT_DIR" "$TENSORFOLD_27B_RECIPE_REF"
  tensorfold_status_prepared "${KERNEL_CACHE_DIR}/.prepared" "image + checkpoints ready"
  # Same signals as the pre-flight: presence of checkpoints and image first,
  # then free disk — and what a re-run would still have to download.
  tensorfold_resolve_pending_downloads --quiet \
    --model-label "Checkpoints" \
    --model-gb "$TENSORFOLD_27B_MODEL_GB" \
    --image-gb "$TENSORFOLD_27B_IMAGE_GB" \
    --cache-dir "$MODEL_CACHE_DIR" \
    --cache-dir "$DRAFT_CACHE_DIR" \
    --image "$TENSORFOLD_27B_IMAGE" \
    --image "$TENSORFOLD_27B_IMAGE_PREBUILT" \
    --hf-cache "$HF_CACHE_DIR"
  if [[ "$TENSORFOLD_NEEDS_MODEL" -eq 0 ]]; then
    echo -e "  ${BOLD}Checkpoints:${RESET}  ${GREEN}present${RESET} (${MODEL_CACHE_DIR}, ${DRAFT_CACHE_DIR})"
  else
    echo -e "  ${BOLD}Checkpoints:${RESET}  ${YELLOW}not cached${RESET} (${MODEL_CACHE_DIR}, ${DRAFT_CACHE_DIR})"
  fi
  tensorfold_status_image "$TENSORFOLD_27B_IMAGE" "$TENSORFOLD_27B_IMAGE_PREBUILT"
  tensorfold_status_disk "$HF_CACHE_DIR"
  tensorfold_status_catalog "${REPO_ROOT}/models.yml" "$TENSORFOLD_27B_MODEL_NAME"
  tensorfold_status_llama_swap_entry "${LLAMA_SWAP_DIR}/config/config.yaml" "$TENSORFOLD_27B_MODEL_NAME"
  tensorfold_status_container "$TENSORFOLD_27B_CONTAINER"
  tensorfold_status_proxy "$LLAMA_SWAP_PORT"
  echo ""
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  check_status
  exit 0
fi

# ── Pre-flight: sanity ────────────────────────────────────────────────────────
# docker daemon, envsubst/python3+PyYAML/hf, llama-swap, DGX Spark (GB10,
# sm_121) and the CDI device nvidia.com/gpu=all — all shared with the Flash Next
# sibling, so the checks live in lib/tensorfold-helper.sh. Last argument is the
# sizing sentence printed when the GPU is not a Spark.
step "Pre-flight checks"
tensorfold_preflight_sanity "$LLAMA_SWAP_DIR" \
  "This recipe is sized for one DGX Spark (GB10, 128 GB unified memory): ~97 GiB resident at the full auto KV pool."

# ── Pre-flight: what still needs to be downloaded? ────────────────────────────
# Presence first, disk second, and disk only for what is missing — a re-run on a
# nearly full machine where the checkpoints and the engine image are already on
# disk must converge and download nothing (conventions.md → Re-run policy:
# converge by default). A cold install still pays the full
# TENSORFOLD_27B_MIN_FREE_GB requirement, and prepare.sh re-checks it on its own.
# The recipe pins no revision, so any usable cached snapshot is a finished
# download (upstream's own probe is scripts/config.sh: have_model) — see
# lib/tensorfold-helper.sh → tensorfold_resolve_pending_downloads.
tensorfold_resolve_pending_downloads \
  --model-label "Checkpoints" \
  --model-gb "$TENSORFOLD_27B_MODEL_GB" \
  --image-gb "$TENSORFOLD_27B_IMAGE_GB" \
  --cache-dir "$MODEL_CACHE_DIR" \
  --cache-dir "$DRAFT_CACHE_DIR" \
  --image "$TENSORFOLD_27B_IMAGE" \
  --image "$TENSORFOLD_27B_IMAGE_PREBUILT" \
  --hf-cache "$HF_CACHE_DIR"

# ── --force: stop the running model first ─────────────────────────────────────
tensorfold_stop_running_model "$PROJECT_DIR" "$FORCE"

# ── Clone upstream (pinned) ───────────────────────────────────────────────────
tensorfold_checkout_pinned_recipe "$PROJECT_DIR" "$TENSORFOLD_27B_REPO" "$TENSORFOLD_27B_RECIPE_REF"

# ── Write /srv/tensorfold-27b/.env (upstream settings file) ───────────────────
tensorfold_render_serve_env "${TEMPLATE_DIR}/serve.env" "${PROJECT_DIR}/.env" "$TENSORFOLD_27B_PORT"

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
# Render + additive merge (merge-model-entry.py): the entry is replaced only if
# the rendered template changed, --force re-writes it.
# shellcheck disable=SC2016  # the last argument is envsubst's literal variable list
tensorfold_merge_model_entry \
  "${TEMPLATE_DIR}/models-entry.yml" \
  "${REPO_ROOT}/models.yml" \
  "${REPO_ROOT}/models.yml.default" \
  "$TENSORFOLD_27B_MODEL_NAME" \
  "$FORCE" \
  '${TENSORFOLD_27B_PORT} ${LLAMA_SWAP_PORT} ${HF_CACHE_DIR} ${KERNEL_CACHE_DIR} ${TENSORFOLD_27B_HEALTH_TIMEOUT}'

# llama-swap's healthCheckTimeout is GLOBAL (top-level config key, default 600) —
# a per-model value is accepted but ignored. Raise it to cover the first load
# (19 GB weights + one-time kernel compile); sync-models.py below restarts
# llama-swap when the file changed.
tensorfold_llama_swap_raise_health_timeout "${LLAMA_SWAP_DIR}/config/config.yaml" "$TENSORFOLD_27B_HEALTH_TIMEOUT"

# ── Sync llama-swap ───────────────────────────────────────────────────────────
# Merges models.yml into config.yaml, restarts only on change, polls /health.
tensorfold_sync_llama_swap

# ── Smoke test through llama-swap ─────────────────────────────────────────────
if [[ "$SKIP_SMOKE" -eq 1 ]]; then
  warn "Smoke test skipped (--skip-smoke)."
else
  # enable_thinking: false (a documented per-request parameter of this engine) —
  # with the default thinking mode the think block would eat the small token
  # budget and leave message.content empty, failing the check.
  tensorfold_smoke_test "$TENSORFOLD_27B_MODEL_NAME" "$LLAMA_SWAP_PORT" "$TENSORFOLD_27B_HEALTH_TIMEOUT" "$TENSORFOLD_27B_CONTAINER" \
    "First load pulls ~19 GB of weights into the GPU and compiles CUDA kernels once — up to ${TENSORFOLD_27B_HEALTH_TIMEOUT}s."
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
