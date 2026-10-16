#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# lib/tensorfold-helper.sh — Shared helper library for the TensorFold tasks
# =============================================================================
#
# PURPOSE:
#   The two `setup-tensorfold-spark-qwen38-*.sh` scripts install a TensorFold
#   recipe on the same DGX Spark and must converge the same way, so the logic
#   they genuinely share lives here instead of being copy-pasted. Anything that
#   is per-model (names, ports, recipe pins, serve levers, sizes) stays in the
#   task script; anything mechanical and identical belongs in this file.
#
#   This file complements lib/helpers.sh — source that one first (colour,
#   logging, env-file and port-validation primitives), then this one.
#
# USAGE:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/tensorfold-helper.sh"
#
# CONVENTIONS:
#   - every function is wrapped in `if ! declare -F <name> …` so sourcing twice
#     (directly + via another library) is harmless
#   - functions use info/success/warn/error from lib/helpers.sh; error() exits
#   - the caller decides policy, the helper measures and reports
# =============================================================================
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
