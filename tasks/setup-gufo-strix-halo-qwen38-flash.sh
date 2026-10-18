#!/usr/bin/env bash
# shellcheck disable=SC1091
# =============================================================================
# setup-gufo-strix-halo-qwen38-flash.sh
# Installs Qwen3.8 Flash Next on an AMD Strix Halo machine (Ryzen AI MAX+ 395 /
# Radeon 8060S / gfx1151) via the Gufo inference engine, managed by
# llama-swap. There is no standalone stack: llama-swap owns the container
# lifecycle (serve.cmd runs our wrapper, cmdStop stops the container) and
# proxies the OpenAI API from port 9292 to Gufo on GUFO_FLASH_PORT (8901).
#
# Engine (pinned):
#   ghcr.io/gufo-org/toolboxes/gufo-runtime — GUFO_IMAGE_TAG plus a verified
#   GUFO_IMAGE_DIGEST, so the reference is immutable and still readable. The
#   image id resolved at pull time is recorded in .engine-version, so --check
#   can tell "the tag moved" from "you are still running what we installed".
#   The registry publishes tags WITHOUT a "v" prefix (see GUFO_IMAGE_TAG below
#   for the verification), which is the one thing a copied `vX.Y.Z` always gets
#   wrong: a `v`-prefixed tag is a 404 on ghcr.io and fails a cold install.
#
# Weights:
#   unsloth/Qwen3.8-Flash-Next-GGUF, default quant UD-Q4_K_XL (four shards,
#   ~111 GB) plus mmproj-BF16.gguf for vision and the shared-Q8_0 MTP
#   sidecar. Revisions are recorded, not pinned: a hard --revision in the
#   download line would make a normal re-run re-fetch 94 GB after any upstream
#   push. The recorded-vs-current comparison is printed as an advisory warning
#   (this is the same residual-risk trade-off the DGX Spark 27B task states).
#
# Workflow (all steps idempotent, converge on re-run):
#   1. pre-flight in cost order: docker, tooling, llama-swap, the Strix Halo
#      gate, the tuning state, memlock/devices/swap — and only then what still
#      needs downloading, then free disk for the missing pieces only. A re-run
#      with everything cached runs no disk check at all.
#   2. llama-swap config.yaml writability probe (read-only) — before the
#      download, because a cold install must not burn 94 GB against a
#      root:root 644 file it cannot write.
#   3. engine image pull (only if missing), directories, render .env + the two
#      wrappers
#   4. gufo-prepare.sh downloads the checkpoint files it lists itself (single
#      source of truth) and records the resolved revisions
#   5. merge the catalog entry additively, raise the global healthCheckTimeout,
#      sync llama-swap (restart only on change), smoke test
#
# Trust boundary: the llama-swap service (root) execs gufo-serve.sh out of
# /srv/gufo-qwen38-flash, so anyone who can write that directory owns the host.
# The wrappers render from templates in this repo, are mode 0755, and contain no
# secrets; secrets stay in the mode-600 .env and are referenced, never
# substituted into a generated file.
#
# The steps shared with the 27B sibling (pre-flight, the hardware and tuning
# gates, the download gate, rendering, the catalog round-trip, the smoke test,
# the --check vocabulary) live in lib/strix-halo-helper.sh. This script keeps
# the model-specific constants and passes them in.
#
# Usage:
#   ./setup-gufo-strix-halo-qwen38-flash.sh              # install / converge
#   ./setup-gufo-strix-halo-qwen38-flash.sh --check      # status, no writes
#   ./setup-gufo-strix-halo-qwen38-flash.sh --quant UD-IQ4_XS   # smaller shard
#   ./setup-gufo-strix-halo-qwen38-flash.sh --port 8911  # different port
#   ./setup-gufo-strix-halo-qwen38-flash.sh --skip-smoke # do not load it now
#   ./setup-gufo-strix-halo-qwen38-flash.sh --help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/gufo-strix-halo-qwen38-flash"
REPO_ROOT="${SCRIPT_DIR}/.."

# shellcheck source=../lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"
# Same reason as in setup-strix-halo-tuning.sh: assign the floor before the
# helper publishes its own 125 default, or the override is inert.
STRIX_MIN_RAM_GIB="${STRIX_MIN_RAM_GIB:-120}"
# shellcheck source=../lib/strix-halo-helper.sh
source "${SCRIPT_DIR}/../lib/strix-halo-helper.sh"

# ── Identity ─────────────────────────────────────────────────────────────────
# "qwen3.8-flash-next" is the TensorFold/DGX-Spark entry and keeps its id; the
# two never coexist on one machine (different hardware gates) but the catalog
# is shared, so the id here names the engine. No case-only alias, and no bare
# "qwen3.8" — that is a TensorFold alias already.
GUFO_MODEL_NAME="qwen3.8-flash-next-gufo"
GUFO_CONTAINER="qwen38-flash-gufo"

# ── Pinned engine ─────────────────────────────────────────────────────────────
GUFO_IMAGE_REPO="ghcr.io/gufo-org/toolboxes/gufo-runtime"
# The tag is what makes the reference readable, the digest is what makes it
# reproducible; both default to a value verified against the registry, not
# copied from a post. Checked 2026-10-17 against the ghcr HTTP API:
#
#   tok=$(curl -s "https://ghcr.io/token?scope=repository:gufo-org/toolboxes/gufo-runtime:pull" | jq -r .token)
#   curl -s -D- -o /dev/null -H "Authorization: Bearer $tok" \
#     https://ghcr.io/v2/gufo-org/toolboxes/gufo-runtime/manifests/0.8.1
#   -> HTTP 200, docker-content-digest: sha256:56f0a052e784…
#   /tags/list -> 0.8.0, 0.8.1, … 0.17.0 (current), and NO "v"-prefixed tag.
#
# So `v0.8.0` never existed: the tag is `0.8.0`, and 0.8.1 is its patch. Bump
# deliberately — tag AND digest together — then re-read the serve flags from the
# new tag's source, because a flag rename shows up as a container that exits at
# once rather than as a slow load.
GUFO_IMAGE_TAG="${GUFO_IMAGE_TAG:-0.8.1}"
# Leave empty to pin by tag only. Set it to a registry digest (sha256:…) to
# make the reference immutable; docker then ignores the tag, and the recorded
# image id still tells --check what actually ran.
GUFO_IMAGE_DIGEST="${GUFO_IMAGE_DIGEST:-sha256:56f0a052e784fdfd43ebe2aba590336c8fb5b05c5a813aaebb5ac98d61010afd}"
GUFO_IMAGE="${GUFO_IMAGE:-${GUFO_IMAGE_REPO}:${GUFO_IMAGE_TAG}}"
if [[ -n "$GUFO_IMAGE_DIGEST" && "$GUFO_IMAGE" == "${GUFO_IMAGE_REPO}:${GUFO_IMAGE_TAG}" ]]; then
  GUFO_IMAGE="${GUFO_IMAGE_REPO}@${GUFO_IMAGE_DIGEST}"
fi

# ── Weights ───────────────────────────────────────────────────────────────────
GUFO_MODEL_REPO="${GUFO_MODEL_REPO:-unsloth/Qwen3.8-Flash-Next-GGUF}"
# Empty = whatever main is now. Recorded after the download, warned about on
# drift, pinned only if you set this.
GUFO_MODEL_REVISION="${GUFO_MODEL_REVISION:-}"
# The checkpoint is the repo's own directory per quantisation, and the shards
# live inside it:
#
#   UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf  … of-00004
#
# so the pattern is directory + glob, which is also what upstream's own download
# line uses (`--include "UD-Q4_K_XL/*"`). A bare file-name glob here matches
# nothing, and "nothing" is what the gate and serve both report.
#
# UD-Q4_K_XL is the target upstream documents and benchmarks (~111 GB, four
# shards). UD-IQ4_XS (~94 GB, three shards) is the label to pick when the box
# also runs the 27B or when the KV budget needs the room.
GUFO_QUANT="${GUFO_QUANT:-UD-Q4_K_XL}"
GUFO_SHARD_PATTERN="${GUFO_QUANT}/*.gguf"
GUFO_MMPROJ_PATTERN="mmproj-BF16.gguf"
# The MTP sidecar is a *subdirectory* of the same repo — upstream's validated
# recipe names MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf, not the root-level
# mtp-Qwen3.8-Flash-Next-Q8_0.gguf that shares its name.
GUFO_DRAFT_PATTERN="MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0*.gguf"
GUFO_DRAFT_REPO="${GUFO_DRAFT_REPO:-$GUFO_MODEL_REPO}"

# ── Layout ────────────────────────────────────────────────────────────────────
GUFO_FLASH_PORT="${GUFO_FLASH_PORT:-8901}"
GUFO_FLASH_HEALTH_TIMEOUT="${GUFO_FLASH_HEALTH_TIMEOUT:-1800}"
PROJECT_DIR="${PROJECT_DIR:-/srv/gufo-qwen38-flash}"
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME:-/root}/.cache/huggingface}"
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/.state}"
LLAMA_SWAP_PORT="${LLAMA_SWAP_PORT:-9292}"
LLAMA_SWAP_DIR="${LLAMA_SWAP_DIR:-/srv/llama-swap}"
# The 27B sibling, so "what does this box already have" is a real question
# rather than a guess. Override it when the sibling lives elsewhere — a
# hardcoded /srv path that silently misses the install is worse than not
# checking, because it prints a clean result for a box that is on fire.
STRIX_SIBLING_DIR="${STRIX_SIBLING_DIR:-/srv/gufo-qwen38-27b}"
STRIX_SIBLING_ENV="${STRIX_SIBLING_ENV:-${STRIX_SIBLING_DIR}/.env}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
# The binary the wrappers pass as --entrypoint. The pinned runtime ships
# without an entrypoint (CMD is /bin/bash), so naming it is the wrapper's
# job; empty defers to the image's own entrypoint (only for images that
# have one).
GUFO_ENTRYPOINT="${GUFO_ENTRYPOINT:-gufo}"
CONTAINER_EXTRA_ARGS="${CONTAINER_EXTRA_ARGS:-}"
GUFO_EXTRA_ARGS="${GUFO_EXTRA_ARGS:-}"
# Speculation, on by default: `--speculative mtp` plus the shared-Q8_0 sidecar
# is the configuration upstream measures Flash-Next with (docs/models/
# qwen3.8-flash-next), and both spellings were checked against the v0.8.1
# option table rather than guessed. The wrapper appends --mtp-model with the
# path it resolved, so this key carries only the switch, and a
# GUFO_SPEC_ARGS= re-run turns the whole thing off without costing the load.
# unset means "default recipe", explicitly empty means "no speculation" —
# which is why this is a set-test and not the dash form: written as
# ${GUFO_SPEC_ARGS----speculative mtp} that expansion silently gains a dash,
# the wrapper matches no backend, and speculation turns off quietly. `! -v`
# keeps both documented cases correct.
if [[ ! -v GUFO_SPEC_ARGS ]]; then
  GUFO_SPEC_ARGS="--speculative mtp"
fi
GUFO_CONTEXT_WINDOW="${GUFO_CONTEXT_WINDOW:-262144}"
GUFO_MAX_TOKENS="${GUFO_MAX_TOKENS:-32768}"
GUFO_SHM_SIZE="${GUFO_SHM_SIZE:-16g}"
GUFO_SESSIONS="${GUFO_SESSIONS:-1}"
# Disk staging for the prompt cache: off by default (8 GiB resident that this
# machine would rather give the model). See decision G in the plan.
GUFO_CACHE_DISK_STAGING_BYTES="${GUFO_CACHE_DISK_STAGING_BYTES:-0}"
HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-11.5.1}"
HSA_ENABLE_SDMA="${HSA_ENABLE_SDMA:-0}"
# Fraction of the GPU aperture; blank = the engine's own default.
GUFO_GPU_MEMORY_UTILIZATION="${GUFO_GPU_MEMORY_UTILIZATION:-}"

# Disk numbers, per piece that still has to be downloaded. A cold install
# needs ~120 GB of what the checkpoint needs: UD-Q4_K_XL is 111.3 GB across four
# shards, mmproj-BF16 another 0.9 GB and the MTP sidecar 2.8 GB, i.e. ~115 GB
# before the engine image. Re-checked, precisely, by hf itself.
STRIX_FLASH_MIN_FREE_GB="${STRIX_FLASH_MIN_FREE_GB:-120}"
GUFO_IMAGE_GB="${GUFO_IMAGE_GB:-25}"
STRIX_FLASH_MODEL_GB=$((STRIX_FLASH_MIN_FREE_GB - GUFO_IMAGE_GB))

# 1 = a non-Strix machine is a hard error (default). warn = print and carry on,
# for a developer who is testing the script on other hardware.
STRIX_HW_CHECK="${STRIX_HW_CHECK:-error}"
# The tuning script's GPU reserve must be ACTIVE, not merely written. Set to 1
# to install anyway on a box you know you are about to reboot.
STRIX_ALLOW_UNTUNED="${STRIX_ALLOW_UNTUNED:-0}"

FORCE="${FORCE:-0}"
SKIP_SMOKE="${SKIP_SMOKE:-0}"
CHECK_ONLY=0

usage() {
  cat <<EOF
setup-gufo-strix-halo-qwen38-flash.sh — Qwen3.8 Flash Next via Gufo on AMD Strix Halo

Installs the pinned Gufo runtime as a llama-swap-managed model and downloads
the ${GUFO_MODEL_REPO} checkpoint (${GUFO_QUANT}).

USAGE
  $0 [OPTIONS]

OPTIONS
  --port <n>            Port Gufo binds on the host network (default: ${GUFO_FLASH_PORT}).
                        llama-swap's proxy points at it, so changing it after the
                        first install also needs the entry to be converged — see
                        "Re-run policy".
  --health-timeout <s>  Seconds a first load may take (default: ${GUFO_FLASH_HEALTH_TIMEOUT}).
                        Raises llama-swap's GLOBAL healthCheckTimeout to at least
                        this (the field is global in llama-swap, not per-model) and
                        bounds the smoke-test wait. A first load reads ~115 GB
                        of weights; this number is deliberately boring.
  --dir <path>          Service dir (default: ${PROJECT_DIR})
  --hf-cache <path>     Host HuggingFace cache (default: ${HF_CACHE_DIR})
  --state-dir <path>    Marker/logs dir (default: ${STATE_DIR})
  --quant <label>       Which shard to serve (default: ${GUFO_QUANT}). The file
                        list and the serve path both come from this, so the two
                        cannot disagree. UD-IQ4_XS (~94 GB) is the label to reach
                        for when memory matters more than quality.
  --force               Stop the running model first and force the catalog
                        re-merge even if the rendered entry is unchanged
  --skip-smoke          Do not load the model after installing. llama-swap is
                        still health-checked and its /v1/models is still read —
                        what you lose is the one chat completion that proves the
                        engine actually answers.
  --check               Show installation status and exit
  --help                Show this help

ENVIRONMENT (every flag above has an env equivalent)
  GUFO_FLASH_PORT, GUFO_FLASH_HEALTH_TIMEOUT, PROJECT_DIR, HF_CACHE_DIR,
  STATE_DIR, LLAMA_SWAP_PORT, LLAMA_SWAP_DIR, GUFO_IMAGE, GUFO_IMAGE_TAG,
  GUFO_IMAGE_DIGEST, GUFO_MODEL_REPO, GUFO_MODEL_REVISION, GUFO_QUANT,
  GUFO_DRAFT_REPO, CONTAINER_RUNTIME, CONTAINER_EXTRA_ARGS, GUFO_ENTRYPOINT,
  GUFO_EXTRA_ARGS, GUFO_SPEC_ARGS, GUFO_CONTEXT_WINDOW, GUFO_MAX_TOKENS, STRIX_FLASH_MIN_FREE_GB,
  GUFO_IMAGE_GB, GPU_RESERVE_GIB (read here, written by setup-strix-halo-tuning),
  STRIX_MIN_RAM_GIB (the RAM floor, 120 GiB by default),
  STRIX_ALLOW_UNTUNED, STRIX_HW_CHECK, SKIP_SMOKE, FORCE

REQUIREMENTS
  An AMD Strix Halo (Ryzen AI MAX+ 395, Radeon 8060S, gfx1151) with
  kernel >= 6.18.9 and >= 120 GiB of RAM, setup-docker.sh, setup-llama-swap.sh,
  and setup-strix-halo-tuning.sh already run with its GPU reserve ACTIVE — this
  script checks that and stops within seconds if it is not, rather than loading
  a model that will fail partway. ~${STRIX_FLASH_MIN_FREE_GB} GB free under
  HF_CACHE_DIR for a cold install, and the 'hf' CLI (pip install -U
  "huggingface_hub[cli]").

FREE DISK
  The disk check runs only for what is still missing: weights are probed by
  file presence (gufo-prepare.sh --list-files), the image by docker inspect.
  Both present → no free-space check at all, and the run converges on a
  nearly-full filesystem. Weights missing and space short is a hard error
  naming the pieces and the remediation (hf cache rm / HF_CACHE_DIR=), never a
  partial download.

RUNTIME MODEL
  There is no docker-compose stack for this model. llama-swap starts the
  container on demand (serve.cmd blocks for its lifetime) and stops it via
  cmdStop. Consume the API through llama-swap:
    http://localhost:${LLAMA_SWAP_PORT}/v1  (model: ${GUFO_MODEL_NAME})
  Serve levers (sessions, prompt-cache staging, speculation flags, extra docker
  args) live in ${PROJECT_DIR}/.env — a re-run re-renders the keys it owns and
  keeps every line you added. Gufo's own flags:
    docker run --rm --entrypoint gufo ${GUFO_IMAGE} serve llm --help
  checkEndpoint is /v1/models, not /health: Gufo opens its port before the
  weights are resident, so "the port answers" is not readiness.

COEXISTENCE (Qwen3.8 27B via setup-gufo-strix-halo-qwen38-27b.sh)
  Both at full size does not fit: UD-Q4_K_XL here is 111.3 GB and the 27B's
  UD-Q4_K_XL is 17.6 GB, so 119.9 GiB of weights inside a ${GPU_RESERVE_GIB:-120}
  GiB reserve — that is the reserve, with nothing left for KV cache, sidecars or
  the OS. The recipe that does fit is this stack at UD-IQ4_XS (93.7 GB) next to
  the 27B (17.6 GB), which leaves about 16 GiB. Load one at a time through
  llama-swap otherwise. Ports: Flash Next ${GUFO_FLASH_PORT}, 27B 8902.

RE-RUN POLICY (converge by default)
  Re-running re-renders .env and both wrappers, short-circuits prepare when the
  weights are cached, replaces the catalog entry only if the rendered entry
  changed, raises healthCheckTimeout once, and restarts llama-swap only when
  its config changed. The one non-convergeable case is documented and exits 0:
  the GPU reserve written but not active (needs a reboot).
  Changing --port/--dir/--hf-cache here does NOT rewrite the existing
  llama-swap entry (add-only sync), even though models.yml is updated. Fix:
  delete this model's section from ${LLAMA_SWAP_DIR}/config/config.yaml and
  re-run.

TRUST BOUNDARY
  llama-swap runs as root and execs ${PROJECT_DIR}/gufo-serve.sh, so write
  access to that directory is root access. The wrappers are rendered from this
  repo, are mode 0755, and carry no secrets.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --port)
    [[ $# -gt 1 ]] || error "--port requires an argument"
    GUFO_FLASH_PORT="$2"
    shift
    ;;
  --health-timeout)
    [[ $# -gt 1 ]] || error "--health-timeout requires an argument"
    GUFO_FLASH_HEALTH_TIMEOUT="$2"
    shift
    ;;
  --dir)
    [[ $# -gt 1 ]] || error "--dir requires an argument"
    PROJECT_DIR="$2"
    shift
    ;;
  --hf-cache)
    [[ $# -gt 1 ]] || error "--hf-cache requires an argument"
    HF_CACHE_DIR="$2"
    shift
    ;;
  --state-dir)
    [[ $# -gt 1 ]] || error "--state-dir requires an argument"
    STATE_DIR="$2"
    shift
    ;;
  --quant)
    [[ $# -gt 1 ]] || error "--quant requires an argument"
    GUFO_QUANT="$2"
    GUFO_SHARD_PATTERN="${GUFO_QUANT}/*.gguf"
    shift
    ;;
  --force) FORCE=1 ;;
  --skip-smoke) SKIP_SMOKE=1 ;;
  --check) CHECK_ONLY=1 ;;
  -h | --help) usage ;;
  *)
    error "Unknown option: $1  (use --help for usage)"
    ;;
  esac
  shift
done

# Defaults that depend on a parsed value resolve here, not at load time.
: "${STATE_DIR:=${PROJECT_DIR}/.state}"
: "${MODEL_CACHE_DIR:=${HF_CACHE_DIR}/hub/models--${GUFO_MODEL_REPO//\//--}}"

# Validation of the FINAL values, after parsing and after defaults that depend
# on them resolved.
strix_validate_serving_settings "$GUFO_FLASH_PORT" "$LLAMA_SWAP_PORT" || exit 1
[[ "$GUFO_FLASH_HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] \
  || die "--health-timeout must be a number of seconds (got '${GUFO_FLASH_HEALTH_TIMEOUT}')"

# ── --check ───────────────────────────────────────────────────────────────────
check_status() {
  echo ""
  echo -e "${BOLD}gufo-qwen38-flash status${RESET}  ${GUFO_MODEL_NAME}"
  echo ""
  strix_status_gpu
  strix_status_gtt "${GPU_RESERVE_GIB:-120}"
  strix_status_locked_memory
  strix_status_swap
  strix_status_devices
  echo
  strix_status_weights "$MODEL_CACHE_DIR"
  strix_status_engine_image "$GUFO_IMAGE"
  strix_status_disk "$HF_CACHE_DIR" "$STRIX_FLASH_MIN_FREE_GB"
  echo
  strix_status_catalog "${REPO_ROOT}/models.yml" "$GUFO_MODEL_NAME"
  strix_status_llama_swap_entry "${LLAMA_SWAP_DIR}/config/config.yaml" "$GUFO_MODEL_NAME"
  strix_status_llama_swap_writable "${LLAMA_SWAP_DIR}/config/config.yaml"
  strix_status_container "$GUFO_CONTAINER"
  strix_status_proxy "$LLAMA_SWAP_PORT"
  strix_status_engine "$GUFO_FLASH_PORT" "$GUFO_MODEL_NAME"
  echo
  strix_status_memory_budget "$([[ -f "$STRIX_SIBLING_ENV" ]] && echo both || echo flash)"
  strix_sibling_port_warning "$GUFO_FLASH_PORT" "$STRIX_SIBLING_ENV"
  strix_sibling_container_warning "$GUFO_MODEL_NAME" "$STRIX_SIBLING_ENV"
  strix_engine_version_drift "${PROJECT_DIR}/.engine-version" "$GUFO_IMAGE"
  echo
  echo -e "  ${BOLD}Load:${RESET}   curl -s http://localhost:${LLAMA_SWAP_PORT}/v1/chat/completions -H 'Content-Type: application/json' -H \"Authorization: Bearer \$(grep -A1 '^apiKeys:' ${LLAMA_SWAP_DIR}/config/config.yaml | tail -1 | sed 's/^- //')\" -d '{\"model\":\"${GUFO_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":32}'"
  echo -e "          ${YELLOW}(llama-swap >= v219 rejects JSON POSTs without Content-Type; if apiKeys are unset, drop the Authorization header)${RESET}"
  echo -e "  ${BOLD}Unload:${RESET} llama-swap unloads by TTL/swap; a stale container dies with: docker rm -f ${GUFO_CONTAINER}"
  echo ""
}

if [[ "$CHECK_ONLY" == "1" ]]; then
  check_status
  exit 0
fi

# ── 1. Pre-flight, in cost order ─────────────────────────────────────────────
# Order is the design: docker, tooling and llama-swap are free, the hardware
# gate is free, and the 94 GB download is the most expensive thing this script
# can do. Reporting the expensive one first is how a five-second problem turns
# into an hour of wasted bandwidth.
strix_require_docker
strix_require_tooling
strix_require_llama_swap

strix_require_strix_hal "this stack" || {
  if [[ "$STRIX_HW_CHECK" == "warn" ]]; then
    warn "STRIX_HW_CHECK=warn — continuing on non-Strix Halo hardware"
  else
    die "not an AMD Strix Halo machine. Set STRIX_HW_CHECK=warn to install anyway (supported only for development)."
  fi
}

strix_require_tuning "this stack" \
  || [[ "$STRIX_ALLOW_UNTUNED" == "1" ]] \
  || die "the GPU memory reserve is not active. Run tasks/setup-strix-halo-tuning.sh (and reboot if it says so), or set STRIX_ALLOW_UNTUNED=1 to proceed anyway."

strix_require_locked_memory || die "dockerd cannot load a model this large under its current locked-memory limit — see the fix printed above"
strix_require_devices
strix_warn_swap

# ── 2. What still needs downloading? ─────────────────────────────────────────
step "Resolving what still needs downloading"
strix_resolve_pending_downloads \
  --model-label "Checkpoint" \
  --model-gb "$STRIX_FLASH_MODEL_GB" \
  --image-gb "$GUFO_IMAGE_GB" \
  --hf-cache "$HF_CACHE_DIR" \
  --required-from "${PROJECT_DIR}/gufo-prepare.sh" \
  --repo-dir "$MODEL_CACHE_DIR" \
  --image-ref "$GUFO_IMAGE"

if [[ "$STRIX_NEEDS_MODEL" == "yes" || "$STRIX_NEEDS_IMAGE" == "yes" ]]; then
  require_free_space "$HF_CACHE_DIR" "$STRIX_PENDING_GB" \
    "${STRIX_PENDING:-the remaining pieces}" || die "not enough free space for what is missing — see above"
else
  info "Nothing to download; skipping the free-disk check"
fi

# ── 3. llama-swap config writability (before the download) ───────────────────
# Read-only probe. Silent when there is no config yet (first sync will create
# it); loud when it exists and is not ours, because that is the one failure
# that should be discovered before 94 GB, not after.
strix_require_llama_swap_config_writable "${LLAMA_SWAP_DIR}/config/config.yaml" || die "llama-swap's config is not writable by this user — see the command above"

# ── 4. Force: stop what is running ───────────────────────────────────────────
strix_stop_running_model "$PROJECT_DIR" "$FORCE" "$GUFO_CONTAINER"

# ── 5. Engine image ──────────────────────────────────────────────────────────
strix_pull_engine_image "$GUFO_IMAGE" || die "could not pull ${GUFO_IMAGE} — check the tag/digest and that ghcr.io is reachable"
warn_moving_image "$GUFO_IMAGE" "GUFO_IMAGE"

# ── 6. Directories ───────────────────────────────────────────────────────────
# /srv/<svc> and its .state, created with the same escalation order as the
# render helpers: plain install first, so a re-run whose directories already
# exist and belong to the invoking user never needs a sudo ticket; sudo only
# for the first create (when /srv needs a new directory) or a wrong owner.
step "Preparing ${PROJECT_DIR}"
if ! { install -d -m 755 -o "$(id -un)" -g "$(id -gn)" "$PROJECT_DIR" "$STATE_DIR" "$STATE_DIR/logs" 2>/dev/null \
  || sudo install -d -m 755 -o "$(id -un)" -g "$(id -gn)" "$PROJECT_DIR" "$STATE_DIR" "$STATE_DIR/logs"; }; then
  die "could not create ${PROJECT_DIR} / ${STATE_DIR}"
fi
if [[ -f "${PROJECT_DIR}/gufo-serve.sh" && ! -r "${PROJECT_DIR}/gufo-serve.sh" ]]; then
  die "${PROJECT_DIR}/gufo-serve.sh exists but is not readable/writable by $(id -un) — that is not this script's file. Inspect it, then remove it deliberately."
fi

# ── 7. Render .env and the wrappers ─────────────────────────────────────────
# Layout values are envsubst'ed; nothing secret is substituted. The operator's
# own .env levers survive because the renderer keeps keys it does not own.
export PROJECT_DIR STATE_DIR HF_CACHE_DIR GUFO_FLASH_PORT LLAMA_SWAP_PORT
export GUFO_MODEL_NAME GUFO_CONTAINER GUFO_IMAGE GUFO_MODEL_REPO
export GUFO_SHARD_PATTERN GUFO_MMPROJ_PATTERN GUFO_DRAFT_PATTERN GUFO_DRAFT_REPO
export GUFO_MODEL_REVISION GUFO_CONTEXT_WINDOW GUFO_MAX_TOKENS
export GUFO_SHM_SIZE GUFO_SESSIONS GUFO_CACHE_DISK_STAGING_BYTES
export GUFO_EXTRA_ARGS CONTAINER_EXTRA_ARGS GUFO_SPEC_ARGS GUFO_ENTRYPOINT
# serve.env carries GUFO_GPU_MEMORY_UTILIZATION in its owned-key list, so it is
# rendered from the task's default like every other owned key: unexported, that
# key would come out blank and a value set in the environment would be silently
# dropped.
export GUFO_GPU_MEMORY_UTILIZATION
export CONTAINER_RUNTIME HSA_OVERRIDE_GFX_VERSION HSA_ENABLE_SDMA
# Rendered into the wrappers as the one absolute path they start from.
export STATE_DIR_PATH="$STATE_DIR"
# Rendered into both wrappers as the absolute path of the env file they source.
# Both wrappers used to derive it from STATE_DIR (".state/.env"), which is not
# where it is written: it sits next to the wrappers, in PROJECT_DIR.
export GUFO_ENV_FILE="$PROJECT_DIR/.env"
export GUFO_MODEL_CACHE_NAME="${GUFO_MODEL_REPO//\//--}"
# Names the templates use. Two families, on purpose:
#   *_DEFAULT   — the fallback a wrapper prints into, so .env stays the lever
#   CONTAINER_NAME / HF_CACHE / PORT / GUFO_PORT — the literal key names the
#                 rendered files carry, so envsubst cannot leave a ${...} behind
export GUFO_PORT_DEFAULT="$GUFO_FLASH_PORT"
export GUFO_PORT="$GUFO_FLASH_PORT"
# The literal key name serve.env carries. Same reason as GUFO_PORT: it is in the
# envsubst list, so unexported it renders as PORT= (blank) and the renderer's
# own "PORT is missing, add it" fallback never fires.
export PORT="$GUFO_FLASH_PORT"
export CONTAINER_NAME="$GUFO_CONTAINER"
export HF_CACHE="$HF_CACHE_DIR"
export HF_CACHE_DEFAULT="$HF_CACHE_DIR"
export GUFO_IMAGE_DEFAULT="$GUFO_IMAGE"
export GUFO_CONTAINER_NAME="$GUFO_CONTAINER"
export GUFO_MODEL_NAME_DEFAULT="$GUFO_MODEL_NAME"
export GUFO_CONTEXT_DEFAULT="$GUFO_CONTEXT_WINDOW"
export GUFO_REVISION_DEFAULT="$GUFO_MODEL_REVISION"

# shellcheck disable=SC2016  # envsubst expects the literal variable list
strix_render_serve_env "${TEMPLATE_DIR}/serve.env" "${PROJECT_DIR}/.env" \
  "$GUFO_FLASH_PORT" \
  '${PORT} ${CONTAINER_NAME} ${STATE_DIR} ${HF_CACHE} ${GUFO_MODEL_NAME} ${GUFO_IMAGE}
   ${HSA_OVERRIDE_GFX_VERSION} ${HSA_ENABLE_SDMA} ${GUFO_SHM_SIZE} ${GUFO_SESSIONS}
   ${GUFO_CACHE_DISK_STAGING_BYTES} ${GUFO_EXTRA_ARGS} ${CONTAINER_EXTRA_ARGS}
   ${GUFO_DRAFT_REPO} ${GUFO_DRAFT_PATTERN} ${GUFO_SPEC_ARGS} ${GUFO_ENTRYPOINT}
   ${GUFO_GPU_MEMORY_UTILIZATION}' \
  || die "could not render ${PROJECT_DIR}/.env"

# Linger so the service survives logout is the tuning script's business, not
# this one's.
# shellcheck disable=SC2016  # envsubst expects the literal variable list
strix_render_wrapper "${TEMPLATE_DIR}/gufo-serve.sh" "${PROJECT_DIR}/gufo-serve.sh" \
  '${STATE_DIR_PATH} ${GUFO_ENV_FILE} ${GUFO_PORT_DEFAULT} ${GUFO_CONTAINER_NAME} ${HF_CACHE_DEFAULT}
   ${GUFO_IMAGE_DEFAULT} ${GUFO_MODEL_NAME_DEFAULT} ${GUFO_CONTEXT_DEFAULT}
   ${GUFO_MODEL_CACHE_NAME} ${GUFO_SHARD_PATTERN}' \
  || die "could not render ${PROJECT_DIR}/gufo-serve.sh"

# shellcheck disable=SC2016  # envsubst expects the literal variable list
strix_render_wrapper "${TEMPLATE_DIR}/gufo-prepare.sh" "${PROJECT_DIR}/gufo-prepare.sh" \
  '${STATE_DIR_PATH} ${GUFO_ENV_FILE} ${GUFO_MODEL_REPO} ${GUFO_SHARD_PATTERN} ${GUFO_MMPROJ_PATTERN}
   ${GUFO_DRAFT_REPO} ${GUFO_DRAFT_PATTERN} ${GUFO_IMAGE_DEFAULT} ${GUFO_REVISION_DEFAULT}' \
  || die "could not render ${PROJECT_DIR}/gufo-prepare.sh"

# ── 8. Weights ───────────────────────────────────────────────────────────────
# The wrapper owns the file list; this is the only call. It is a handful of
# tests when everything is already cached.
step "Preparing weights"
if ! STATE_DIR="$STATE_DIR" HF_CACHE="${HF_CACHE:-$HF_CACHE_DIR}" HF_TOKEN="${HF_TOKEN:-}" \
  bash "${PROJECT_DIR}/gufo-prepare.sh"; then
  die "gufo-prepare.sh failed — its output above names the file and the repo"
fi
strix_checkpoint_revision_record "${STATE_DIR}/prepared" "$GUFO_MODEL_REPO" "$MODEL_CACHE_DIR"
strix_checkpoint_revision_recheck "${STATE_DIR}/prepared" "$GUFO_MODEL_REPO"

# ── 9. Catalog ───────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # envsubst expects the literal variable list
strix_merge_model_entry "${TEMPLATE_DIR}/models-entry.yml" \
  "${REPO_ROOT}/models.yml" "${REPO_ROOT}/models.yml.default" \
  "$GUFO_MODEL_NAME" "$FORCE" \
  '${PROJECT_DIR} ${STATE_DIR} ${HF_CACHE_DIR} ${GUFO_MODEL_CACHE_NAME} ${GUFO_PORT} ${LLAMA_SWAP_PORT}
   ${GUFO_MODEL_NAME} ${GUFO_CONTAINER_NAME} ${GUFO_CONTEXT_WINDOW} ${GUFO_MAX_TOKENS}' \
  || die "could not merge the catalog entry for ${GUFO_MODEL_NAME}"

strix_llama_swap_raise_health_timeout "${LLAMA_SWAP_DIR}/config/config.yaml" "$GUFO_FLASH_HEALTH_TIMEOUT"

strix_sync_llama_swap "${LLAMA_SWAP_DIR}/config/config.yaml" "$LLAMA_SWAP_PORT" "$GUFO_CONTAINER" \
  || die "llama-swap sync failed — check ${LLAMA_SWAP_DIR}/config/config.yaml"

# ── 10. Engine version bookkeeping ───────────────────────────────────────────
strix_record_engine_version "${PROJECT_DIR}/.engine-version" "$GUFO_IMAGE"

# ── 11. Smoke test ───────────────────────────────────────────────────────────
if [[ "$SKIP_SMOKE" == "1" ]]; then
  strix_require_llama_swap_up "$GUFO_MODEL_NAME" "$LLAMA_SWAP_PORT" \
    || die "llama-swap is not answering as expected after the sync"
  warn "Smoke test SKIPPED (--skip-smoke): the entry is installed and llama-swap"
  warn "answered /health and listed ${GUFO_MODEL_NAME}, but no request was sent —"
  warn "the engine itself has not been exercised. Load it once for real before"
  warn "relying on it; the first load is a ${STRIX_FLASH_MODEL_GB} GB read."
else
  strix_smoke_test "$GUFO_MODEL_NAME" "http://localhost:${LLAMA_SWAP_PORT}" "$GUFO_FLASH_PORT" \
    "$GUFO_FLASH_HEALTH_TIMEOUT" || die "the model did not answer through llama-swap — see the diagnosis above"
fi

# ── 12. Summary ──────────────────────────────────────────────────────────────
echo
success "Qwen3.8 Flash Next is installed via Gufo on Strix Halo"
echo
echo -e "  ${BOLD}Model id:${RESET}   ${GUFO_MODEL_NAME}   (aliases: Qwen3.8-Flash-Next-GGUF, qwen3.8-flash-gufo)"
echo -e "  ${BOLD}OpenAI API:${RESET} http://localhost:${LLAMA_SWAP_PORT}/v1"
echo -e "  ${BOLD}Engine:${RESET}       http://127.0.0.1:${GUFO_FLASH_PORT} (/v1/models is the readiness endpoint)"
echo -e "  ${BOLD}Weights:${RESET}      ${MODEL_CACHE_DIR}"
echo -e "  ${BOLD}Quant:${RESET}        ${GUFO_QUANT}   (change with --quant; it drives both the file list and the serve path)"
echo -e "  ${BOLD}Service dir:${RESET}  ${PROJECT_DIR} (.env, gufo-serve.sh, gufo-prepare.sh)"
echo -e "  ${BOLD}State:${RESET}        ${STATE_DIR}"
echo -e "  ${BOLD}Health:${RESET}       llama-swap healthCheckTimeout >= ${GUFO_FLASH_HEALTH_TIMEOUT} s"
echo
info "Re-run converges: $0 --check shows what it thinks is true."
info "First load reads ~${STRIX_FLASH_MODEL_GB} GB; keep other engines off it."
info "Coexistence: the 27B leaves <10 GiB headroom alongside this one — see --help."
info "If llama-swap restarts while a container is running it prints a stale-"
echo -e "   container hint; clear it with ${BOLD}docker rm -f ${GUFO_CONTAINER}${RESET}"

# Cross-service checks, run on both the install path and --check, so the
# coexistence advice does not depend on which command someone typed.
strix_sibling_container_warning "$GUFO_MODEL_NAME" "$STRIX_SIBLING_ENV"
if [[ -f "$STRIX_SIBLING_ENV" ]]; then
  info "The 27B stack is installed here too (${STRIX_SIBLING_DIR}). Both resident at"
  info "once is <10 GiB of headroom — load one at a time through llama-swap, or"
  info "serve Flash-Next at UD-IQ4_XS. See --help, section Coexistence."
fi
