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
#   2. clone the recipe into /srv/tensorfold (re-run: fetch + force-checkout pin)
#   3. run upstream scripts/prepare.sh (image + ~122 GiB checkpoint)
#   4. merge the qwen3.8-flash-next entry into models.yml (additive; the
#      entry is replaced if the rendered template changed)
#   5. run tasks/sync-models.py (merge into llama-swap config.yaml, restart
#      only on change, poll /health)
#   6. smoke test through llama-swap (first load is a ~122 GiB weight load of
#      which ~66 GiB becomes GPU-resident)
#
# Trust boundary: the llama-swap service (root) execs start.sh/prepare.sh from
# this checkout, so anyone who can write /srv/tensorfold owns the host.
#
# The steps that are shared with the 27B sibling (pre-flight, the
# what-needs-downloading gate, pinned checkout, .env render, catalog merge,
# llama-swap sync/health-timeout/smoke test, --check signals) live in
# lib/tensorfold-helper.sh; this script keeps the recipe-specific constants and
# passes them in.
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
# Paths that depend on PROJECT_DIR are resolved AFTER argument parsing, so
# --dir / PROJECT_DIR actually moves everything (review flash F3 / 27B F1).
PROJECT_DIR="${PROJECT_DIR:-/srv/tensorfold}"
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME:-/root}/.cache/huggingface}"
# Kernel cache: NOT $HOME. llama-swap runs start.sh as root with
# ProtectHome=read-only, so a cache under the invoking user's home cannot be
# written by the service (the 27B sibling moved it for that reason; the flash
# recipe follows here). Legacy: ${HOME}/.cache/tensorfold-qwen38.
KERNEL_CACHE_DIR="${KERNEL_CACHE_DIR:-}"
TENSORFOLD_PORT="${TENSORFOLD_PORT:-8888}"
LLAMA_SWAP_PORT="${LLAMA_SWAP_PORT:-9292}"
LLAMA_SWAP_DIR="${LLAMA_SWAP_DIR:-/srv/llama-swap}"
# Writable by the llama-swap service (ProtectHome=read-only): start.sh flocks
# $STATE_DIR/start.lock and writes $LOG_DIR there at load time, so both must
# live outside $HOME. /srv is not protected by ProtectSystem=full.
TENSORFOLD_STATE_DIR="${TENSORFOLD_STATE_DIR:-}"
SKIP_SMOKE=0
# Seconds for llama-swap to wait for a first load (~122 GiB weight load).
TENSORFOLD_HEALTH_TIMEOUT="${TENSORFOLD_HEALTH_TIMEOUT:-900}"

FORCE=0
CHECK_ONLY=0

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
  echo "  --kernel-cache <path>    Engine/kernel cache (default: /srv/tensorfold/.cache)"
  echo "  --force                  Stop the running model first (upstream stop.sh) and"
  echo "                           force the catalog re-merge even if unchanged"
  echo "  --skip-smoke             Skip the post-install smoke test through llama-swap"
  echo "                           (llama-swap is still health-checked; the model itself"
  echo "                            is not exercised)"
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
  echo "  checkpoint, of which ~66 GiB becomes GPU-resident, + the engine image). That"
  echo "  check runs only while the checkpoint or the engine image is still missing — a"
  echo "  re-run with both present needs no free space at all and converges"
  echo "  (scripts/prepare.sh re-checks the exact download itself). Tune with"
  echo "  TENSORFOLD_MIN_FREE_GB / TENSORFOLD_IMAGE_GB."
  echo ""
  echo -e "${BOLD}Runtime model:${RESET}"
  echo "  The model is NOT a standalone stack. llama-swap starts the container"
  echo "  on demand (serve.cmd = upstream start.sh, blocking) and stops it via"
  echo "  cmdStop; the OpenAI API is consumed through llama-swap:"
  echo "    http://localhost:${LLAMA_SWAP_PORT}/v1  (model: ${TENSORFOLD_MODEL_NAME})"
  echo "  Serve levers (context, parallel, KV dtype, vision, ...) are upstream"
  echo "  settings: add them to ${PROJECT_DIR}/.env (see scripts/config.sh there)."
  echo "  A re-run re-renders only the keys this script owns (FOREGROUND, PORT,"
  echo "  HOST) and keeps everything else in that file."
  echo ""
  echo -e "${BOLD}Coexistence${RESET} (Qwen3.8-27B via setup-tensorfold-spark-qwen38-27b.sh):"
  echo "  The two models do NOT fit on one Spark at the same time — use"
  echo "  llama-swap's one-model-at-a-time swap. Co-loading needs reduced"
  echo "  settings on one side and TENSORFOLD_MEMORY_RESERVE_GIB=4 in"
  echo "  /srv/tensorfold-27b/.env; this recipe already keeps a 10 GiB reserve"
  echo "  (do not lower it). Ports: Flash Next 8888, 27B 8889."
  echo ""
  echo -e "${BOLD}Re-run policy${RESET} (converge by default):"
  echo "  Re-running converges: the checkout is re-pinned (fetch + force checkout),"
  echo "  the .env is re-rendered without dropping operator-added levers,"
  echo "  prepare.sh is a no-op when ready, the catalog entry is replaced only if"
  echo "  the rendered template changed, and sync-models.py restarts llama-swap"
  echo "  only when its config changed."
  echo "  Changing --port/--dir/--hf-cache/--kernel-cache on an existing install does"
  echo "  NOT converge the llama-swap entry (add-only sync in sync-models.py), even"
  echo "  though models.yml is updated. Converge the entry by deleting its section"
  echo "  from ${LLAMA_SWAP_DIR}/config/config.yaml and re-running."
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)             shift; [[ $# -gt 0 ]] || error "--port requires an argument"; TENSORFOLD_PORT="$1" ;;
    --health-timeout)   shift; [[ $# -gt 0 ]] || error "--health-timeout requires an argument"; TENSORFOLD_HEALTH_TIMEOUT="$1" ;;
    --dir)              shift; [[ $# -gt 0 ]] || error "--dir requires an argument"; PROJECT_DIR="$1" ;;
    --hf-cache)         shift; [[ $# -gt 0 ]] || error "--hf-cache requires an argument"; HF_CACHE_DIR="$1" ;;
    --kernel-cache)     shift; [[ $# -gt 0 ]] || error "--kernel-cache requires an argument"; KERNEL_CACHE_DIR="$1" ;;
    --force)            FORCE=1 ;;
    --skip-smoke)       SKIP_SMOKE=1 ;;
    --check)            CHECK_ONLY=1 ;;
    --help|-h)          usage ;;
    *) error "Unknown option: $1  (use --help for usage)" ;;
  esac
  shift
done

# Defaults that depend on a parsed value resolve here, not at load time.
: "${KERNEL_CACHE_DIR:=${PROJECT_DIR}/.cache}"
: "${TENSORFOLD_STATE_DIR:=${PROJECT_DIR}/.state}"

# Validation of the FINAL values (review flash F4: validating the defaults at
# load time meant --port abc was never checked).
tensorfold_validate_serving_settings TENSORFOLD_PORT "$TENSORFOLD_PORT" \
  LLAMA_SWAP_PORT "$LLAMA_SWAP_PORT" TENSORFOLD_HEALTH_TIMEOUT "$TENSORFOLD_HEALTH_TIMEOUT"

# The kernel cache default moved out of $HOME (ProtectHome=read-only) — used
# only to note an existing cache under the legacy path, nothing is moved.
KERNEL_CACHE_DIR_LEGACY="${HOME:-/root}/.cache/tensorfold-qwen38"

# HF cache layout of the pinned checkpoint (…/hub/models--<org>--<repo>),
# resolved after argument parsing so --check and the pre-flight probe the same
# path. The revision is NOT part of the probe (see path_has_hf_snapshot).
MODEL_CACHE_DIR="${HF_CACHE_DIR}/hub/models--azampatti--Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound"

# ── --check ───────────────────────────────────────────────────────────────────

check_status() {
  echo ""
  echo -e "${BOLD}tensorfold status${RESET}"
  echo ""
  tensorfold_status_recipe "$PROJECT_DIR" "$TENSORFOLD_RECIPE_REF"
  tensorfold_status_prepared "${TENSORFOLD_STATE_DIR}/prepared" "image + checkpoint ready"
  # Same signals as the pre-flight: presence of checkpoint and image first,
  # then free disk — and what a re-run would still have to download.
  tensorfold_resolve_pending_downloads --quiet \
    --model-label "Checkpoint" \
    --model-gb "$TENSORFOLD_MODEL_GB" \
    --image-gb "$TENSORFOLD_IMAGE_GB" \
    --cache-dir "$MODEL_CACHE_DIR" \
    --image "$TENSORFOLD_IMAGE" \
    --hf-cache "$HF_CACHE_DIR"
  if [[ "$TENSORFOLD_NEEDS_MODEL" -eq 0 ]]; then
    echo -e "  ${BOLD}Checkpoint:${RESET}   ${GREEN}present${RESET} (${MODEL_CACHE_DIR})"
  else
    echo -e "  ${BOLD}Checkpoint:${RESET}   ${YELLOW}not cached${RESET} (${MODEL_CACHE_DIR})"
  fi
  tensorfold_status_image "$TENSORFOLD_IMAGE"
  tensorfold_status_disk "$HF_CACHE_DIR"
  tensorfold_status_catalog "${REPO_ROOT}/models.yml" "$TENSORFOLD_MODEL_NAME"
  tensorfold_status_llama_swap_entry "${LLAMA_SWAP_DIR}/config/config.yaml" "$TENSORFOLD_MODEL_NAME"
  tensorfold_status_container "$TENSORFOLD_CONTAINER"
  tensorfold_status_proxy "$LLAMA_SWAP_PORT"
  tensorfold_kernel_cache_move_note "$KERNEL_CACHE_DIR" "$KERNEL_CACHE_DIR_LEGACY"
  tensorfold_sibling_port_warning "$TENSORFOLD_PORT" /srv/tensorfold-27b/.env
  echo ""
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  check_status
  exit 0
fi

# ── Pre-flight: sanity ────────────────────────────────────────────────────────
# docker daemon, envsubst/python3+PyYAML/hf, llama-swap, DGX Spark (GB10,
# sm_121) and the CDI device nvidia.com/gpu=all — all shared with the 27B
# sibling, so the checks live in lib/tensorfold-helper.sh. Last argument is the
# sizing sentence printed when the GPU is not a Spark.
step "Pre-flight checks"
tensorfold_preflight_sanity "$LLAMA_SWAP_DIR" \
  "This recipe is sized for one DGX Spark (GB10, 128 GB unified memory): ~103 GiB at startup with the defaults."

# ── Pre-flight: what still needs to be downloaded? ────────────────────────────
# Presence first, disk second, and disk only for what is missing — a re-run on a
# nearly full machine where the checkpoint and the engine image are already on
# disk must converge and download nothing (conventions.md → Re-run policy:
# converge by default). A cold install still pays the full TENSORFOLD_MIN_FREE_GB
# requirement, and prepare.sh re-checks it precisely on its own.
# Any usable cached snapshot counts, not one pinned revision
# (lib/tensorfold-helper.sh → tensorfold_resolve_pending_downloads).
tensorfold_resolve_pending_downloads \
  --model-label "Checkpoint" \
  --model-gb "$TENSORFOLD_MODEL_GB" \
  --image-gb "$TENSORFOLD_IMAGE_GB" \
  --cache-dir "$MODEL_CACHE_DIR" \
  --image "$TENSORFOLD_IMAGE" \
  --hf-cache "$HF_CACHE_DIR"

# ── --force: stop the running model first ─────────────────────────────────────
tensorfold_stop_running_model "$PROJECT_DIR" "$FORCE"

# ── Clone upstream (pinned) ───────────────────────────────────────────────────
tensorfold_checkout_pinned_recipe "$PROJECT_DIR" "$TENSORFOLD_REPO" "$TENSORFOLD_RECIPE_REF"

# ── Write ${PROJECT_DIR}/.env (upstream settings file) ────────────────────────
tensorfold_render_serve_env "${TEMPLATE_DIR}/serve.env" "${PROJECT_DIR}/.env" "$TENSORFOLD_PORT"

# ── Prepare: image + checkpoint (idempotent upstream) ─────────────────────────
step "Preparing TensorFold (image + ~122 GiB checkpoint — idempotent, can take a while)"

# KERNEL_CACHE/STATE_DIR/LOG_DIR must match the catalog entry
# (templates/tensorfold-spark-qwen38-flash/models-entry.yml): the llama-swap
# service runs with ProtectHome=read-only, so the prepared marker, the runtime
# lock/log files and the kernel cache live under ${PROJECT_DIR}, not $HOME.
tensorfold_kernel_cache_move_note "$KERNEL_CACHE_DIR" "$KERNEL_CACHE_DIR_LEGACY"
(cd "$PROJECT_DIR" && HF_CACHE="$HF_CACHE_DIR" KERNEL_CACHE="$KERNEL_CACHE_DIR" \
  STATE_DIR="$TENSORFOLD_STATE_DIR" LOG_DIR="${TENSORFOLD_STATE_DIR}/logs" bash scripts/prepare.sh)
success "Prepare complete."

# ── Merge the catalog entry into models.yml ───────────────────────────────────
step "Merging catalog entry '${TENSORFOLD_MODEL_NAME}' into models.yml"

# PROJECT_DIR is a layout value: the entry must run start.sh/prepare.sh from the
# checkout this run installed, not from the default path.
export TENSORFOLD_PORT LLAMA_SWAP_PORT PROJECT_DIR HF_CACHE_DIR KERNEL_CACHE_DIR TENSORFOLD_STATE_DIR
# Render + additive merge (merge-model-entry.py): the entry is replaced only if
# the rendered template changed, --force re-writes it.
# shellcheck disable=SC2016  # the last argument is envsubst's literal variable list
tensorfold_merge_model_entry \
  "${TEMPLATE_DIR}/models-entry.yml" \
  "${REPO_ROOT}/models.yml" \
  "${REPO_ROOT}/models.yml.default" \
  "$TENSORFOLD_MODEL_NAME" \
  "$FORCE" \
  '${PROJECT_DIR} ${TENSORFOLD_PORT} ${LLAMA_SWAP_PORT} ${HF_CACHE_DIR} ${KERNEL_CACHE_DIR} ${TENSORFOLD_STATE_DIR}'

# llama-swap's healthCheckTimeout is GLOBAL (top-level config key; llama-swap's
# own default is 120 s, kwisatz's template renders 500). A per-model value is
# accepted but ignored, so raise the global to cover the ~122 GiB first load —
# and, because sync-models.py restarts only when it has something to write, let
# the sync below force the restart when only the raise changed the file.
tensorfold_llama_swap_raise_health_timeout "${LLAMA_SWAP_DIR}/config/config.yaml" "$TENSORFOLD_HEALTH_TIMEOUT"

# ── Sync llama-swap ───────────────────────────────────────────────────────────
# Merges models.yml into config.yaml, restarts only on change, polls /health.
tensorfold_sync_llama_swap "${LLAMA_SWAP_DIR}/config/config.yaml" "$LLAMA_SWAP_PORT" "$TENSORFOLD_CONTAINER"

# ── Smoke test through llama-swap ─────────────────────────────────────────────
if [[ "$SKIP_SMOKE" -eq 1 ]]; then
  tensorfold_require_llama_swap_up "$TENSORFOLD_MODEL_NAME" "$LLAMA_SWAP_PORT" 60 "$TENSORFOLD_CONTAINER"
  warn "Smoke test skipped (--skip-smoke): the model was NOT exercised — run $0 without --skip-smoke or load it manually."
else
  tensorfold_smoke_test "$TENSORFOLD_MODEL_NAME" "$LLAMA_SWAP_PORT" "$TENSORFOLD_HEALTH_TIMEOUT" "$TENSORFOLD_CONTAINER" \
    "First load pulls ~122 GiB of weights in, ~66 GiB of them GPU-resident — up to ${TENSORFOLD_HEALTH_TIMEOUT}s."
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║     tensorfold installation complete!        ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Recipe:${RESET}        ${PROJECT_DIR} ($(git -C "$PROJECT_DIR" rev-parse --short HEAD))"
echo -e "  ${BOLD}HF cache:${RESET}      ${HF_CACHE_DIR}"
echo -e "  ${BOLD}Kernel cache:${RESET}  ${KERNEL_CACHE_DIR}"
echo -e "  ${BOLD}TensorFold port:${RESET} ${TENSORFOLD_PORT} (fixed, host network — via ${PROJECT_DIR}/.env)"
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
