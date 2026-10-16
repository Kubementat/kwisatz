#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# lib/tensorfold-helper.sh — Shared logic for the TensorFold DGX Spark tasks
# =============================================================================
#
# PURPOSE:
#   Companion to lib/helpers.sh for tasks/setup-tensorfold-spark-qwen38-{flash,27b}.sh.
#   Both scripts drive a pinned MiaAI-Lab TensorFold recipe into a llama-swap
#   managed model, and after the last fixes roughly 60-70% of their text was
#   identical (both reviews: F12/F9 — every finding had to be applied twice).
#   This library holds exactly that shared procedure. Per-task differences
#   (model name, container, ports, sizes, cache dirs, template dir) stay in the
#   task scripts and arrive as arguments — there is no "is it flash / is it
#   27B" branch anywhere here.
#
# USAGE:
#   source "${SCRIPT_DIR}/../lib/helpers.sh"            # general library, first
#   source "${SCRIPT_DIR}/../lib/tensorfold-helper.sh"  # tensorfold-specific
#
# NOTES:
#   - Sourced, never executed. All definitions are guarded so re-sourcing is
#     safe and a task-local override of a function is not overwritten.
#   - Depends on lib/helpers.sh: info/success/warn/error, err_msg, mktempfile.
#     error/die terminate the process — exactly where the task scripts called
#     them before, so no exit code changes.
#   - Resolving functions publish TENSORFOLD_* globals (documented on each
#     function); they are plain data, set once, read afterwards.
#   - Output text, message ordering and file modes are intentionally identical
#     to the two task scripts before the factor-out: this is a move, not a
#     change of behaviour. Do not "improve" a message here without checking
#     both consumers.
# =============================================================================

# ---------------------------------------------------------------------------
# _tensorfold_task_dir
#   Directory holding the task scripts that the shared blocks call out to
#   (merge-model-entry.py, sync-models.py). The sourcing task script's own
#   SCRIPT_DIR wins, so a worktree/repo copy of the repo uses its own copies;
#   falls back to this library's sibling tasks/ directory.
# ---------------------------------------------------------------------------
if ! declare -F _tensorfold_task_dir > /dev/null 2>&1; then
  _tensorfold_task_dir() {
    if [[ -n "${SCRIPT_DIR:-}" ]]; then
      printf '%s\n' "$SCRIPT_DIR"
      return 0
    fi
    (cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../tasks" >/dev/null 2>&1 && pwd)
  }
fi

# ---------------------------------------------------------------------------
# path_has_hf_snapshot <cache_dir>
#   True when a Hugging Face cache directory (…/hub/models--<org>--<repo>)
#   already holds a usable snapshot: any snapshots/<revision>/ that contains
#   config.json plus at least one weight file (a safetensors shard or its
#   index, or a legacy .bin).
#
#   The revision hash is deliberately NOT part of the probe: the download (or
#   the recipe's own prepare.sh) resolves it, so a cache populated under a
#   different revision is still a finished download. This mirrors upstream's
#   own probe (scripts/config.sh: have_model -> "any snapshots/<rev>/ exists")
#   but additionally requires weights, so a half-downloaded snapshot counts as
#   missing. Weight files are symlinks into blobs/, and -e follows them, so a
#   snapshot whose blobs never landed is not counted as present either.
#
#   Cheap file-existence test only — no checksums, no network. Whoever runs the
#   download still verifies the checkpoint itself.
#
#   Lives here (not in lib/helpers.sh) because the only consumers are the
#   TensorFold tasks; a general library must not carry a probe that only makes
#   sense for a recipe's HF cache layout.
# ---------------------------------------------------------------------------
if ! declare -F path_has_hf_snapshot > /dev/null 2>&1; then
  path_has_hf_snapshot() {
    local dir="${1:-}" snap weights
    [[ -d "$dir" ]] || return 1
    for snap in "$dir"/snapshots/*/; do
      [[ -f "${snap}config.json" ]] || continue
      for weights in "${snap}"*.safetensors* "${snap}"*.bin; do
        [[ -e "$weights" ]] && return 0
      done
    done
    return 1
  }
fi

# ---------------------------------------------------------------------------
# require_free_space <need_gb> <path> <what_needs_it>
#   Hard-fail (via error()) when <path> lives on a filesystem with less than
#   <need_gb> GB free; otherwise log the measurement.
#
#   CALLERS: only call this when something actually still has to be downloaded.
#   A task script that must fetch nothing must not gate on free disk — it has to
#   converge (conventions.md -> Re-run policy: converge by default).
#
#   Lives here for the same reason as path_has_hf_snapshot (tensorfold-only
#   download gate).
# ---------------------------------------------------------------------------
if ! declare -F require_free_space > /dev/null 2>&1; then
  require_free_space() {
    local need="$1" path="$2" what="${3:-the download}" free
    mkdir -p "$path" 2>/dev/null || true   # df needs the dir to exist on a fresh machine
    free="$(df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -dc '0-9')"
    if [[ -z "$free" ]]; then
      error "Could not determine free disk space under ${path} (df failed)."
    fi
    if (( free < need )); then
      error "Only ${free} GB free under ${path}; ~${need} GB needed for ${what}. Free up space (docker image prune -a; hf cache ls + hf cache rm <repo-id> for models you no longer serve) or download onto another filesystem (HF_CACHE_DIR=<path>). Free space and re-run — everything already on disk is reused."
    fi
    info "Disk: ${free} GB free under ${path} (~${need} GB needed for ${what})"
  }
fi

# ---------------------------------------------------------------------------
# Pre-flight: the environment both recipes demand (docker + tooling +
# llama-swap as runtime owner + one DGX Spark with a CDI GPU).
#
#   Each check keeps the message and exit code of the block it replaced.
#   tensorfold_preflight_sanity runs them in the order the scripts used to.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_require_docker > /dev/null 2>&1; then
  tensorfold_require_docker() {
    if ! command -v docker &>/dev/null; then
      error "Docker is not installed. Run setup-docker.sh first."
    fi
    if ! docker info &>/dev/null; then
      error "Docker daemon is not running. Start it with: sudo systemctl start docker"
    fi
    success "Docker $(docker --version | awk '{print $3}' | tr -d ',') detected and running."
  }
fi

if ! declare -F tensorfold_require_tooling > /dev/null 2>&1; then
  tensorfold_require_tooling() {
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
  }
fi

if ! declare -F tensorfold_require_llama_swap > /dev/null 2>&1; then
  # llama-swap is the runtime owner of the model — hard requirement.
  tensorfold_require_llama_swap() {
    local dir="${1:-/srv/llama-swap}"
    if [[ ! -d "$dir" ]] || ! systemctl cat llama-swap &>/dev/null; then
      error "llama-swap is not installed. Run tasks/setup-llama-swap.sh first."
    fi
    success "llama-swap installed (${dir})."
  }
fi

if ! declare -F tensorfold_is_dgx_spark > /dev/null 2>&1; then
  # DGX Spark (GB10) detection: compute capability 12.1 (sm_121). nvidia-smi
  # reports N/A for memory fields on Spark (UMA) — compute capability is the
  # reliable signal.
  tensorfold_is_dgx_spark() {
    nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | grep -qi "12\.1"
  }
fi

if ! declare -F tensorfold_require_dgx_spark > /dev/null 2>&1; then
  # <sizing_note>: the per-recipe sentence naming the memory footprint, printed
  # when the GPU is not a Spark. These recipes are Spark-sized, so a Spark is
  # hard-required.
  tensorfold_require_dgx_spark() {
    local sizing="${1:-This recipe is sized for one DGX Spark (GB10, 128 GB unified memory).}"
    if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null; then
      error "No working NVIDIA GPU (nvidia-smi missing or failing). This recipe requires a DGX Spark (GB10)."
    fi
    if ! tensorfold_is_dgx_spark; then
      local gpu_name
      gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
      error "Not a DGX Spark (found: ${gpu_name:-unknown GPU})."
      error "${sizing}"
    fi
    success "DGX Spark (GB10, sm_121) detected."
  }
fi

if ! declare -F tensorfold_require_cdi_gpu > /dev/null 2>&1; then
  # The container requests the GPU via the CDI device nvidia.com/gpu=all
  # (the 27B recipe runs it with --gpus all; same toolkit + CDI prerequisite).
  tensorfold_require_cdi_gpu() {
    if ! command -v nvidia-ctk &>/dev/null; then
      error "nvidia-ctk is not installed. Run setup-nvidia-container.sh first."
    fi
    if ! nvidia-ctk cdi list 2>/dev/null | grep -q "nvidia.com/gpu=all"; then
      error "No CDI spec for nvidia.com/gpu=all. Run setup-nvidia-container.sh — it generates
  the spec and installs an apt hook that regenerates it after every driver upgrade.
  Manual equivalent: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
    fi
    success "CDI device nvidia.com/gpu=all is available."
  }
fi

if ! declare -F tensorfold_preflight_sanity > /dev/null 2>&1; then
  # tensorfold_preflight_sanity <llama_swap_dir> <spark_sizing_note>
  #   The whole "Pre-flight checks" step except the download/disk part, which
  #   is tensorfold_resolve_pending_downloads' job.
  tensorfold_preflight_sanity() {
    local llama_swap_dir="${1:-/srv/llama-swap}" sizing="${2:-}"
    if [[ "$(id -u)" -eq 0 ]]; then
      warn "Running as root – not recommended."
    fi
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
      warn "This script targets Ubuntu. Continuing anyway…"
    fi
    tensorfold_require_docker
    tensorfold_require_tooling
    tensorfold_require_llama_swap "$llama_swap_dir"
    tensorfold_require_dgx_spark "$sizing"
    tensorfold_require_cdi_gpu
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_resolve_pending_downloads — *what still has to be downloaded?*
#
#   Presence first, disk second, and disk only for the pieces that are missing:
#   a re-run on a nearly full machine where the checkpoints and the engine image
#   are already on disk must converge and download nothing (conventions.md →
#   Re-run policy: converge by default). A cold install still pays the full
#   <model-gb>+<image-gb> requirement, and upstream's scripts/prepare.sh
#   re-checks its exact numbers on its own.
#
#   OPTIONS:
#     --model-label <word>  singular/plural wording ("Checkpoint")
#     --model-gb <n>        GB of checkpoint data that is still missing
#     --image-gb <n>        GB the engine image needs
#     --cache-dir <path>    HF cache dir; repeat for several checkpoints —
#                           every one of them must hold a usable snapshot
#     --image <ref>         engine image; repeat — any one present counts as
#                           "no image download needed"
#     --hf-cache <path>     path the free-disk gate measures (only used when
#                           something is actually missing)
#     --quiet               resolve only, print nothing (--check path)
#
#   GLOBALS SET (after the call, read-only):
#     TENSORFOLD_NEEDS_MODEL / TENSORFOLD_NEEDS_IMAGE  0 = present, 1 = missing
#     TENSORFOLD_PENDING_GB    sum of the GB that is still missing
#     TENSORFOLD_PENDING       human-readable "checkpoint ~N GB and image ~M GB",
#                              empty when nothing is missing
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_resolve_pending_downloads > /dev/null 2>&1; then
  tensorfold_resolve_pending_downloads() {
    local model_label="Checkpoint" model_gb=0 image_gb=0 hf_cache="${HOME:-/root}/.cache/huggingface" quiet=0
    local -a cache_dirs=() images=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --model-label) shift; model_label="${1:-}" ;;
        --model-gb)    shift; model_gb="${1:-0}" ;;
        --image-gb)    shift; image_gb="${1:-0}" ;;
        --cache-dir)   shift; cache_dirs+=("$1") ;;
        --image)       shift; images+=("$1") ;;
        --hf-cache)    shift; hf_cache="${1:-}" ;;
        --quiet)       quiet=1 ;;
        *) err_msg "tensorfold_resolve_pending_downloads: unknown option: $1"; return 1 ;;
      esac
      shift
    done
    (( ${#cache_dirs[@]} )) || { err_msg "tensorfold_resolve_pending_downloads: no --cache-dir given"; return 1; }
    (( ${#images[@]} ))     || { err_msg "tensorfold_resolve_pending_downloads: no --image given"; return 1; }

    # (a) Checkpoints — any usable cached snapshot counts, not one pinned revision.
    local _dir all_present=1
    for _dir in "${cache_dirs[@]}"; do
      path_has_hf_snapshot "$_dir" || all_present=0
    done
    if [[ "$all_present" -eq 1 ]]; then
      TENSORFOLD_NEEDS_MODEL=0
    else
      TENSORFOLD_NEEDS_MODEL=1
    fi

    # (b) Engine image — pulled and tagged, or built, by the recipe.
    local img _image_present=0
    for img in "${images[@]}"; do
      if docker image inspect "$img" &>/dev/null; then
        _image_present=1
        break
      fi
    done
    if [[ "$_image_present" -eq 1 ]]; then
      TENSORFOLD_NEEDS_IMAGE=0
    else
      TENSORFOLD_NEEDS_IMAGE=1
    fi

    # (c) What a re-run would still have to download, and the space it needs.
    TENSORFOLD_PENDING=""
    TENSORFOLD_PENDING_GB=0
    if [[ "$TENSORFOLD_NEEDS_MODEL" -eq 1 ]]; then
      TENSORFOLD_PENDING="${model_label,,} ~${model_gb} GB"
      TENSORFOLD_PENDING_GB=$(( TENSORFOLD_PENDING_GB + model_gb ))
    fi
    if [[ "$TENSORFOLD_NEEDS_IMAGE" -eq 1 ]]; then
      if [[ -n "$TENSORFOLD_PENDING" ]]; then
        TENSORFOLD_PENDING="${TENSORFOLD_PENDING} and "
      fi
      TENSORFOLD_PENDING="${TENSORFOLD_PENDING}image ~${image_gb} GB"
      TENSORFOLD_PENDING_GB=$(( TENSORFOLD_PENDING_GB + image_gb ))
    fi

    [[ "$quiet" -eq 1 ]] && return 0

    # Presence report — one line for the checkpoints, one for the engine image.
    local joined="" first=1
    for _dir in "${cache_dirs[@]}"; do
      if [[ "$first" -eq 1 ]]; then
        joined="$_dir"
        first=0
      else
        joined="${joined} and ${_dir}"
      fi
    done
    if [[ "$TENSORFOLD_NEEDS_MODEL" -eq 0 ]]; then
      success "${model_label} already present under ${joined}"
    fi
    if [[ "$TENSORFOLD_NEEDS_IMAGE" -eq 0 ]]; then
      success "Engine image already present (${images[0]})"
    fi

    # Free disk, only for the pieces that are still missing.
    if [[ "$TENSORFOLD_NEEDS_MODEL" -eq 1 || "$TENSORFOLD_NEEDS_IMAGE" -eq 1 ]]; then
      local needed_gb=0 missing=""
      if [[ "$TENSORFOLD_NEEDS_MODEL" -eq 1 ]]; then
        needed_gb=$(( needed_gb + model_gb ))
        missing="the ~${model_gb} GB ${model_label,,}"
      fi
      if [[ "$TENSORFOLD_NEEDS_IMAGE" -eq 1 ]]; then
        needed_gb=$(( needed_gb + image_gb ))
        if [[ -n "$missing" ]]; then
          missing="${missing} and "
        fi
        missing="${missing}the ~${image_gb} GB engine image"
      fi
      require_free_space "$needed_gb" "$hf_cache" "$missing"
    else
      info "${model_label} and engine image already on disk — nothing to download, free-disk check skipped."
    fi

    return 0
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_stop_running_model <project_dir> <force>
#   --force: stop the model through upstream stop.sh before converging, so the
#   container does not hold the GPU while the checkout/env is rewritten.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_stop_running_model > /dev/null 2>&1; then
  tensorfold_stop_running_model() {
    local dir="$1" force="${2:-0}"
    if [[ "$force" -eq 1 && -x "${dir}/stop.sh" ]]; then
      info "--force: stopping the running model (upstream stop.sh)…"
      (cd "$dir" && bash stop.sh) || true
    fi
    return 0
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_checkout_pinned_recipe <project_dir> <repo_url> <commit>
#   Clone the recipe (converge: fetch + checkout the pinned commit). Everything
#   pinned is the rule; the recipe pins the TensorFold engine inside it.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_checkout_pinned_recipe > /dev/null 2>&1; then
  tensorfold_checkout_pinned_recipe() {
    local dir="$1" repo="$2" ref="${3:?tensorfold_checkout_pinned_recipe: no recipe ref}"
    step "Upstream recipe: ${dir}"
    if [[ -d "${dir}/.git" ]]; then
      info "Converging existing checkout (fetch + checkout ${ref:0:7})…"
      git -C "$dir" fetch --quiet origin
      git -C "$dir" checkout --quiet "$ref"
    else
      if [[ -e "$dir" ]]; then
        error "${dir} exists but is not a git checkout — move it aside and re-run."
      fi
      # Create the service dir with user ownership; never chown /srv itself.
      sudo mkdir -p "$(dirname "$dir")"
      sudo install -d -m 755 -o "$(id -un)" -g "$(id -gn)" "$dir"
      git clone --quiet "$repo" "$dir"
      git -C "$dir" checkout --quiet "$ref"
    fi
    success "Recipe at $(git -C "$dir" rev-parse --short HEAD)"
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_render_serve_env <template_file> <target_file> <port>
#   Render the upstream settings file (${PROJECT_DIR}/.env) from the component
#   template. Only the port is a layout value here — the serve levers stay
#   ${VAR}-free in the template and are operator settings in the file itself.
#   (Re-rendering the whole file is how it works today: operator-added levers
#   are NOT read back. See the review notes if that ever has to change.)
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_render_serve_env > /dev/null 2>&1; then
  tensorfold_render_serve_env() {
    local template_file="$1" target_file="$2" port="${3:?}"
    step "Writing ${target_file}"
    local tmp
    tmp="$(mktempfile serve.env)"
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    (
      export PORT="$port"
      envsubst '${PORT}' < "$template_file"
    ) > "$tmp"
    install -m 644 -o "$(id -un)" -g "$(id -gn)" "$tmp" "$target_file"
    success ".env written: FOREGROUND=1, PORT=${port}"
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_merge_model_entry <template_file> <catalog> <default_catalog> \
#                             <model_name> <force> <envsubst_varlist>
#   Render the llama-swap catalog entry from the component template and merge
#   it into models.yml additively (merge-model-entry.py: replaced only when the
#   rendered entry changed, --force to re-write it).
#
#   The variables of <envsubst_varlist> ('${A} ${B} …', a literal string) must
#   already be exported by the calling script — the helper never guesses which
#   per-task settings a template wants.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_merge_model_entry > /dev/null 2>&1; then
  tensorfold_merge_model_entry() {
    local template_file="$1" catalog="$2" default_catalog="$3" name="$4" force="${5:-0}" varlist="$6"
    local tasks_dir entry
    tasks_dir="$(_tensorfold_task_dir)"
    entry="$(mktempfile models-entry.yml)"
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    envsubst "$varlist" < "$template_file" > "$entry"
    local -a merge_args=(
      --catalog "$catalog"
      --default "$default_catalog"
      --entry "$entry"
      --name "$name"
      --provider local
    )
    if [[ "$force" -eq 1 ]]; then
      merge_args+=(--force)
    fi
    python3 "${tasks_dir}/merge-model-entry.py" "${merge_args[@]}"
    rm -f -- "$entry"
    success "Catalog merged."
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_llama_swap_raise_health_timeout <config_file> <seconds>
#   llama-swap's healthCheckTimeout is GLOBAL (top-level config key) — a
#   per-model value is accepted but ignored. Raise it to cover this model's
#   first load; the sync below restarts llama-swap when the file changed.
#   No-op when the config file does not exist (llama-swap not configured yet).
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_llama_swap_raise_health_timeout > /dev/null 2>&1; then
  tensorfold_llama_swap_raise_health_timeout() {
    local config_file="$1" need="${2:?tensorfold_llama_swap_raise_health_timeout: no seconds}"
    step "Ensuring llama-swap healthCheckTimeout >= ${need}s"
    if [[ -f "$config_file" ]]; then
      python3 - "$config_file" "$need" <<'PYEOF'
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
    return 0
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_sync_llama_swap
#   Merge models.yml into llama-swap's config.yaml (tasks/sync-models.py
#   restarts the service only when its config changed and polls /health).
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_sync_llama_swap > /dev/null 2>&1; then
  tensorfold_sync_llama_swap() {
    step "Syncing llama-swap (tasks/sync-models.py)"
    python3 "$(_tensorfold_task_dir)/sync-models.py"
    success "llama-swap in sync."
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_smoke_test <model_name> <llama_swap_port> <timeout_s> \
#                       <container_name> <load_hint>
#   End-to-end health gate: one chat completion through llama-swap (which
#   swaps the model in itself), asserting a non-empty answer. <load_hint> is the
#   one-line "what happens on first load" text the task prints for this model.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_smoke_test > /dev/null 2>&1; then
  tensorfold_smoke_test() {
    local model="$1" port="$2" timeout="$3" container="$4" hint="${5:-}"
    step "Smoke test through llama-swap (http://localhost:${port})"
    if [[ -n "$hint" ]]; then
      info "${hint}"
    fi

    # enable_thinking: false (a documented per-request parameter of these
    # engines) — with the default thinking mode the think block would eat the
    # small token budget and leave message.content empty, failing the check.
    local smoke_body smoke_resp
    smoke_body="{\"model\": \"${model}\", \"max_tokens\": 32, \"temperature\": 0, \"chat_template_kwargs\": {\"enable_thinking\": false}, \"messages\": [{\"role\": \"user\", \"content\": \"Reply with OK.\"}]}"
    if smoke_resp="$(curl -s --max-time $(( timeout + 60 )) \
         "http://localhost:${port}/v1/chat/completions" \
         -H 'Content-Type: application/json' -d "${smoke_body}")" \
       && python3 -c 'import json,sys; r=json.loads(sys.argv[1]); c=r["choices"][0]["message"].get("content") or ""; sys.exit(0 if c.strip() else 1)' "${smoke_resp}" 2>/dev/null; then
      success "Smoke test passed — the model answers through llama-swap."
    else
      error "Smoke test failed — the model is not answering through llama-swap."
      error "Check: curl http://localhost:${port}/running | jq .  and  docker logs -f ${container}"
      error "Retry:   curl -s http://localhost:${port}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK.\"}],\"max_tokens\":32}'"
      error "Re-run $0 (or use --skip-smoke if you will fix this manually)."
    fi
    return 0
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_status_<signal> — the shared lines of --check
#
#   Read-only signals both scripts report identically. The task prints the ones
#   that genuinely differ (the status title and the checkpoint line(s)); the
#   pending/need globals come from tensorfold_resolve_pending_downloads --quiet.
# ---------------------------------------------------------------------------

# tensorfold_status_recipe <project_dir> <recipe_ref>
if ! declare -F tensorfold_status_recipe > /dev/null 2>&1; then
  tensorfold_status_recipe() {
    local dir="$1" ref="$2" head
    if [[ -d "${dir}/.git" ]]; then
      head="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
      if [[ "$head" == "${ref:0:7}" ]]; then
        echo -e "  ${BOLD}Recipe:${RESET}      ${GREEN}pinned${RESET} (${head})"
      else
        echo -e "  ${BOLD}Recipe:${RESET}      ${YELLOW}${head}${RESET} (expected ${ref:0:7} — re-run without --check to converge)"
      fi
    else
      echo -e "  ${BOLD}Recipe:${RESET}      ${YELLOW}not installed${RESET} (${dir})"
    fi
    return 0
  }
fi

# tensorfold_status_prepared <marker_file> <ok_text>
#   Marker written by upstream prepare.sh; its location is recipe-specific
#   (state dir vs kernel cache), so the caller passes the path.
if ! declare -F tensorfold_status_prepared > /dev/null 2>&1; then
  tensorfold_status_prepared() {
    local marker="$1" ok_text="$2"
    if [[ -f "$marker" ]]; then
      echo -e "  ${BOLD}Prepared:${RESET}    ${GREEN}${ok_text}${RESET}"
    else
      echo -e "  ${BOLD}Prepared:${RESET}    ${YELLOW}no — prepare.sh has not completed${RESET}"
    fi
    return 0
  }
fi

# tensorfold_status_image <image_ref>...
#   Any one of the references present counts as the engine image (the 27B
#   recipe tags a pulled ghcr.io reference as its local one); the first
#   reference is the name shown.
if ! declare -F tensorfold_status_image > /dev/null 2>&1; then
  tensorfold_status_image() {
    local img present=0
    for img in "$@"; do
      if docker image inspect "$img" &>/dev/null; then
        present=1
        break
      fi
    done
    if [[ "$present" -eq 1 ]]; then
      echo -e "  ${BOLD}Image:${RESET}        ${GREEN}${1}${RESET}"
    else
      echo -e "  ${BOLD}Image:${RESET}        ${YELLOW}missing${RESET} (${1})"
    fi
    return 0
  }
fi

# tensorfold_status_disk <hf_cache_dir>
#   Uses TENSORFOLD_PENDING / TENSORFOLD_PENDING_GB from the resolver.
if ! declare -F tensorfold_status_disk > /dev/null 2>&1; then
  tensorfold_status_disk() {
    local dir="$1" free
    free="$(df -BG --output=avail "$dir" 2>/dev/null | tail -1 | tr -dc '0-9')"
    echo -e "  ${BOLD}Disk:${RESET}        ${free:-?} GB free under ${dir} (still to download: ${TENSORFOLD_PENDING:-nothing})"
    if (( ${TENSORFOLD_PENDING_GB:-0} > 0 )) && [[ -n "$free" ]] && (( free < TENSORFOLD_PENDING_GB )); then
      echo -e "                 ${YELLOW}below the ~${TENSORFOLD_PENDING_GB} GB that download would need${RESET}"
    fi
    return 0
  }
fi

# tensorfold_status_catalog <catalog_file> <model_name>
#   -A1: require 'type: local' right after — a same-named remote entry must not
#   count as the local tensorfold entry.
if ! declare -F tensorfold_status_catalog > /dev/null 2>&1; then
  tensorfold_status_catalog() {
    local catalog="$1" name="$2"
    if [[ -f "$catalog" ]] && grep -A1 -q "name: ${name}" "$catalog" \
       && grep -A1 "name: ${name}" "$catalog" | grep -q "type: local"; then
      echo -e "  ${BOLD}Catalog:${RESET}     ${GREEN}entry in ${catalog}${RESET}"
    else
      echo -e "  ${BOLD}Catalog:${RESET}     ${YELLOW}no ${name} entry in ${catalog}${RESET}"
    fi
    return 0
  }
fi

# tensorfold_status_llama_swap_entry <config_file> <model_name>
if ! declare -F tensorfold_status_llama_swap_entry > /dev/null 2>&1; then
  tensorfold_status_llama_swap_entry() {
    local config="$1" name="$2"
    if [[ -f "$config" ]] && grep -qE "^[[:space:]]+${name//./\\.}:" "$config"; then
      echo -e "  ${BOLD}llama-swap:${RESET}  ${GREEN}entry in config.yaml${RESET}"
    else
      echo -e "  ${BOLD}llama-swap:${RESET}  ${YELLOW}no entry in config.yaml${RESET}"
    fi
    return 0
  }
fi

# tensorfold_status_container <container_name>
if ! declare -F tensorfold_status_container > /dev/null 2>&1; then
  tensorfold_status_container() {
    local container="$1" state
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
      state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo '?')"
      echo -e "  ${BOLD}Container:${RESET}   ${container} (${state})"
    else
      echo -e "  ${BOLD}Container:${RESET}   ${YELLOW}not running${RESET} (llama-swap starts it on demand)"
    fi
    return 0
  }
fi

# tensorfold_status_proxy <llama_swap_port>
if ! declare -F tensorfold_status_proxy > /dev/null 2>&1; then
  tensorfold_status_proxy() {
    local port="$1"
    if curl -sf --max-time 3 "http://localhost:${port}/health" &>/dev/null; then
      echo -e "  ${BOLD}Proxy:${RESET}       ${GREEN}llama-swap healthy on port ${port}${RESET}"
    else
      echo -e "  ${BOLD}Proxy:${RESET}       ${YELLOW}llama-swap not answering on port ${port}${RESET}"
    fi
    return 0
  }
fi
