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
# validate_port <name> <value>  +  tensorfold_validate_serving_settings
#   Port/timeout validation. Both scripts call it AFTER argument parsing
#   (review F4: validating the defaults at load time never looked at a value
#   handed in with --port / --health-timeout, so `--port abc` only failed much
#   later as a confusing curl/sync error).
#
#   validate_port keeps the signature every other task script uses; a script
#   that defines its own copy after sourcing keeps that copy.
# ---------------------------------------------------------------------------
if ! declare -F validate_port > /dev/null 2>&1; then
  validate_port() {
    local name="$1" port="$2"
    if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
      error "${name} must be a number between 1 and 65535 (got: ${port})."
    fi
  }
fi

if ! declare -F tensorfold_validate_serving_settings > /dev/null 2>&1; then
  # tensorfold_validate_serving_settings <port-name> <port> <proxy-name> <proxy-port> \
  #                                      <timeout-name> <timeout>
  #   Called with the FINAL values, i.e. after the while-parse loop.
  tensorfold_validate_serving_settings() {
    local p_name="$1" port="$2" proxy_name="$3" proxy_port="$4" t_name="$5" timeout="$6"
    validate_port "$p_name" "$port"
    validate_port "$proxy_name" "$proxy_port"
    if [[ ! "$timeout" =~ ^[1-9][0-9]*$ ]]; then
      error "${t_name} must be a positive integer number of seconds (got: ${timeout})."
    fi
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
#   Clone or converge the recipe checkout at the pinned commit. Everything
#   pinned is the rule; the recipe pins the TensorFold engine inside it.
#
#   Converge means a re-run always ends at <commit> (review 27B F7): fetch the
#   ref even when the default branch moved, and force the checkout when the
#   tree is dirty (the recipe is "yours" — patches/ and .env live here, so an
#   operator edit must not wedge the re-run; the dirty state is reported
#   first). `origin` is re-pointed so a changed remote cannot silently re-pin
#   a different repository.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_checkout_pinned_recipe > /dev/null 2>&1; then
  tensorfold_checkout_pinned_recipe() {
    local dir="$1" repo="$2" ref="${3:?tensorfold_checkout_pinned_recipe: no recipe ref}"
    step "Upstream recipe: ${dir}"
    if [[ -d "${dir}/.git" ]]; then
      info "Converging existing checkout (fetch + checkout ${ref:0:7})…"
      git -C "$dir" remote set-url origin "$repo"
      if ! git -C "$dir" cat-file -e "${ref}^{commit}" 2>/dev/null; then
        git -C "$dir" fetch --quiet --tags origin "$ref" \
          || git -C "$dir" fetch --quiet --tags --prune origin \
          || error "could not fetch recipe commit ${ref} from ${repo} (offline?) — fetch it once, then re-run."
      fi
      local -a dirty=()
      mapfile -t dirty < <(git -C "$dir" status --porcelain 2>/dev/null || true)
      if (( ${#dirty[@]} > 0 )); then
        warn "${dir} has local changes — checkout --force discards tracked ones (the recipe pins them):"
        printf '       %s\n' "${dirty[@]}" >&2
      fi
      git -C "$dir" checkout --quiet --force "$ref" \
        || error "${dir} does not converge to ${ref:0:7}. Converge it by hand:
         git -C ${dir} status --short
         git -C ${dir} checkout --force ${ref}"
    else
      if [[ -e "$dir" ]]; then
        error "${dir} exists but is not a git checkout — move it aside and re-run."
      fi
      # Create the service dir with user ownership; never chown /srv itself.
      sudo mkdir -p "$(dirname "$dir")"
      sudo install -d -m 755 -o "$(id -un)" -g "$(id -gn)" "$dir"
      git clone --quiet "$repo" "$dir"
      git -C "$dir" checkout --quiet --force "$ref"
    fi
    success "Recipe at $(git -C "$dir" rev-parse --short HEAD)"
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_render_serve_env <template_file> <target_file> <port>
#   Render the upstream settings file (${PROJECT_DIR}/.env) from the component
#   template. Only the port is a layout value here — the serve levers
#   (CONTEXT, PARALLEL, KV_POOL_GB, YARN_FACTOR, KV_DTYPE, VISION,
#   TENSORFOLD_MEMORY_RESERVE_GIB, …) are operator settings, and both scripts'
#   --help blocks advertise this file as the place to put them.
#
#   Converge-by-default (review F1/F2): a re-run must not destroy them. The
#   keys the template owns (FOREGROUND, PORT, HOST) are re-rendered, every
#   other KEY= line of the existing file is carried over unchanged. Install
#   goes through env_file_write so the file ends up mode 600 — it is the
#   documented home of a future HF_TOKEN.
#
#   Only KEY= lines are carried over, never free-standing comments/blank lines:
#   the template's own header would otherwise be re-appended on every re-run.
#   Tell the operator where settings live (the header), not in side comments.
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

    local kept=0 line key
    if [[ -f "$target_file" ]]; then
      while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        key="${BASH_REMATCH[2]}"
        # Keys the rendered template owns stay whatever the template says;
        # everything the operator added is appended verbatim.
        grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=" "$tmp" && continue
        printf '%s\n' "$line" >> "$tmp"
        kept=$(( kept + 1 ))
      done < "$target_file"
    fi

    env_file_write "$target_file" < "$tmp"
    if (( kept > 0 )); then
      success ".env written (mode 600): FOREGROUND=1, PORT=${port} — preserved ${kept} operator setting(s) from ${target_file}."
    else
      success ".env written (mode 600): FOREGROUND=1, PORT=${port}"
    fi
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
# tensorfold_require_llama_swap_config_writable <config_file>
#   Read-only, non-mutating pre-flight probe: will the sync that runs AFTER the
#   download be able to write llama-swap's config.yaml? A cold install hits the
#   default root:root 644 config.yaml that tasks/setup-llama-swap.sh creates, and
#   tensorfold_llama_swap_raise_health_timeout only notices that once
#   scripts/prepare.sh has already pulled ~122 GiB (flash) / ~19 GB (27B).
#   conventions.md → fail fast with actionable messages, so ask BEFORE downloading.
#
#   Contract — deliberately the same one sync_models/llama_swap.py's pre-flight
#   applies (os.access(path, W_OK) or os.access(path.parent, W_OK)) and that the
#   raise reuses, so the probe's verdict and the later action's verdict cannot
#   disagree. Directory write access alone counts because both writers REPLACE
#   the file (sync_models/atomicio.py: mkstemp in the parent dir + os.replace;
#   the raise: install), never writing into the existing inode.
#
#     - file missing         -> PASS silently. llama-swap may not be configured
#       yet; the raise handles that case with an info, and a first install must
#       not be blocked over a file that does not exist yet.
#     - parent dir missing   -> WARN, do not fail. There is nothing to write
#       into, and tensorfold_require_llama_swap (same pre-flight) already errors
#       when llama-swap is not installed at all.
#     - file present and either the file or its directory is W_OK -> PASS.
#     - file present and neither is W_OK -> FAIL with the raise's wording plus
#       the fact that nothing has been downloaded yet.
#
#   Writes nothing, creates nothing, needs no sudo: no test file, no chmod.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_require_llama_swap_config_writable > /dev/null 2>&1; then
  tensorfold_require_llama_swap_config_writable() {
    local config_file="${1:?tensorfold_require_llama_swap_config_writable: no config file}"
    local dir
    dir="$(dirname "$config_file")"
    if [[ ! -e "$config_file" ]]; then
      if [[ ! -d "$dir" ]]; then
        warn "No ${dir} yet — llama-swap is not configured, so there is no config to make writable."
      fi
      return 0
    fi
    if [[ -w "$config_file" || -w "$dir" ]]; then
      return 0
    fi
    error "llama-swap config not writable: ${config_file} — fix ownership/permissions or run as a user with write access, then re-run (the same gate tasks/sync-models.py applies, e.g.: sudo chown $(id -un):$(id -gn) ${config_file}). Nothing has been downloaded yet — this check runs before scripts/prepare.sh, and tensorfold_llama_swap_raise_health_timeout would have hit it only after the checkpoint download."
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_llama_swap_raise_health_timeout <config_file> <seconds>
#   llama-swap's healthCheckTimeout is GLOBAL (top-level config key) — a
#   per-model value is accepted but ignored (llama-swap internal/config
#   overwrites every per-model value with the global one). Raise it to cover
#   this model's first load. No-op when the config file does not exist
#   (llama-swap not configured yet).
#
#   Implementation notes (review flash F2 / 27B F3):
#   - targeted textual edit of the one key: the file is the llama-swap example
#     config with ~250 lines of comments that document every other option, and
#     a YAML round-trip would throw them away. The write goes to a mktemp and
#     is installed, so the file is never truncated in place.
#   - ownership: setup-llama-swap.sh creates config.yaml root:root 644 via
#     sudo tee, so an in-place write is not possible for a non-root user. The
#     plain install is tried first, then sudo install; the latter keeps the
#     file owned by the invoking user so the sync that follows (which rewrites
#     it as the invoking user) keeps working. If neither works, fail with the
#     same actionable wording tasks/sync-models.py's pre-flight uses — not a
#     PermissionError traceback after the big download.
#   - the stated default here is llama-swap's own (120 s); kwisatz's own
#     template renders 500 (templates/llama-swap/config.yaml).
#
#   GLOBAL SET: TENSORFOLD_HEALTH_TIMEOUT_BUMPED=1 when the file was changed,
#   so tensorfold_sync_llama_swap can still force the restart that loads it.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_llama_swap_raise_health_timeout > /dev/null 2>&1; then
  tensorfold_llama_swap_raise_health_timeout() {
    local config_file="$1" need="${2:?tensorfold_llama_swap_raise_health_timeout: no seconds}"
    TENSORFOLD_HEALTH_TIMEOUT_BUMPED=0
    step "Ensuring llama-swap healthCheckTimeout >= ${need}s"
    if [[ ! -f "$config_file" ]]; then
      info "No ${config_file} yet — nothing to raise (run tasks/setup-llama-swap.sh first)."
      return 0
    fi

    local cur
    # Column 0 is what makes it the GLOBAL key — an indented occurrence lives
    # inside another mapping and is not the same setting.
    cur="$(sed -n 's/^healthCheckTimeout:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$config_file" | tail -1)"
    # Missing key => llama-swap's own default (120 s), not 600.
    cur="${cur:-120}"
    if (( cur >= need )); then
      info "healthCheckTimeout already ${cur} >= ${need} (global key)."
      return 0
    fi

    # Same writability contract as sync_models/llama_swap.py's pre-flight. The
    # pre-flight probe (tensorfold_require_llama_swap_config_writable) already
    # covered the common case before the download — kept here as a defence, the
    # file could have been replaced in between.
    if [[ ! -w "$config_file" && ! -w "$(dirname "$config_file")" ]]; then
      error "llama-swap config not writable: ${config_file} — fix ownership/permissions or run as a user with write access, then re-run (the same gate tasks/sync-models.py applies, e.g.: sudo chown $(id -un):$(id -gn) ${config_file}). Nothing else in ${config_file} was touched."
    fi

    local tmp
    tmp="$(mktempfile config.yaml)"
    sed -E "s/^healthCheckTimeout:.*/healthCheckTimeout: ${need}/" "$config_file" > "$tmp" \
      || error "could not read ${config_file} — apply the change by hand: sudo sed -i 's/^healthCheckTimeout:.*/healthCheckTimeout: ${need}/' ${config_file}"
    if ! grep -q "^healthCheckTimeout:" "$tmp"; then
      # Hand-written config without the key: add it at the top level.
      printf '\nhealthCheckTimeout: %s\n' "$need" >> "$tmp"
    fi
    install -m 644 -o "$(id -un)" -g "$(id -gn)" "$tmp" "$config_file" 2>/dev/null \
      || sudo install -m 644 -o "$(id -un)" -g "$(id -gn)" "$tmp" "$config_file" \
      || error "cannot update ${config_file} — apply the change by hand and re-run: sudo sed -i 's/^healthCheckTimeout:.*/healthCheckTimeout: ${need}/' ${config_file}"

    TENSORFOLD_HEALTH_TIMEOUT_BUMPED=1
    info "healthCheckTimeout raised ${cur} -> ${need} (global key; comments in ${config_file} preserved)."
    return 0
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_sync_llama_swap <config_file> <llama_swap_port> <container>
#   Merge models.yml into llama-swap's config.yaml (tasks/sync-models.py
#   restarts the service only when its config changed and polls /health).
#
#   The restart-on-change rule is what makes the healthCheckTimeout raise
#   depend on it: sync-models.py compares the merged data against what is
#   already on disk, so when the raise edited config.yaml but there is nothing
#   new to merge it prints "config unchanged — no write, no restart" and the
#   raised value is never loaded (review flash F2). A hash before/after the
#   sync tells the two cases apart deterministically — no parsing of the
#   python output.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_sync_llama_swap > /dev/null 2>&1; then
  tensorfold_sync_llama_swap() {
    local config_file="$1" port="$2" container="${3:-}"
    step "Syncing llama-swap (tasks/sync-models.py)"
    local before="" after
    if [[ -f "$config_file" ]]; then
      before="$(sha256sum "$config_file" 2>/dev/null | cut -d' ' -f1)"
    fi
    python3 "$(_tensorfold_task_dir)/sync-models.py"

    if [[ "${TENSORFOLD_HEALTH_TIMEOUT_BUMPED:-0}" -eq 1 && -n "$before" && -f "$config_file" ]]; then
      after="$(sha256sum "$config_file" 2>/dev/null | cut -d' ' -f1)"
      if [[ "$before" == "$after" ]]; then
        info "The raise changed config.yaml but sync-models.py found nothing to write — restarting llama-swap so the new healthCheckTimeout is loaded."
        warn "llama-swap restarts now. If ${container:-the model container} was running, remove it before the next load: docker rm -f ${container:-<container>}"
        sudo systemctl restart llama-swap \
          || error "could not restart llama-swap — run: sudo systemctl restart llama-swap (and re-run this script)."
        local deadline=$(( $(date +%s) + 60 ))
        until curl -sf --max-time 5 "http://localhost:${port}/health" >/dev/null 2>&1; do
          (( $(date +%s) < deadline )) || error "llama-swap did not answer /health within 60 s after the restart — check: systemctl status llama-swap; journalctl -u llama-swap -n 50"
          sleep 2
        done
        success "llama-swap restarted and healthy (healthCheckTimeout reloaded)."
      fi
    fi
    success "llama-swap in sync."
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_smoke_test <model_name> <llama_swap_port> <timeout_s> \
#                       <container_name> <load_hint>
#   End-to-end health gate: the model must answer a chat completion through
#   llama-swap (which swaps the model in itself). <load_hint> is the one-line
#   "what happens on first load" text the task prints for this model.
#
#   Shape (review flash F8): the load is *triggered* in the background and then
#   polled, instead of one 900 s blocking request. A single long request ties
#   the smoke result to llama-swap's internal request handling during the swap
#   (a proxy timeout or a mid-load connection reset fails the test while the
#   load itself would have succeeded).
# ---------------------------------------------------------------------------

# _tensorfold_chat_completion <url> <json_body> <max_time_s>
#   One chat completion; prints the raw response body (empty when the request
#   did not get through). Never fails the caller — curl errors are expected
#   while a model is swapping in.
if ! declare -F _tensorfold_chat_completion > /dev/null 2>&1; then
  _tensorfold_chat_completion() {
    curl -s --max-time "$3" "$1" -H 'Content-Type: application/json' -d "$2" 2>/dev/null || true
  }
fi

# _tensorfold_answers <response-body>
#   True when the response carries a non-empty assistant message.
if ! declare -F _tensorfold_answers > /dev/null 2>&1; then
  _tensorfold_answers() {
    printf '%s' "$1" | python3 -c 'import json, sys
try:
    r = json.load(sys.stdin)
    c = r["choices"][0]["message"].get("content") or ""
except Exception:
    sys.exit(1)
sys.exit(0 if c.strip() else 1)' 2>/dev/null
  }
fi

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
    local url="http://localhost:${port}/v1/chat/completions"
    local body
    body="{\"model\": \"${model}\", \"max_tokens\": 32, \"temperature\": 0, \"chat_template_kwargs\": {\"enable_thinking\": false}, \"messages\": [{\"role\": \"user\", \"content\": \"Reply with OK.\"}]}"
    local deadline=$(( $(date +%s) + timeout ))

    # (1) Trigger the swap: llama-swap loads the model on the first request and
    # holds that request open until the upstream server answers, so the
    # trigger runs in the background while the poll below watches.
    local trigger trigger_pid loaded=0
    trigger="$(mktempfile smoke-trigger.json)"
    curl -s --max-time $(( timeout + 120 )) "$url" -H 'Content-Type: application/json' -d "$body" \
      > "$trigger" 2>/dev/null &
    trigger_pid=$!

    # (2) Bounded readiness poll — /running lists the models llama-swap has
    # actually loaded (the same endpoint setup-llama-swap.sh advertises).
    while (( $(date +%s) < deadline )); do
      if curl -sf --max-time 15 "http://localhost:${port}/running" 2>/dev/null | grep -qF "$model"; then
        loaded=1
        break
      fi
      if ! kill -0 "$trigger_pid" 2>/dev/null; then
        # The trigger returned already (answered, or failed fast) — its answer
        # is the best evidence available, stop waiting.
        loaded=1
        break
      fi
      sleep 10
    done

    # (3) Assert a non-empty answer. Any connection reset during the swap now
    # reads as "not yet", not as a failed model.
    local resp ok=0
    while :; do
      resp="$(_tensorfold_chat_completion "$url" "$body" 120)"
      if _tensorfold_answers "$resp"; then
        ok=1
        break
      fi
      (( $(date +%s) < deadline )) || break
      sleep 10
    done
    kill "$trigger_pid" 2>/dev/null || true
    wait "$trigger_pid" 2>/dev/null || true

    if [[ "$ok" -eq 1 ]]; then
      success "Smoke test passed — the model answers through llama-swap."
    else
      # error() exits: everything the operator has to know goes in this one
      # message (review flash F5).
      error "Smoke test failed — the model is not answering through llama-swap within ${timeout}s ($([ "$loaded" -eq 1 ] && echo "llama-swap reported the model loaded" || echo "the model never reached /running")).
  Check:   curl http://localhost:${port}/running | jq .   and   docker logs -f ${container}
  Retry:   curl -s http://localhost:${port}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK.\"}],\"max_tokens\":32}'
  Re-run:  $0 --force (or --skip-smoke if you will fix this manually)."
    fi
    return 0
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_require_llama_swap_up <model_name> <llama_swap_port> <timeout_s> <container>
#   The health gate for the --skip-smoke path (review flash F7 + conventions.md
#   "Stack health verification"): the script may not print a success banner
#   with nothing proven, so llama-swap is bounded-polled on /health and its
#   model list is checked. It does NOT exercise the model — that gap is stated
#   out loud by the caller.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_require_llama_swap_up > /dev/null 2>&1; then
  tensorfold_require_llama_swap_up() {
    local model="$1" port="$2" timeout="${3:-60}" container="${4:-}"
    step "Health check through llama-swap (http://localhost:${port})"
    local deadline=$(( $(date +%s) + timeout ))
    until curl -sf --max-time 10 "http://localhost:${port}/health" >/dev/null 2>&1; do
      (( $(date +%s) < deadline )) \
        || error "llama-swap is not answering on http://localhost:${port}/health within ${timeout}s.
  Check:  systemctl status llama-swap; journalctl -u llama-swap -n 50
  Re-run: $0 (the sync step restarts llama-swap only when its config changed)"
      sleep 2
    done

    # /v1/models is served from config.yaml, so the entry must be listed even
    # when the model is not loaded.
    local models
    models="$(curl -sf --max-time 10 "http://localhost:${port}/v1/models" 2>/dev/null || true)"
    if ! printf '%s' "$models" | grep -qF "\"${model}\""; then
      error "llama-swap answers /health but does not list ${model} in /v1/models.
  Check:  grep -A2 '${model}' ${REPO_ROOT:-.}/models.yml  and  tasks/sync-models.py
  Re-run: $0 --force"
    fi
    success "llama-swap is up and serves ${model} in /v1/models (model not loaded — smoke skipped)."
    return 0
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_kernel_cache_move_note <current_dir> <legacy_dir>
#   Info-note when the default kernel-cache location moved (review flash F9 /
#   27B F5: llama-swap runs start.sh as root with ProtectHome=read-only, so a
#   cache under $HOME cannot be written by the service — the 27B recipe was
#   first to move it under PROJECT_DIR, and the flash recipe follows).
#
#   Recompiling CUDA kernels and re-downloading engine bits is expensive, so
#   nothing here is moved or deleted: the note only fires when the legacy
#   location holds something and the new one does not, and it says how to keep
#   the compiled kernels (KERNEL_CACHE_DIR=<legacy>).
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_kernel_cache_move_note > /dev/null 2>&1; then
  tensorfold_kernel_cache_move_note() {
    local now="$1" legacy="$2"
    [[ -n "$legacy" && "$legacy" != "$now" ]] || return 0
    [[ -d "$legacy" ]] || return 0
    if [[ -d "$now" && -n "$(ls -A "$now" 2>/dev/null)" ]]; then
      return 0
    fi
    warn "Kernel cache default is ${now} (llama-swap mounts $HOME read-only). A populated cache still exists under ${legacy} — set KERNEL_CACHE_DIR=${legacy} to keep its compiled kernels, or expect one recompile of each kernel on the next load."
    return 0
  }
fi

# ---------------------------------------------------------------------------
# tensorfold_sibling_port_warning <port> <sibling_env_file...>
#   Advisory cross-check between the two TensorFold installs (review 27B F11):
#   8888 (Flash Next) and 8889 (27B) are only a convention, and the collision
#   surfaces at first load (both containers bind the host network). Reads the
#   sibling's own ${PROJECT_DIR}/.env PORT with env_file_get — never fatal,
#   because a deliberately re-set port is the operator's business.
# ---------------------------------------------------------------------------
if ! declare -F tensorfold_sibling_port_warning > /dev/null 2>&1; then
  tensorfold_sibling_port_warning() {
    local port="$1"; shift
    local env_file peer
    for env_file in "$@"; do
      [[ -f "$env_file" ]] || continue
      peer="$(env_file_get "$env_file" PORT)"
      if [[ "$peer" == "$port" ]]; then
        warn "${env_file} also sets TensorFold port ${port} — the two containers collide on the host network at first load. Give one side another port (TENSORFOLD_PORT / TENSORFOLD_27B_PORT), then re-run both."
      fi
    done
    return 0
  }
fi

# ---------------------------------------------------------------------------
# Checkpoint revision bookkeeping (for recipes that pin no revision)
#
#   Upstream's 27B recipe exposes MODEL_ID/DRAFT_ID but no MODEL_REVISION (the
#   Flash Next recipe pins one), so its prepare.sh always resolves the newest
#   revision and the recipe-commit pin does not actually pin the weights.
#   These helpers record the revision an entry was installed against and
#   compare on every re-run — best-effort and never fatal: a cached checkpoint
#   that is still usable has to converge, and refusing to run would be worse
#   than a loud warning. See AUTOMATIONS.md for the residual risk and the
#   upstream ask (mirror the flash recipe's MODEL_REVISION/DRAFT_REVISION).
#
#   State file: KEY=value under PROJECT_DIR, read with env_file_get, so
#   install runs and --check share one source of truth.
# ---------------------------------------------------------------------------

# tensorfold_hf_cache_revision <cache_dir>
#   Resolved revision of a local HF cache entry: the newest snapshots/<sha>/ by
#   modification time — that is the one `hf download` without --revision just
#   wrote. Sets TENSORFOLD_HF_CACHE_REVISION / _COUNT; returns 1 when nothing
#   usable is cached. Deterministic when several snapshots exist (newest wins,
#   count reported so callers can flag the ambiguity).
if ! declare -F tensorfold_hf_cache_revision > /dev/null 2>&1; then
  tensorfold_hf_cache_revision() {
    local dir="$1" newest line name
    TENSORFOLD_HF_CACHE_REVISION=""
    TENSORFOLD_HF_CACHE_COUNT=0
    [[ -d "${dir}/snapshots" ]] || return 1
    local -a snaps=() usable=()
    mapfile -t snaps < <(find "${dir}/snapshots" -mindepth 1 -maxdepth 1 -type d \
      -printf '%T@\t%f\n' 2>/dev/null | sort -k1,1nr -k2,2)
    (( ${#snaps[@]} > 0 )) || return 1

    # Prefer snapshots that actually hold a checkpoint (config.json), so a
    # half-fetched directory can never win the newest-first tie.
    for line in "${snaps[@]}"; do
      name="$(printf '%s\n' "$line" | cut -f2)"
      if [[ -f "${dir}/snapshots/${name}/config.json" ]]; then
        usable+=("$line")
      fi
    done
    if (( ${#usable[@]} > 0 )); then
      snaps=("${usable[@]}")
    fi

    newest="$(printf '%s\n' "${snaps[0]}" | cut -f2)"
    [[ -n "$newest" ]] || return 1
    TENSORFOLD_HF_CACHE_REVISION="$newest"
    TENSORFOLD_HF_CACHE_COUNT="${#snaps[@]}"
    return 0
  }
fi

# tensorfold_hf_upstream_revision <repo_id>
#   Best-effort: the revision "main" resolves to right now (Hub API, gated by
#   nothing here). Sets TENSORFOLD_HF_UPSTREAM_REVISION and returns 1 when the
#   answer is unavailable (offline, gated repo, mirror) — callers must treat an
#   empty value as UNKNOWN, never as agreement.
if ! declare -F tensorfold_hf_upstream_revision > /dev/null 2>&1; then
  tensorfold_hf_upstream_revision() {
    local id="$1" body="" rev=""
    TENSORFOLD_HF_UPSTREAM_REVISION=""
    if command -v curl &>/dev/null; then
      body="$(curl -sfL --max-time 10 "${HF_ENDPOINT:-https://huggingface.co}/api/models/${id}" 2>/dev/null || true)"
    fi
    if [[ -n "$body" ]]; then
      rev="$(printf '%s' "$body" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("sha", ""))
except Exception:
    pass' 2>/dev/null || true)"
    fi
    TENSORFOLD_HF_UPSTREAM_REVISION="$rev"
    [[ -n "$rev" ]]
  }
fi

# tensorfold_checkpoint_revision_record <state_file> <label> <repo_id> <cache_dir>
#   Called after prepare.sh. Records the revision that is on disk now, keyed by
#   <label> (MODEL/DRAFT → <label>_REVISION). An unresolvable cache keeps the
#   previously recorded value rather than erasing it.
if ! declare -F tensorfold_checkpoint_revision_record > /dev/null 2>&1; then
  tensorfold_checkpoint_revision_record() {
    local state="$1" label="$2" id="$3" dir="$4"
    local key="${label}_REVISION" tmp cur=""
    if [[ -f "$state" ]]; then
      cur="$(env_file_get "$state" "$key")"
    fi
    if tensorfold_hf_cache_revision "$dir"; then
      cur="$TENSORFOLD_HF_CACHE_REVISION"
    fi
    if [[ -z "$cur" ]]; then
      info "${id}: no cached snapshot and no recorded revision — nothing recorded in ${state}."
      return 0
    fi
    tmp="$(mktempfile checkpoint-revisions)"
    if [[ -f "$state" ]]; then
      grep -Ev "^[[:space:]]*${key}=" "$state" > "$tmp" || true
    else
      printf '# Resolved checkpoint revisions (kwisatz, not secrets).\n' > "$tmp"
    fi
    printf '%s=%s\n' "$key" "$cur" >> "$tmp"   # value only — env_file_get reads it verbatim
    env_file_write "$state" < "$tmp"
    info "Recorded ${label} revision for ${id}: ${cur:0:12} ($(basename "$dir"))"
    return 0
  }
fi

# tensorfold_checkpoint_revision_recheck <state_file> <label> <repo_id> <cache_dir> <sink>
#   <sink>: "echo" prints one status line (--check), "log" warns during an
#   install run. Both report, nothing fails:
#   - cached revision differs from the recorded one  -> the recipe resolved other weights
#   - upstream main differs from the recorded one    -> the next prepare.sh downloads other weights
#   - several snapshots in the cache                 -> which one was assumed
if ! declare -F tensorfold_checkpoint_revision_recheck > /dev/null 2>&1; then
  tensorfold_checkpoint_revision_recheck() {
    local state="$1" label="$2" id="$3" dir="$4" sink="$5"
    local key="${label}_REVISION" recorded="" cached="" upstream="" note

    [[ -f "$state" ]] && recorded="$(env_file_get "$state" "$key")"
    if tensorfold_hf_cache_revision "$dir"; then
      cached="$TENSORFOLD_HF_CACHE_REVISION"
    fi
    tensorfold_hf_upstream_revision "$id" || true
    upstream="$TENSORFOLD_HF_UPSTREAM_REVISION"

    local st_ok=1 st="recorded ${recorded:-<none>}"
    if [[ -n "$recorded" && -n "$cached" && "$cached" != "$recorded" ]]; then
      st_ok=0
      st="cached ${cached:0:12} != recorded ${recorded:0:12}"
    elif [[ -z "$recorded" ]]; then
      st="not recorded yet"
    elif [[ -z "$cached" ]]; then
      st="not cached"
    else
      st="cached ${cached:0:12}"
    fi
    note=""
    if [[ -n "$upstream" && -n "$recorded" && "$upstream" != "$recorded" ]]; then
      st_ok=0
      note=" upstream main is now ${upstream:0:12} — a fresh download (no .prepared marker, or a cleared cache) would pull different weights"
    elif [[ -z "$upstream" ]]; then
      note=" (upstream revision unknown — hub API unreachable)"
    fi
    if (( TENSORFOLD_HF_CACHE_COUNT > 1 )); then
      note="${note} ${TENSORFOLD_HF_CACHE_COUNT} snapshots cached, assumed the newest"
    fi

    if [[ "$sink" == "echo" ]]; then
      if (( st_ok )); then
        echo -e "  ${BOLD}${label} rev:${RESET}  ${GREEN}${st}${RESET}${note}"
      else
        echo -e "  ${BOLD}${label} rev:${RESET}  ${YELLOW}${st}${RESET} — drift vs the validated revision (re-validate before updating the recorded value)${note}"
      fi
    else
      if (( st_ok )); then
        info "${id}: ${st}${note}"
      else
        warn "${id}: ${st}${note} — the 27B recipe pins no revision: a re-run may load weights this entry was never validated against. Re-validate, then update ${key} in ${state}."
      fi
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
#   One pass, -A1: require 'type: local' right after the name line — a
#   same-named remote entry must not count as the local tensorfold entry. The
#   model name is escaped (review 27B F13: in 'qwen3.8-27b-tf' every dot would
#   otherwise match any character).
if ! declare -F tensorfold_status_catalog > /dev/null 2>&1; then
  tensorfold_status_catalog() {
    local catalog="$1" name="$2" esc
    esc="${name//./\\.}"
    if [[ -f "$catalog" ]] && grep -A1 "name: ${esc} *$\|name: ${esc} #" "$catalog" | grep -q "type: local"; then
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

# tensorfold_status_llama_swap_writable <config_file>
#   The same verdict tensorfold_require_llama_swap_config_writable gates the
#   install on, reported before anyone starts a ~122 GiB download.
if ! declare -F tensorfold_status_llama_swap_writable > /dev/null 2>&1; then
  tensorfold_status_llama_swap_writable() {
    local config="$1" dir
    dir="$(dirname "$config")"
    if [[ ! -e "$config" ]]; then
      echo -e "  ${BOLD}Config:${RESET}      ${YELLOW}not created yet${RESET} (${config})"
    elif [[ -w "$config" || -w "$dir" ]]; then
      echo -e "  ${BOLD}Config:${RESET}      ${GREEN}writable${RESET} (${config})"
    else
      echo -e "  ${BOLD}Config:${RESET}      ${RED}read-only${RESET} (${config} — sudo chown $(id -un):$(id -gn) ${config})"
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
