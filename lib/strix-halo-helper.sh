#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # STRIX_* are published globals, read by the sourcing task script
# =============================================================================
# lib/strix-halo-helper.sh — Shared logic for the AMD Strix Halo tasks
# =============================================================================
# PURPOSE
#   Tasks targeting an AMD "Strix Halo" box (Ryzen AI MAX+ 395, Radeon 8060S,
#   gfx1151, 128 GiB of unified LPDDR5X) all have to answer the same questions:
#
#     * Is this actually a Strix Halo, and is the kernel new enough to drive it?
#     * Is the GPU-reserve tuning active on the running kernel (the knobs in
#       /proc/cmdline), or were they only written to the GRUB drop-in?
#     * Is the weights snapshot on disk, and does it contain the model files?
#     * What is still pending — weights, engine image, disk — in one report?
#     * Is the engine reachable, does the proxy see it, does it answer?
#     * What is the memory headroom, and does the sibling stack also claim it?
#
#   This library answers them. Every function is a `declare -F` guard, so a
#   task may override any of them.
#
# USAGE
#   source "${SCRIPT_DIR}/../lib/helpers.sh"
#   source "${SCRIPT_DIR}/../lib/strix-halo-helper.sh"
#
#   Then call, in the order the task needs:
#
#     strix_preflight_sanity                 # docker, tooling, llama-swap, hw
#     strix_require_strix_hal "<sizing>"     # gfx1151 + kernel + RAM
#     strix_require_tuning "<sizing>"        # GPU-reserve knobs ACTIVE
#     strix_require_locked_memory            # dockerd LimitMEMLOCK
#     strix_require_devices                  # /dev/kfd, /dev/dri
#     strix_warn_swap                        # zram active? warn only
#     strix_require_free_space <GB> <what>   # disk headroom
#     strix_resolve_pending_downloads ...    # STRIX_NEEDS_MODEL/IMAGE/PENDING
#     strix_pull_engine_image <ref>          # docker pull, skip when present
#     strix_require_llama_swap_config_writable
#     strix_render_wrapper <tpl> <dst> <vars>
#     strix_render_serve_env <tpl> <dst> <port> <vars>
#     strix_merge_model_entry <file> <name>
#     strix_sync_llama_swap
#     strix_require_llama_swap_up
#     strix_smoke_test ...                   # one /v1/chat/completions
#     strix_record_engine_version <file> <ref>
#     strix_checkpoint_revision_recheck      # weights updated upstream?
#
# PUBLISHED GLOBALS
#   Strix tasks publish state through these, not through return codes alone,
#   because the --check renderer and the gate both need the same numbers. A
#   function that inspects something always sets its full result set, even on
#   success paths, so --check output never depends on which branch ran.
#
#     STRIX_GPU_OK          1 when a gfx1151 amdgpu device is bound
#     STRIX_GPU_NAME        "Radeon 8060S (gfx1151)" or the tool's wording
#     STRIX_PCI_ID          "1002:<device>" for the AMD device amdgpu claimed,
#                           reported only — it is never matched against
#     STRIX_KERNEL_OK       1 when uname -r >= STRIX_MIN_KERNEL
#     STRIX_KERNEL_HAVE     running kernel version triple
#     STRIX_KERNEL_WANT     required kernel version triple
#     STRIX_RAM_OK          1 when MemTotal >= STRIX_MIN_RAM_GIB
#     STRIX_RAM_TOTAL_GIB   whole GiB of RAM seen in /proc/meminfo
#     STRIX_GTT             active|inactive|mismatched|absent
#     STRIX_REBOOT_REQUIRED 1 when the tuning is written but not running
#     STRIX_RESERVE_GIB     reserve actually in force on the running kernel
#     STRIX_GTT_DETAIL      one-line explanation for status lines and errors
#     STRIX_HEALTH_TIMEOUT_BUMPED 1 when the healthTimeout patch applied
#
#   Nothing in this library runs a privileged command: gates read and probe
#   only. Every write belongs to a task script.
#
# NOTE ON THE TENSORFOLD LIBRARY
#   This file deliberately does NOT share functions with
#   lib/tensorfold-helper.sh, even where the code is nearly identical (the
#   models-entry merge, the sync, the serve.env convergence, the smoke-test
#   shape). Those functions changed semantics during TensorFold development —
#   the serve.env convergence and the models-entry merge both did — and the
#   Strix work has no validated DGX path yet. Importing them across libraries
#   would couple two stacks that are free to diverge. What is copied says so
#   at the copy site. If the two stacks ever converge onto one engine, that is
#   the moment to factor the shared core out — not before.
# =============================================================================

if [[ -z "${SCRIPT_DIR:-}" ]]; then
  warn "lib/strix-halo-helper.sh sourced without SCRIPT_DIR set"
fi

# Floors the gates compare against. Set here so every consumer — including a
# plain `source` outside a task, where no task defaults exist — gets the same
# numbers rather than an unbound variable in the middle of an error message.
STRIX_MIN_KERNEL="${STRIX_MIN_KERNEL:-6.18.9}"
STRIX_MIN_RAM_GIB="${STRIX_MIN_RAM_GIB:-125}"

# =============================================================================
# TASK-DIR RESOLUTION
# =============================================================================

# Resolve the directory a task's templates live in. Same shape as
# tensorfold's _tensorfold_task_dir / _strix's future twin, for the same
# reason: these task scripts live in tasks/ and their templates in
# templates/<task>/, and neither path is knowable from $PWD.
#
# Unlike tensorfold's, this one also accepts the caller's override via
# KWISATZ_TEMPLATE_DIR, because the tuning task's templates sit in a directory
# that is shared by name with the hardware drop-ins and may be relocated.
_strix_task_dir() {
  local d="${SCRIPT_DIR:-.}"
  if [[ -n "${KWISATZ_TEMPLATE_DIR:-}" && -d "${KWISATZ_TEMPLATE_DIR}" ]]; then
    printf '%s\n' "$KWISATZ_TEMPLATE_DIR"
    return
  fi
  printf '%s\n' "$(dirname "$(cd "$d" && pwd)")/templates"
}

# =============================================================================
# SMALL PRIMITIVES
# =============================================================================

# Validate a single port: integer, in the usable range, not privileged.
#
# The Strix tasks must not have to reason about the difference between
# "PORT is not set" and "PORT is empty": both mean "use the default", and the
# default is applied by the task. validate_port is called for every port the
# task is about to write.
if ! declare -F validate_port &>/dev/null; then
  validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] \
      || { error "Invalid port '$port' (must be numeric)"; return 1; }
    (( port >= 1024 && port <= 65535 )) \
      || { error "Port $port out of range (1024-65535)"; return 1; }
  }
fi

# True when have >= want, comparing dotted version triples.
#
# Needed because uname -r reports things like "6.18.9-generic" and "6.19.0-rc2",
# and plain string comparison would call 6.18.10 older than 6.18.9.
strix_version_ge() {
  local want="$1" have="$2"
  local w h i
  local -a wa=() ha=()
  IFS=. read -r -a wa <<<"${want%%-*}"
  IFS=. read -r -a ha <<<"${have%%-*}"
  for ((i = 0; i < ${#wa[@]} || i < ${#ha[@]}; i++)); do
    w="${wa[i]:-0}"
    h="${ha[i]:-0}"
    [[ "$w" =~ ^[0-9]+$ ]] || w=0
    [[ "$h" =~ ^[0-9]+$ ]] || h=0
    if ((h > w)); then return 0; fi
    if ((h < w)); then return 1; fi
  done
  return 0
}

# Kernel version triple out of `uname -r` (drops -rc/-generic/suffixes).
strix_kernel_release() {
  uname -r | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# =============================================================================
# EXTERNAL DEPENDENCY CHECKS
# =============================================================================

# docker must be present and reachable.
#
# Checked before any template is rendered: a task that writes its whole layout
# and then discovers docker is missing leaves an orphaned stack directory
# behind. Better to fail with a message that names the missing thing.
strix_require_docker() {
  command -v docker &>/dev/null \
    || { error "docker is required — install it first (enable setup-docker in machine-config.yml, then ./run-setup.sh apply)"; return 1; }
  docker info &>/dev/null \
    || { error "Cannot reach the docker daemon — is it running? (systemctl status docker)"; return 1; }
}

# Tools a Strix task must have. `hf` matters because gufo-prepare.sh uses it to
# pull weights, and `envsubst` because the config.yaml writability gate probes
# it. jq is required to read and patch llama-swap's config.
strix_require_tooling() {
  local tool missing=0
  for tool in jq envsubst docker; do
    command -v "$tool" &>/dev/null \
      || { error "Missing required tool: $tool"; missing=1; }
  done
  if [[ $missing -eq 0 ]]; then
    command -v hf &>/dev/null \
      || warn "hf not found (huggingface_hub CLI). gufo-prepare.sh needs it to download weights — install python3-huggingface-hub or 'pip install huggingface_hub'."
  fi
  return "$missing"
}

# llama-swap must be installed, running, and able to see the container runtime.
#
# Unlike tensorfold, the check here does NOT pass --gpus to `docker run`:
# llama-swap's own probe does not, and an AMD box has no nvidia container
# toolkit, so that probe always fails with "could not select device driver"
# whatever ROCm is installed.
strix_require_llama_swap() {
  # What proves llama-swap is installed is the unit it runs from, not a marker
  # file. Two reasons, and both bit here: /run is tmpfs, so any state parked
  # under it is gone at the first reboot and the verdict silently flips to
  # "not installed" on a healthy box; and nothing in this repo ever wrote this
  # particular path in the first place, so the probe was false even before a
  # reboot touched it.
  if [[ ! -f /etc/systemd/system/llama-swap.service ]] \
    && ! systemctl cat llama-swap.service >/dev/null 2>&1; then
    err_msg "llama-swap service not installed. Run: ${SCRIPT_DIR:-.}/setup-llama-swap.sh"
    return 1
  fi
  if ! systemctl is-active --quiet llama-swap 2>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -q "llama-swap"; then
      warn "llama-swap is running but not managed by systemd — install the unit so it starts after a reboot"
    else
      err_msg "llama-swap service not running. Start with: sudo systemctl start llama-swap"
      return 1
    fi
  fi
  if ! command -v curl &>/dev/null; then
    warn "curl not found — cannot verify llama-swap connectivity"
    return 0
  fi
  local user="${LLAMA_SWAP_USER:-llama-swap}"
  local -a cmd
  cmd=()
  if command -v run0 &>/dev/null; then
    cmd+=(run0)
  elif command -v sudo &>/dev/null; then
    cmd+=(sudo)
  fi
  if [[ "${#cmd[@]}" -gt 0 ]] \
    && ! sudo -n -u "$user" docker run --rm --entrypoint echo \
      alpine:3.22 llama-swap-probe >/dev/null 2>&1; then
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      : # it is in the group; the failure above is probably a registry hiccup
    else
      warn "user '$user' is not in the 'docker' group — llama-swap cannot start containers (sudo usermod -aG docker '$user'; restart llama-swap)"
    fi
  fi
  if curl -s --max-time 3 "http://127.0.0.1:${LLAMA_SWAP_PORT:-8080}/health" &>/dev/null; then
    info "llama-swap reachable (http://127.0.0.1:${LLAMA_SWAP_PORT:-8080})"
  else
    warn "llama-swap not reachable on port ${LLAMA_SWAP_PORT:-8080}"
  fi
}

# =============================================================================
# HARDWARE GATES
# =============================================================================

# Detect the gfx1151 Strix Halo compute engine.
#
# No PCI device id is part of this test, deliberately. AMD ships the same
# graphics IP under different ids across pci.ids releases — Strix Halo reads
# 1002:1586 on a current pci.ids, and 1002:15bf is a Phoenix1 part — so an id
# in the gate is a machine-specific constant rather than an architecture test.
# It would reject exactly the hardware this tuning is sized for while passing a
# Phoenix APU.
#
# What identifies the machine instead, in order:
#
#   1. the gfx target the amdgpu driver publishes itself, in the KFD topology:
#      /sys/class/kfd/kfd/topology/nodes/*/properties -> gfx_target_version,
#      encoded MMMNNRR, so GC 11.5.1 is 110501 -> gfx1151. This is the primary
#      path because it needs no ROCm userspace, and the userspace is what
#      breaks first: a distro rocminfo older than the GPU (5.7 here) prints
#      "Agent creation failed / unrecognized id" and only lists the CPU.
#   2. rocm-smi --showid / rocminfo output mentioning gfx1151, for boxes whose
#      sysfs is unreadable to the invoking user.
#
# The PCI scan still runs, but only to report the bus id in the status line and
# to show whether an AMD device is claimed by amdgpu at all.
#
# Sets STRIX_GPU_OK / STRIX_GPU_NAME / STRIX_PCI_ID and returns 0 on a match.
# Never fails the process; the caller decides what a miss means.
strix_hal_gpu() {
  STRIX_GPU_OK=0
  STRIX_GPU_NAME=""
  STRIX_PCI_ID=""
  local dev vendor device driver node target
  for dev in /sys/bus/pci/devices/*/; do
    [[ -r "${dev}vendor" ]] || continue
    vendor="$(tr -d '[:space:]' <"${dev}vendor" 2>/dev/null || true)"
    device="$(tr -d '[:space:]' <"${dev}device" 2>/dev/null || true)"
    driver="$(basename "$(readlink -f "${dev}driver" 2>/dev/null || true)" 2>/dev/null || true)"
    if [[ "$vendor" == "0x1002" && "$driver" == "amdgpu" ]]; then
      STRIX_PCI_ID="${vendor#0x}:${device#0x}"
      break
    fi
  done
  # GC 11.5.1 is what ROCm compiles as gfx1151; the CPU node reports 0.
  for node in /sys/class/kfd/kfd/topology/nodes/*/properties; do
    target="$(awk '/^gfx_target_version/ {print $2; exit}' "$node" 2>/dev/null || true)"
    if [[ "$target" == "110501" ]]; then
      STRIX_GPU_OK=1
      STRIX_GPU_NAME="gfx1151 (kfd topology)"
      return 0
    fi
  done
  if command -v rocm-smi &>/dev/null \
    && rocm-smi --showid 2>/dev/null | grep -qi "gfx1151"; then
    STRIX_GPU_OK=1
    STRIX_GPU_NAME="gfx1151 (rocm-smi)"
    return 0
  fi
  if command -v rocminfo &>/dev/null \
    && rocminfo 2>/dev/null | grep -qi "gfx1151"; then
    STRIX_GPU_OK=1
    STRIX_GPU_NAME="gfx1151 (rocminfo)"
    return 0
  fi
  return 1
}

# Kernel + RAM floor for this class of box.
#
# Kernel: 6.18.9 is the first release with the gfx1151 support these engines
# rely on. A 6.19-rc is *newer*, so it passes — string comparison would have
# got that wrong, which is why this goes through strix_version_ge.
#
# RAM: 125 GiB of the 128 GiB SKU is the floor. Smaller memory parts cannot
# hold the model plus the GPU reserve plus everything the host already needs,
# so a task that boots on 64 GiB and silently OOM-kills mid-session has failed
# at planning time, not at runtime.
strix_require_kernel_and_ram() {
  STRIX_KERNEL_OK=0
  STRIX_RAM_OK=0
  STRIX_KERNEL_HAVE="$(strix_kernel_release || true)"
  STRIX_KERNEL_WANT="${STRIX_MIN_KERNEL:-6.18.9}"
  if [[ -z "$STRIX_KERNEL_HAVE" ]]; then
    warn "Could not read kernel version from $(uname -r)"
    return 1
  fi
  if strix_version_ge "$STRIX_KERNEL_WANT" "$STRIX_KERNEL_HAVE"; then
    STRIX_KERNEL_OK=1
  else
    warn "Kernel $STRIX_KERNEL_HAVE is older than $STRIX_KERNEL_WANT — gfx1151 support may be incomplete"
    return 1
  fi
  local total_kib
  total_kib="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)" \
    || { warn "Could not read MemTotal from /proc/meminfo"; return 1; }
  STRIX_RAM_TOTAL_GIB=$((total_kib / 1048576))
  if ((STRIX_RAM_TOTAL_GIB >= STRIX_MIN_RAM_GIB)); then
    STRIX_RAM_OK=1
    return 0
  fi
  warn "System has ${STRIX_RAM_TOTAL_GIB} GiB RAM; this task needs >= ${STRIX_MIN_RAM_GIB} GiB"
  return 1
}

# The single Strix hardware gate.
#
# Splits into three separate messages rather than one combined verdict,
# because the three failures need three different fixes:
#
#   no gfx1151 device   -> wrong machine
#   kernel too old      -> boot a newer kernel (kernel-generic-hwe-24.04-edge)
#   RAM below floor     -> wrong machine for this sizing
#
# A "wrong machine" is not something a re-run can fix, so this fails hard. It
# runs *before* the download gate for exactly that reason: nothing on disk
# should change while the task is standing on hardware it cannot serve.
strix_require_strix_hal() {
  local sizing_note="${1:-this stack}"
  step "Checking the target machine is an AMD Strix Halo"
  local failed=0
  if ! strix_hal_gpu; then
    warn "no AMD Strix Halo (gfx1151) device detected — neither the driver's KFD topology (GC 11.5.1) nor rocm-smi/rocminfo reported gfx1151"
    warn "the detected GPU (if any) is not supported by this task"
    failed=1
  fi
  if ! strix_require_kernel_and_ram; then
    warn "kernel/RAM floor not met: need kernel >= ${STRIX_KERNEL_WANT} and >= ${STRIX_MIN_RAM_GIB} GiB RAM"
    warn "install a newer kernel: sudo apt install linux-generic-hwe-24.04-edge"
    failed=1
  fi
  if [[ $failed -eq 0 ]]; then
    info "Strix Halo confirmed: ${STRIX_GPU_NAME:-gfx1151}, kernel $STRIX_KERNEL_HAVE, ${STRIX_RAM_TOTAL_GIB} GiB RAM"
    return 0
  fi
  if [[ "${STRIX_HW_CHECK:-error}" == "warn" ]]; then
    warn "STRIX_HW_CHECK=warn — continuing past the hardware gate on ${sizing_note}"
    return 0
  fi
  err_msg "This task targets AMD Strix Halo (Ryzen AI MAX+ 395 / Radeon 8060S, gfx1151, >= ${STRIX_MIN_RAM_GIB} GiB RAM, kernel >= ${STRIX_KERNEL_WANT:-6.18.9})."
  err_msg "Refusing to install ${sizing_note} on this machine: it does not have the GPU this sizing assumes."
  err_msg "Set STRIX_HW_CHECK=warn to continue anyway (bring-up only — the stack will not serve reliably)."
  return 1
}

# =============================================================================
# GPU-RESERVE TUNING STATE
# =============================================================================

# The two knobs, derived from a reserve in GiB.
#
#   amdgpu.gttsize=<GiB*1024>     MiB of GPU virtual aperture
#   ttm.pages_limit=<GiB*262144>  TTM pages (4 KiB each)
#
# Both encode the SAME number. That is the whole trap: they are read
# independently by two different subsystems, so a pair that disagrees makes
# the GPU usable and the memory bookkeeping wrong, and the failure appears
# during loading rather than at boot.
#
# The widely-copied pair 131072 / 31457280 is exactly this: 131072 MiB is a
# 128 GiB reserve (33554432 pages), while 31457280 pages is a 120 GiB reserve.
# Anyone who copied "gttsize=131072 ttm.pages_limit=31457280" from a forum set
# an inconsistent pair and will not see why allocations fail past ~119 GiB.
#
# Echoes "<gttsize_mib> <pages_limit>".
strix_gtt_math() {
  local reserve_gib="${1:-${GPU_RESERVE_GIB:-120}}"
  printf '%d %d\n' $((reserve_gib * 1024)) $((reserve_gib * 262144))
}

# Where the running kernel stands, and what that means.
#
# Four states, and they read differently in --check and in an error message:
#
#   active       knobs in /proc/cmdline agree with each other and with the
#                derived values, and the GTT pool reflects them
#   inactive     knobs are in /proc/cmdline (or the drop-in is written with
#                the right values) but the GTT pool does not reflect them, OR
#                the drop-in is written and cmdline was not re-generated
#   mismatched   knobs are in /proc/cmdline but disagree (with each other, or
#                with the reserve this run asks for)
#   absent       nothing is in /proc/cmdline and nothing is written
#
# STRIX_RESERVE_GIB is set to the reserve actually in force; STRIX_GTT_DETAIL
# is the one line that explains the state to a human.
strix_gtt_state() {
  local reserve_gib="${1:-${GPU_RESERVE_GIB:-120}}"
  local dropin="${2:-${STRIX_GRUB_DROPIN:-/etc/default/grub.d/99-kwisatz-strix-halo.cfg}}"

  STRIX_GTT="absent"
  STRIX_REBOOT_REQUIRED=0
  STRIX_RESERVE_GIB=""
  STRIX_GTT_DETAIL=""
  STRIX_RESERVE_EXPECTED_GIB="$reserve_gib"

  local want_mib want_pages
  read -r want_mib want_pages <<<"$(strix_gtt_math "$reserve_gib")"
  STRIX_WANT_GTT_SIZE_MIB="$want_mib"
  STRIX_WANT_TTM_PAGES_LIMIT="$want_pages"

  local cmdline have_mib have_pages
  cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
  have_mib="$(grep -oE 'amdgpu\.gttsize=[0-9]+' <<<"$cmdline" | tail -1 | cut -d= -f2)"
  have_pages="$(grep -oE 'ttm\.pages_limit=[0-9]+' <<<"$cmdline" | tail -1 | cut -d= -f2)"

  # Is the intended state written down, regardless of whether it is running?
  #
  # Only the assignment is the setting. This file also carries the
  # "do NOT use gttsize=131072 pages_limit=31457280" example inside a comment,
  # and grepping the whole file reads that comment as if it were the value — so a
  # drop-in whose values are empty gets reported as "drop-in written
  # (131072 / 31457280)", which is exactly how a boot line that stops amdgpu from
  # loading passed for "written" for as long as this file has had that comment.
  local written_mib="" written_pages=""
  local -a dropin_effective
  dropin_effective=()
  if [[ -r "$dropin" ]]; then
    mapfile -t dropin_effective < <(grep -v '^[[:space:]]*#' "$dropin" 2>/dev/null || true)
    written_mib="$(printf '%s\n' "${dropin_effective[@]}" \
      | grep -oE 'amdgpu\.gttsize=[0-9]+' | tail -1 | cut -d= -f2)"
    written_pages="$(printf '%s\n' "${dropin_effective[@]}" \
      | grep -oE 'ttm\.pages_limit=[0-9]+' | tail -1 | cut -d= -f2)"
  fi
  STRIX_DROPIN_WRITTEN=0
  if [[ -n "$written_mib" || -n "$written_pages" ]]; then
    STRIX_DROPIN_WRITTEN=1
  fi

  # Present and malformed is worse than absent: a knob written with no value is
  # rejected by the kernel, amdgpu does not load, and there is no /dev/kfd.
  if [[ -z "$written_mib" && -z "$written_pages" && ${#dropin_effective[@]} -gt 0 ]] \
    && printf '%s\n' "${dropin_effective[@]}" \
      | grep -qE '(amdgpu\.gttsize|ttm\.pages_limit)=[[:space:]]'; then
    STRIX_GTT="mismatched"
    STRIX_REBOOT_REQUIRED=0
    STRIX_RESERVE_GIB=""
    STRIX_GTT_DETAIL="the drop-in writes amdgpu.gttsize= / ttm.pages_limit= with no value — the kernel rejects the parameter, amdgpu will not load and /dev/kfd will be missing. Re-run tasks/setup-strix-halo-tuning.sh (or set the pair by hand) and update-grub"
    return 0
  fi

  if [[ -z "$have_mib" && -z "$have_pages" ]]; then
    if [[ -n "$written_mib" && -n "$written_pages" ]]; then
      STRIX_GTT="inactive"
      STRIX_REBOOT_REQUIRED=1
      STRIX_RESERVE_GIB=$((written_mib / 1024))
      STRIX_GTT_DETAIL="drop-in written (gttsize=${written_mib} MiB / pages_limit=${written_pages}) but not in /proc/cmdline — needs 'sudo update-grub' and a reboot"
    else
      STRIX_GTT="absent"
      STRIX_GTT_DETAIL="neither amdgpu.gttsize= nor ttm.pages_limit= is present in /proc/cmdline"
    fi
    return 0
  fi

  if [[ -z "$have_mib" || -z "$have_pages" ]]; then
    STRIX_GTT="mismatched"
    STRIX_GTT_DETAIL="only one of the two knobs is set (gttsize='${have_mib:-unset}' MiB, pages_limit='${have_pages:-unset}') — both are required and must agree"
    return 0
  fi

  # Pair-consistency: pages_limit must be gttsize/1024*262144 == gttsize*256.
  if ((have_pages != have_mib * 256)); then
    STRIX_GTT="mismatched"
    STRIX_GTT_DETAIL="running kernel has gttsize=${have_mib} MiB with pages_limit=${have_pages} (that is $((have_pages / 262144)) GiB, not $((have_mib / 1024)) GiB) — an inconsistent pair: gttsize=131072 ttm.pages_limit=31457280 is the widely-copied example of this bug"
    return 0
  fi

  STRIX_RESERVE_GIB=$((have_mib / 1024))

  if [[ "$have_mib" != "$want_mib" ]]; then
    STRIX_GTT="mismatched"
    STRIX_GTT_DETAIL="running kernel reserves $((have_mib / 1024)) GiB (gttsize=${have_mib} MiB, pages_limit=${have_pages}) but this run expects ${reserve_gib} GiB (gttsize=${want_mib} MiB, pages_limit=${want_pages})"
    return 0
  fi

  # Last gate: does the kernel actually give the GPU that much address space?
  # mem_info_gtt_total is reported in bytes; when it is not readable (older
  # driver, or permissions) we keep the derived-values verdict and say so.
  local gtt_total="" total_path
  for total_path in /sys/class/drm/card*/device/mem_info_gtt_total; do
    [[ -r "$total_path" ]] || continue
    gtt_total="$(tr -d '[:space:]' <"$total_path" 2>/dev/null || true)"
    [[ -n "$gtt_total" ]] && break
  done
  if [[ -n "$gtt_total" && "$gtt_total" =~ ^[0-9]+$ ]]; then
    if ((gtt_total < want_mib * 1048576 - 1073741824)); then
      STRIX_GTT="inactive"
      STRIX_REBOOT_REQUIRED=1
      STRIX_GTT_DETAIL="knobs are on the kernel command line (gttsize=${have_mib} MiB, pages_limit=${have_pages}) but the GTT pool is only $((gtt_total / 1073741824)) GiB — the tuning is not in effect, a reboot is required"
      return 0
    fi
    STRIX_GTT_DETAIL="${reserve_gib} GiB active on the running kernel (gttsize=${have_mib} MiB, pages_limit=${have_pages}, gtt pool $((gtt_total / 1073741824)) GiB)"
  else
    STRIX_GTT_DETAIL="${reserve_gib} GiB active on the running kernel (gttsize=${have_mib} MiB, pages_limit=${have_pages}, mem_info_gtt_total not readable)"
  fi
  STRIX_GTT="active"
  return 0
}

# Gate: the GPU-reserve tuning must be ACTIVE on the running kernel.
#
# The rule that makes this a gate and not a note: writing the drop-in does
# NOT satisfy it. "Drop-in written, /proc/cmdline unchanged" means the box was
# configured and never rebooted, and that is the single most common way to end
# up with a stack that allocates from RAM at 22:00 and OOMs at 22:04.
strix_require_tuning() {
  local sizing_note="${1:-this stack}"
  step "Checking GPU-reserve tuning is active"
  strix_gtt_state
  info "GPU reserve: ${STRIX_GTT_DETAIL}"
  if [[ "$STRIX_GTT" == "active" ]]; then
    return 0
  fi

  local reserve="${STRIX_RESERVE_EXPECTED_GIB:-${GPU_RESERVE_GIB:-120}}"
  local -a pair
  read -r -a pair <<<"$(strix_gtt_math "$reserve")"

  if [[ "${STRIX_ALLOW_UNTUNED:-0}" == "1" ]]; then
    warn "STRIX_ALLOW_UNTUNED=1 — proceeding with GPU reserve state: ${STRIX_GTT}"
    warn "the stack may allocate from system RAM instead of the GPU aperture"
    return 0
  fi
  if [[ "${STRIX_HW_CHECK:-error}" == "warn" ]]; then
    warn "STRIX_HW_CHECK=warn — continuing past the tuning gate on ${sizing_note}"
    return 0
  fi

  err_msg "The GPU-reserve tuning is not active on the running kernel: ${STRIX_GTT_DETAIL}"
  err_msg "This stack needs a ${reserve} GiB GPU aperture on a ${STRIX_MIN_RAM_GIB} GiB box (${sizing_note})."
  if [[ "$STRIX_REBOOT_REQUIRED" == "1" ]]; then
    err_msg ""
    err_msg "The drop-in IS written but the running kernel still boots without it. Reboot:"
    err_msg "  sudo update-grub && sudo reboot"
  else
    err_msg ""
    err_msg "Apply it and reboot before retrying:"
    err_msg "  ${SCRIPT_DIR:-.}/setup-strix-halo-tuning.sh --reserve ${reserve}"
    err_msg "  sudo update-grub && sudo reboot"
  fi
  err_msg ""
  err_msg "Then verify: grep -o 'amdgpu.gttsize=[0-9]*' /proc/cmdline   # want ${pair[0]}"
  err_msg "            grep -o 'ttm.pages_limit=[0-9]*'   /proc/cmdline   # want ${pair[1]}"
  err_msg "Do NOT copy gttsize=131072 ttm.pages_limit=31457280 from a forum: that"
  err_msg "pair is inconsistent (128 GiB aperture, 120 GiB of TTM pages)."
  return 1
}

# =============================================================================
# CONTAINER PREREQUISITES
# =============================================================================

# The engine must be able to lock its weights.
#
# The container flag (ulimit memlock=-1) only opens a ceiling; it cannot raise
# the ceiling inherited from the daemon. So the real check is dockerd's own
# limit. A hard stop, not a warning, because a 95 GB model fails at load time
# with "Resource temporarily unavailable", and a warning nobody read is the
# same as no check.
#
# Read-only by design. This library never edits a systemd unit.
strix_require_locked_memory() {
  step "Checking docker's locked-memory limit"
  local pid line
  pid="$(pgrep -x dockerd 2>/dev/null | head -1 || true)"
  if [[ -z "$pid" ]]; then
    warn "dockerd not found — cannot read its locked-memory limit"
    return 0
  fi
  if ! line="$(grep -m1 'Max locked memory' "/proc/${pid}/limits" 2>/dev/null)"; then
    warn "Could not read Max locked memory from /proc/${pid}/limits"
    return 0
  fi
  local value unit_
  value="$(awk '{print $(NF-2)}' <<<"$line")"
  unit_="$(awk '{print $(NF-1)}' <<<"$line")"
  if [[ "$value" == "unlimited" || "$value" == "infinity" ]]; then
    info "dockerd runs with unlimited locked memory"
    return 0
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    warn "Unparseable locked-memory limit ('$value $unit_') on dockerd"
    return 0
  fi
  case "$unit_" in
  bytes) value=$((value)) ;;
  KiB | K) value=$((value * 1024)) ;;
  MiB | M) value=$((value * 1024 * 1024)) ;;
  GiB | G) value=$((value * 1024 * 1024 * 1024)) ;;
  *) warn "Unknown locked-memory unit '$unit_'"; return 0 ;;
  esac
  local need_gib="${GPU_RESERVE_GIB:-120}"
  local unit
  if ((value >= need_gib * 1073741824)); then
    info "dockerd locked memory is $((value / 1073741824)) GiB"
    return 0
  fi
  if [[ "${STRIX_HW_CHECK:-error}" == "warn" ]]; then
    warn "dockerd locked memory is only $((value / 1048576)) MiB — STRIX_HW_CHECK=warn, continuing"
    return 0
  fi
  unit="/etc/systemd/system/docker.service.d/10-kwisatz-memlock.conf"
  err_msg "dockerd's locked-memory limit is $((value / 1048576)) MiB — a ${need_gib} GiB model cannot be loaded under it."
  err_msg "The container's '--ulimit memlock=-1' can only lower this ceiling, never raise it."
  err_msg ""
  err_msg "Raise it (restarts docker; this KILLS every running stack on the box):"
  err_msg "  sudo mkdir -p $(dirname "$unit")"
  err_msg "  printf '[Service]\\nLimitMEMLOCK=infinity\\n' | sudo tee $unit >/dev/null"
  err_msg "  sudo systemctl daemon-reload && sudo systemctl restart docker"
  err_msg ""
  err_msg "Restarting docker is disruptive: it takes llama-swap, open-webui and"
  err_msg "any model containers down until they come back. Do it deliberately."
  return 1
}

# The two devices the engine needs. Missing is always fatal here — there is no
# flag that makes /dev/kfd exist, so a task that proceeds past this has to
# discover the same problem at first inference.
strix_require_devices() {
  step "Checking GPU device access"
  local dev missing=0
  for dev in /dev/kfd /dev/dri; do
    if [[ -e "$dev" ]]; then
      info "Found $dev"
    else
      err_msg "Missing $dev — ROCm is not installed, or the device is not exposed to the host"
      missing=1
    fi
  done
  [[ -d "/dev/dri/renderD128" ]] && info "renderD128 present"
  return "$missing"
}

# Swap configuration warning.
#
# Strix Halo boxes are usually shipped with zram, and zram is the worst thing
# on a memory-bound inference box: the kernel starts paging weights into a
# compressed block device in RAM, which is slower than simply not swapping and
# steals memory from the thing doing the inference.
#
# A warning, never an error: removing swap is the operator's call, and some
# boxes are configured with a real NVMe swap partition on purpose.
strix_warn_swap() {
  step "Checking swap configuration"
  local zram=0 entry dev
  while read -r dev _; do
    [[ "$dev" == "/dev/zram"* ]] && zram=1
  done < <(swapon --show=NAME --noheadings 2>/dev/null || true)
  if [[ $zram -eq 1 ]]; then
    warn "zram-backed swap is active and will page model weights into compressed RAM — disable it (swapoff <zram dev> && sudo systemctl disable --now zramswap zram-tools)"
    warn "The Strix tasks assume the model stays resident in RAM; zram makes it thrash instead."
  else
    info "No zram swap detected"
  fi
}

# =============================================================================
# MEMORY BUDGET
# =============================================================================

# The sizing table.
#
# Printed verbatim by --help and --check. It is data, not prose, because the
# numbers are what an operator actually compares against `free -h`; the
# reasoning behind each row lives in the plan/research document.
#
# 127 GiB is the usable budget, not the physical 128: the kernel, the display
# engine, and the memory the iGPU cannot hand back account for the difference,
# and quoting 128 is how you end up 3 GiB short at first load.
#
# Strix tasks do not enforce these numbers. There is no reliable way to read
# "headroom for everything else" from a box that has not been used to its own
# limits yet. The line is printed in --help, and printed again on every run.
strix_status_memory_budget() {
  local label="${1:-both}"
  printf '  Usable budget: 127 GiB (not the physical 128 — kernel and display carve out the difference)\n'
  printf '  ┌────────────────────────────────────┬──────────┬────────────┐\n'
  printf '  │ checkpoint                         │ weights  │ in 120 GiB   │\n'
  printf '  ├────────────────────────────────────┼──────────┼────────────┤\n'
  printf '  │ Flash-Next UD-Q4_K_XL (4 shards)   │ 103.6 GiB│ ~16 GiB left │\n'
  printf '  │ Flash-Next UD-IQ4_XS (3 shards)    │  87.2 GiB│ ~33 GiB left │\n'
  printf '  │ 27B UD-Q4_K_XL (+ DFlash2 1.1 GB)  │  17.6 GiB│ ~102 GiB left│\n'
  printf '  │ both at UD-Q4_K_XL                 │ 119.9 GiB│  ~0 GiB      │\n'
  printf '  └────────────────────────────────────┴──────────┴────────────┘\n'
  printf '  (weights only, and GiB, not GB: a checkpoint listed as 111.3 GB is\n'
  printf '   103.6 GiB of aperture, and the reserve is counted in GiB.)\n'
  if [[ "$label" == "both" ]]; then
    printf '  Both at UD-Q4_K_XL is 119.9 GiB against a %s GiB reserve —\n' "${GPU_RESERVE_GIB:-120}"
    printf '  that is the whole aperture before a single KV page, so it is not tight, it\n'
    printf '  does not fit. Serve Flash-Next at UD-IQ4_XS to keep both resident (~104 GiB).\n'
  else
    printf '  Headroom is for KV cache and sessions: at 262 K context this is where the\n'
    printf '  room actually goes, so keep other engines off the aperture while loading.\n'
  fi
}

# =============================================================================
# WEIGHTS: PRESENCE AND THE DOWNLOAD GATE
# =============================================================================

# True when every pattern is matched inside some snapshots/<rev>/ directory of
# <dir>, AND the match is a complete set.
#
# "Any file matches" was the old rule, and it is the rule that lets a
# half-finished download through: the checkpoint is four files named
# `...-00001-of-00004.gguf`, so 1-of-4 present satisfies a glob and the gate
# says "cached" — then Gufo opens the first shard, discovers the other three by
# name, and fails at load, hours later and with an error that mentions nothing
# about a partial download. Completeness is decided from the filename itself
# (`-of-` declares the count), so it costs nothing.
#
# Patterns rather than exact filenames, deliberately: the sharded repos rename
# their shard files between revisions, and a gate keyed on the exact name breaks
# the day upstream reshuffles. The wrapper still owns the list — this only
# evaluates what the wrapper said.
path_has_gguf_snapshot() {
  local dir="$1"
  shift
  [[ -d "$dir" ]] || return 1
  STRIX_GGUF_MISS=""
  local pattern snap chosen
  for pattern in "$@"; do
    # Same newest-first rule gufo-serve.sh applies, so the gate and the runtime
    # cannot disagree about which snapshot is "the" snapshot.
    chosen=""
    while IFS= read -r snap; do
      [[ -n "$snap" ]] || continue
      if compgen -G "${snap}/${pattern}" >/dev/null 2>&1; then
        chosen="$snap"
        break
      fi
    done < <(find "$dir/snapshots" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | sed 's/^[0-9.]* //')
    if [[ -z "$chosen" ]]; then
      STRIX_GGUF_MISS="${pattern} — no match under ${dir}/snapshots"
      return 1
    fi
    if ! strix_shard_set_complete "$chosen" "$pattern"; then
      STRIX_GGUF_MISS="${STRIX_GGUF_MISS:-${pattern} — incomplete shard set in ${chosen}}"
      return 1
    fi
  done
  return 0
}

# strix_shard_set_complete <snapshot-dir> <pattern>
#   Read the declared shard count out of the file names and require all of them.
#
#   The leader is the first name the glob sorts to, which is the first shard of
#   a sharded checkpoint and the only file the engine is told about. Its own
#   `-N-of-M` suffix says how many files the set has, and the same prefix
#   identifies the set — so two quants cached side by side cannot borrow each
#   other's shards and produce a Frankenstein checkpoint that passes the gate.
#   Single-file checkpoints declare nothing, and are simply present-or-absent.
strix_shard_set_complete() {
  local snap="$1" pattern="$2"
  local -a files=()
  mapfile -t files < <(compgen -G "${snap}/${pattern}" 2>/dev/null | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    STRIX_GGUF_MISS="${pattern} — nothing matched in ${snap}"
    return 1
  fi
  local leader base prefix iw cw total n f dir
  leader="${files[0]}"
  # The glob may point inside a checkpoint *subdirectory* (Flash-Next keeps each
  # quant in its own directory), so the sibling shards are checked next to the
  # file the glob matched, not next to the snapshot root.
  dir="${leader%/*}"
  base="${leader##*/}"
  if [[ ! "$base" =~ ^(.*-)([0-9]+)-of-([0-9]+)\.gguf$ ]]; then
    return 0
  fi
  prefix="${BASH_REMATCH[1]}"
  iw="${#BASH_REMATCH[2]}"
  cw="${#BASH_REMATCH[3]}"
  total=$((10#${BASH_REMATCH[3]}))
  for ((n = 1; n <= total; n++)); do
    f="${dir}/${prefix}$(printf '%0*d' "$iw" "$n")-of-$(printf '%0*d' "$cw" "$total").gguf"
    # -e, not -f: an hf download lands as a symlink into objects/; a hand-placed
    # file is a file. Both count, neither is "missing".
    if [[ ! -e "$f" ]]; then
      STRIX_GGUF_MISS="${prefix}$(printf '%0*d' "$iw" "$n")-of-$(printf '%0*d' "$cw" "$total").gguf is missing from ${snap} — the glob found ${#files[@]} file(s) but this set declares ${total}: hf download was interrupted, or a shard was deleted"
      return 1
    fi
  done
  return 0
}

# Newest snapshot directory that holds at least one file for <pattern>, newest
# mtime first — the same ordering gufo-serve.sh will resolve the checkpoint with.
strix_newest_matching_snapshot() {
  local dir="$1" pattern="$2"
  local snap
  while IFS= read -r snap; do
    [[ -n "$snap" ]] || continue
    if compgen -G "${snap}/${pattern}" >/dev/null 2>&1; then
      printf '%s\n' "$snap"
      return 0
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | sed 's/^[0-9.]* //')
  return 1
}

# Map a cache directory to its HF repo id.
#   models--unsloth--Qwen3.8-Flash-Next-GGUF  ->  unsloth/Qwen3.8-Flash-Next-GGUF
strix_hf_repo_from_cache_dir() {
  local base
  base="$(basename "$1")"
  base="${base#models--}"
  printf '%s\n' "${base/--//}"
}

# Newest usable snapshot revision lives further down, behind a `declare -F`
# guard, together with the upstream-revision probe. Defined once, and the
# guarded pair is the one that counts: it also sets STRIX_HF_CACHE_COUNT and
# honours HF_ENDPOINT. (They used to be defined twice, and the unconditional
# earlier pair silently won the guard, which meant the careful version never
# ran — an ordering bug that only showed up as a revision reported from the
# wrong cache.)

# =============================================================================
# DISK HEADROOM
# ==============================================================================

if ! declare -F require_free_space &>/dev/null; then
  require_free_space() {
    local where="${1:-$MODEL_CACHE_DIR}"
    local need_gb="${2:-0}"
    local what="${3:-the download}"
    local avail_kb avail_gb
    avail_kb=$(df -Pk "$where" 2>/dev/null | awk 'NR==2 {print $4}') || {
      warn "could not read free space on $where"
      return 0
    }
    [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 0
    avail_gb=$((avail_kb / 1048576))
    if ((avail_gb < need_gb)); then
      err_msg "Not enough free space on $where: ${avail_gb} GB available, ${need_gb} GB needed for ${what}."
      err_msg "Free up space or point MODEL_CACHE_DIR at a larger filesystem."
      return 1
    fi
    info "Disk headroom on $where: ${avail_gb} GB free (>= ${need_gb} GB needed for ${what})"
  }
fi

# =============================================================================
# WHAT IS STILL PENDING
# =============================================================================

# Work out, in one pass, what has to be fetched.
#
# Options:
#   --model-label <text>   what the weights are called
#   --model-gb <n>         whole GB of weights (0 when unknown)
#   --image-gb <n>         whole GB of engine images
#   --repo-dir <path>      repeatable, one per cache directory
#   --required-from <file> script whose --list-files prints "repo<TAB>pattern"
#   --image-ref <ref>      repeatable, one per engine image
#   --hf-cache <dir>       HF cache root (default $MODEL_CACHE_DIR)
#   --quiet                report the summary, not the per-directory detail
#
# Sets STRIX_NEEDS_MODEL / STRIX_NEEDS_IMAGE / STRIX_PENDING_GB /
# STRIX_PENDING (human summary) / STRIX_RESOLVED ("yes" when the required list
# was readable, "no" when it had to be assumed).
#
# The single-source-of-truth rule: the list of required files comes from the
# wrapper, never from this function. When the wrapper is not on disk yet —
# cold install, which is exactly when the gate runs first — there is nothing
# to ask, so every repo is treated as missing and reported as such. Guessing
# a list here would be the bug that bites later, because the guess and the
# wrapper drift apart and the gate reports a complete snapshot that serve
# then rejects.
strix_resolve_pending_downloads() {
  STRIX_NEEDS_MODEL="no"
  STRIX_NEEDS_IMAGE="no"
  STRIX_PENDING=""
  STRIX_PENDING_GB=0
  STRIX_RESOLVED="yes"

  local label="Weights"
  local model_gb=0
  local image_gb=0
  local hf_cache="${MODEL_CACHE_DIR:-}"
  local required_from=""
  local quiet=0
  local -a repo_dirs=()
  local -a image_refs=()

  local argv=("$@")
  local i=0 step
  while ((i < ${#argv[@]})); do
    step=2
    case "${argv[i]}" in
    --model-label) label="${argv[i + 1]:-$label}" ;;
    --model-gb) model_gb="${argv[i + 1]:-0}" ;;
    --image-gb) image_gb="${argv[i + 1]:-0}" ;;
    --hf-cache) hf_cache="${argv[i + 1]:-$hf_cache}" ;;
    --required-from) required_from="${argv[i + 1]:-}" ;;
    --repo-dir) repo_dirs+=("${argv[i + 1]:-}") ;;
    --image-ref) image_refs+=("${argv[i + 1]:-}") ;;
    # Valueless. Stepping two here — as every other branch does — made --quiet
    # eat the argument after it, so `--quiet --repo-dir X` silently dropped X and
    # the gate reported "nothing to download" about a stack it had never looked
    # at. This parser is the one place where a swallowed option is invisible.
    --quiet)
      quiet=1
      step=1
      ;;
    *) warn "strix_resolve_pending_downloads: ignoring unknown argument '${argv[i]}'" ;;
    esac
    i=$((i + step))
  done

  # ---- weights -------------------------------------------------------------
  local detail=""
  local dir repo
  local -a patterns=()
  if [[ -n "$required_from" && -r "$required_from" ]] \
    && [[ "$(bash "$required_from" --list-files 2>/dev/null | wc -l)" -gt 0 ]]; then
    STRIX_RESOLVED="yes"
  else
    # No wrapper yet (cold install), or the wrapper could not list. Everything
    # is missing by construction — that is the honest answer, not a failure.
    STRIX_RESOLVED="no"
  fi

  for dir in "${repo_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    repo="$(strix_hf_repo_from_cache_dir "$dir")"
    patterns=()
    if [[ "$STRIX_RESOLVED" == "yes" ]]; then
      while IFS=$'\t' read -r line_repo line_pat; do
        [[ "$line_repo" == "$repo" && -n "$line_pat" ]] && patterns+=("$line_pat")
      done < <(bash "$required_from" --list-files 2>/dev/null)
    fi
    if [[ "${#patterns[@]}" -eq 0 ]]; then
      STRIX_NEEDS_MODEL="yes"
      detail+=" ${dir##*/} (no required-file list)"
      continue
    fi
    if path_has_gguf_snapshot "$dir" "${patterns[@]}"; then
      local rev
      rev="$(strix_hf_cache_revision "$dir")"
      detail+=" ${dir##*/} (present @${rev:0:12})"
    else
      STRIX_NEEDS_MODEL="yes"
      # Name the gap, not just the state: "incomplete" on a 4-shard checkpoint
      # is only useful if it also says which shard is missing.
      detail+=" ${dir##*/} (${STRIX_GGUF_MISS:-incomplete})"
    fi
  done

  if [[ "$STRIX_RESOLVED" == "no" && $quiet -eq 0 && "${#repo_dirs[@]}" -gt 0 ]]; then
    info "Weight list not resolvable yet (gufo-prepare.sh not rendered); treating weights as missing"
  fi

  # ---- engine images -------------------------------------------------------
  local ref present=""
  for ref in "${image_refs[@]}"; do
    [[ -n "$ref" ]] || continue
    if docker image inspect "$ref" &>/dev/null; then
      present+=" ${ref##*/}"
    else
      STRIX_NEEDS_IMAGE="yes"
    fi
  done
  if [[ -n "$present" && $quiet -eq 0 ]]; then
    info "Engine image present:${present}"
  fi

  # ---- summary -------------------------------------------------------------
  if [[ "$STRIX_NEEDS_IMAGE" == "yes" ]]; then
    STRIX_PENDING+="engine image "
    STRIX_PENDING_GB=$((STRIX_PENDING_GB + image_gb))
  fi
  if [[ "$STRIX_NEEDS_MODEL" == "yes" ]]; then
    STRIX_PENDING+="${label} "
    STRIX_PENDING_GB=$((STRIX_PENDING_GB + model_gb))
  fi
  STRIX_PENDING="${STRIX_PENDING% }"

  if [[ $quiet -eq 0 ]]; then
    if [[ -z "$STRIX_PENDING" ]]; then
      info "Nothing to download:${detail}"
    elif [[ $STRIX_PENDING_GB -gt 0 ]]; then
      info "Still to download: ${STRIX_PENDING} (~${STRIX_PENDING_GB} GB)${detail}"
    else
      info "Still to download: ${STRIX_PENDING}${detail}"
    fi
  fi
}

# Pull one engine image, skipping the pull when it is already there.
#
# Skip-on-present is not just a nicety: ghcr's anonymous rate limit returns
# "toomanyrequests", which docker pull treats as a failure and therefore
# aborts a run that would otherwise have converged in one second.
strix_pull_engine_image() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || {
    err_msg "strix_pull_engine_image: no image reference given"
    return 1
  }
  if docker image inspect "$ref" &>/dev/null; then
    info "Engine image present: $ref"
    return 0
  fi
  if ! docker pull --quiet "$ref" >/dev/null 2>&1; then
    warn "docker pull $ref failed — trying anyway"
  fi
  if docker image inspect "$ref" &>/dev/null; then
    info "Pulled $ref"
  else
    err_msg "Engine image $ref is not available locally and could not be pulled."
    return 1
  fi
}

# =============================================================================
# LAYOUT AND RENDERING
# =============================================================================

# Render a wrapper (gufo-prepare.sh / gufo-serve.sh) into the service dir.
#
# Fully rendered every run. These files are derived from templates and from
# the task's knobs; keeping operator edits in place would mean the next re-run
# silently ships a wrapper that asks for the wrong file.
#
# envsubst runs as the invoking user into a temp file, then installs via sudo:
# rendering through sudo would evaluate ${...} in a root-owned temp path and,
# worse, could pick up the user's environment where the caller did not intend
# it. Permissions are what llama-swap needs — prepare must be executable
# because the catalog entry's download command invokes it.
# Both renderers share one assertion, because both fail in the same silent way.
#
# envsubst substitutes only what it can see: a name in the list that is not set
# in the environment renders as an empty value, and a name the list omits is left
# alone as a literal. Neither one is an error, so the wrapper still installs and
# the failure surfaces hours later, when llama-swap execs it. The *_DEFAULT
# family matters most: those names exist only to be substituted into a fallback
# (see the task's render block), so one that survives rendering is a template
# that renamed the key and a task that never noticed.
_strix_assert_rendered() {
  local rendered="$1" varlist="${2:-}"
  local name leftover
  for name in $varlist; do
    name="${name#\$\{}"
    name="${name%\}}"
    [[ -v "$name" ]] || warn "render: ${name} is in the envsubst list but not set — it renders empty"
  done
  leftover="$(grep -oE '\$\{[A-Z_][A-Z0-9_]*_DEFAULT\}' "$rendered" 2>/dev/null | sort -u || true)"
  if [[ -n "$leftover" ]]; then
    err_msg "render: $(tr -d '${}\n' <<<"$leftover") survived rendering — the template uses a key"
    err_msg "  the render list does not name. The wrapper would hand the engine that literal"
    err_msg "  instead of the number. Reconcile the template name with the task's export."
    return 1
  fi
  return 0
}

strix_render_wrapper() {
  local template="$1"
  local target="$2"
  local varlist="${3:-}"
  if [[ ! -r "$template" ]]; then
    err_msg "strix_render_wrapper: template not readable: $template"
    return 1
  fi
  # An empty varlist would leave every ${...} in the wrapper literal, which
  # fails only when llama-swap spawns it — hours later. Ask for the list.
  if [[ -z "$varlist" ]]; then
    err_msg "strix_render_wrapper: no envsubst variable list given for $template"
    return 1
  fi
  step "Writing $target"
  local tmp
  tmp="$(mktempfile 2>/dev/null || mktemp)"
  envsubst "${varlist:-}" <"$template" >"$tmp" || {
    err_msg "Rendering $template failed"
    rm -f "$tmp"
    return 1
  }
  if ! _strix_assert_rendered "$tmp" "$varlist"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    info "Unchanged: $target"
    return 0
  fi
  if install -m 0755 "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp"
  elif sudo install -m 0755 "$tmp" "$target"; then
    rm -f "$tmp"
  else
    err_msg "Could not install $target"
    rm -f "$tmp"
    return 1
  fi
  info "Rendered $(basename "$target")"
}

# Converge one serve.env.
#
# Shape of the merge (this is the part that bit TensorFold, so the rule is
# stated explicitly here rather than implied):
#
#   keys the template owns   — re-rendered from the template EVERY run. They
#                              are the script's contract, and a re-run that
#                              "keeps the old value" of PORT would silently
#                              converge onto a port that no longer exists.
#   keys only the operator owns — appended verbatim after our block, once.
#                              An added lever (GUFO_SESSIONS=2 or a future
#                              gufo flag) survives every re-run.
#   comments inside .env     — our block is rewritten wholesale; anything past
#                              the operator block is left alone.
#
# File mode 0600 via install, because serve.env sits next to .env and may
# later carry a token.
if ! declare -F strix_render_serve_env > /dev/null 2>&1; then
  strix_render_serve_env() {
    local template="$1"
    local target="$2"
    local port="$3"
    local varlist="${4:-}"

    if [[ ! -r "$template" ]]; then
      err_msg "strix_render_serve_env: template not readable: $template"
      return 1
    fi
    if [[ -z "$varlist" ]]; then
      err_msg "strix_render_serve_env: no envsubst variable list given for $template"
      return 1
    fi

    local ours
    ours="$(mktempfile serve.env)"
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    if ! envsubst "$varlist" <"$template" >"$ours"; then
      err_msg "Rendering $template failed"
      rm -f -- "$ours"
      return 1
    fi
    # PORT is never in the template's variable list by accident; make it
    # explicit so --port is the single knob.
    if ! grep -qE '^[[:space:]]*PORT[[:space:]]*=' "$ours"; then
      printf 'PORT=%s\n' "$port" >>"$ours"
    fi
    _strix_assert_rendered "$ours" "$varlist" || { rm -f -- "$ours"; return 1; }

    local merged
    merged="$(mktempfile serve.env)"
    cat "$ours" >"$merged"

    if [[ -f "$target" ]]; then
      local -A owned=()
      local line key
      while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
          owned["${BASH_REMATCH[1]}"]=1
        fi
      done <"$ours"

      local extra
      extra="$(mktempfile serve.env)"
      while IFS= read -r line; do
        key=""
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
          key="${BASH_REMATCH[1]}"
          if [[ -n "${owned[$key]+x}" ]]; then
            continue
          fi
        elif [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
          # Comments are not operator-owned: our block rewrites its own
          # comments wholesale, so also keeping the old file's comments
          # stacked a fresh copy of every block in .env on each re-render.
          # Only operator KEY= lines survive.
          continue
        fi
        printf '%s\n' "$line" >>"$extra"
      done <"$target"
      if [[ -s "$extra" ]]; then
        printf '\n# Kept verbatim — added on this box, not owned by the template.\n' >>"$merged"
        cat "$extra" >>"$merged"
      fi
      rm -f -- "$extra"
    fi

    if [[ -f "$target" ]] && cmp -s "$merged" "$target"; then
      rm -f -- "$ours" "$merged"
      info "Unchanged: $target"
      return 0
    fi

    if env_file_write "$target" <"$merged"; then
      info "$( [[ -f "$target" ]] && echo Updated || echo Wrote ) $target"
      rm -f -- "$ours" "$merged"
      return 0
    fi
    err_msg "Could not write $target"
    rm -f -- "$ours" "$merged"
    return 1
  }
fi

# =============================================================================
# LLAMA-SWAP CATALOG
#
# These go through the repo's own tooling (tasks/merge-model-entry.py and
# tasks/sync-models.py), never through jq on llama-swap's config.yaml. That is
# not style: models.yml is the catalog, config.yaml is its generated view, and
# writing config.yaml directly would be re-derived-away by the next
# sync-models.py run — which is the kind of bug that only shows up as "my model
# disappeared".
# =============================================================================

# strix_merge_model_entry <template_file> <catalog> <default_catalog>
#                         <model_name> <force> <envsubst_varlist>
#   Render the catalog entry from the component template and merge it into
#   models.yml additively (replaced only when the rendered entry changed;
#   --force re-writes it).
#
#   <envsubst_varlist> ('${A} ${B} ...', a literal string) must already be
#   exported by the calling script — the helper does not guess which per-task
#   settings a template wants. Copy of tensorfold_merge_model_entry; the header
#   says why the two stacks keep their own copies.
if ! declare -F strix_merge_model_entry > /dev/null 2>&1; then
  strix_merge_model_entry() {
    local template_file="$1" catalog="$2" default_catalog="$3" name="$4"
    local force="${5:-0}" varlist="${6:-}"
    if [[ ! -r "$template_file" ]]; then
      err_msg "strix_merge_model_entry: template not readable: $template_file"
      return 1
    fi
    if [[ -z "$varlist" ]]; then
      err_msg "strix_merge_model_entry: no envsubst variable list given for $template_file"
      return 1
    fi
    local entry
    entry="$(mktempfile models-entry.yml)"
    # shellcheck disable=SC2016  # envsubst expects the literal variable list
    if ! envsubst "$varlist" <"$template_file" >"$entry"; then
      err_msg "Rendering $template_file failed"
      rm -f -- "$entry"
      return 1
    fi
    local -a merge_args=(
      --catalog "$catalog"
      --default "$default_catalog"
      --entry "$entry"
      --name "$name"
      --provider local
    )
    if [[ "$force" == "1" ]]; then
      merge_args+=(--force)
    fi
    if ! python3 "${SCRIPT_DIR:-.}/merge-model-entry.py" "${merge_args[@]}"; then
      err_msg "Could not merge the catalog entry for $name into $catalog"
      rm -f -- "$entry"
      return 1
    fi
    rm -f -- "$entry"
    success "Catalog merged ($name)."
  }
fi

# strix_require_llama_swap_config_writable <config_file>
#   Read-only probe: will the sync that runs AFTER the downloads be able to
#   write llama-swap's config.yaml? The expensive part of a Strix run is the
#   ~95 GB weight pull, so the answer is needed before it, not after it.
#
#   Contract, deliberately the same one sync_models/llama_swap.py's pre-flight
#   applies, so the probe's verdict and the later action's verdict cannot
#   disagree: PASS when the file is missing, or when either the file or its
#   directory is writable. Both writers REPLACE the file (mktemp in the parent
#   dir + os.replace), so directory write access alone is enough, and a cold
#   install must not be blocked over a file that does not exist yet.
if ! declare -F strix_require_llama_swap_config_writable > /dev/null 2>&1; then
  strix_require_llama_swap_config_writable() {
    local config_file="${1:?strix_require_llama_swap_config_writable: no config file}"
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
    err_msg "llama-swap config not writable: ${config_file} — fix ownership/permissions or run as a user with write access, then re-run (e.g.: sudo chown $(id -un):$(id -gn) ${config_file}). Nothing has been downloaded yet: the weights are still upstream, which is the only reason this is cheap to say."
  }
fi

# strix_llama_swap_raise_health_timeout <config_file> <seconds>
#   A ~95 GB first load does not fit in llama-swap's 120 s default, and it
#   would get its container killed mid-read and report that as a startup
#   failure. healthCheckTimeout is a GLOBAL key (llama-swap overwrites every
#   per-model value with it), so this raises the top-level key and nothing else.
#
#   Targeted textual edit rather than a YAML round-trip: config.yaml carries
#   ~250 lines of comments documenting every other option, and a round-trip
#   would silently throw them away.
#
#   Sets STRIX_HEALTH_TIMEOUT_BUMPED=1 when the file changed, so the sync below
#   knows to force the restart that loads the new value.
if ! declare -F strix_llama_swap_raise_health_timeout > /dev/null 2>&1; then
  strix_llama_swap_raise_health_timeout() {
    local config_file="$1" need="${2:?strix_llama_swap_raise_health_timeout: no seconds}"
    STRIX_HEALTH_TIMEOUT_BUMPED=0
    step "Ensuring llama-swap healthCheckTimeout >= ${need}s"
    if [[ ! -f "$config_file" ]]; then
      info "No ${config_file} yet — nothing to raise (run tasks/setup-llama-swap.sh first)."
      return 0
    fi

    if [[ ! -w "$config_file" && ! -w "$(dirname "$config_file")" ]]; then
      err_msg "llama-swap config not writable: ${config_file} — fix ownership/permissions or run as a user with write access, then re-run. Nothing else in ${config_file} was touched."
      return 1
    fi

    # Column 0 is what makes it the global key — an indented occurrence lives
    # inside a model mapping and is not this setting.
    local cur
    cur="$(sed -n 's/^healthCheckTimeout:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$config_file" | tail -1)"
    # Missing key => llama-swap's own default (120 s), not the template's 500.
    cur="${cur:-120}"
    if ((cur >= need)); then
      info "healthCheckTimeout already ${cur} >= ${need} (global key)."
      return 0
    fi

    local tmp
    tmp="$(mktempfile config.yaml)"
    sed -E "s/^healthCheckTimeout:.*/healthCheckTimeout: ${need}/" "$config_file" >"$tmp" \
      || {
      err_msg "could not read ${config_file} — apply the change by hand: sudo sed -i 's/^healthCheckTimeout:.*/healthCheckTimeout: ${need}/' ${config_file}"
      rm -f -- "$tmp"
      return 1
    }
    if ! grep -q "^healthCheckTimeout:" "$tmp"; then
      printf '\nhealthCheckTimeout: %s\n' "$need" >>"$tmp"
    fi
    if ! install -m 644 -o "$(id -un)" -g "$(id -gn)" "$tmp" "$config_file" 2>/dev/null \
      && ! sudo install -m 644 -o "$(id -un)" -g "$(id -gn)" "$tmp" "$config_file"; then
      err_msg "cannot update ${config_file} — apply it by hand and re-run: sudo sed -i 's/^healthCheckTimeout:.*/healthCheckTimeout: ${need}/' ${config_file}"
      rm -f -- "$tmp"
      return 1
    fi
    rm -f -- "$tmp"
    STRIX_HEALTH_TIMEOUT_BUMPED=1
    info "healthCheckTimeout raised ${cur} -> ${need} (global key; comments in ${config_file} preserved)."
  }
fi

# strix_sync_llama_swap <config_file> <llama_swap_port> <container>
#   Merge models.yml into config.yaml and restart only when something changed.
#
#   This discipline is the whole reason the function exists: llama-swap is a
#   live queue, and a restart drops every loaded model and every waiting
#   request. Unchanged therefore means untouched — no restart, no health poll.
#
#   The hash before/after the sync is what makes the healthTimeout raise
#   reliable: sync-models.py restarts only when it has something to write, so
#   when the raise edited the file but the merge did not, the raised value is
#   never loaded unless this function forces the restart itself.
if ! declare -F strix_sync_llama_swap > /dev/null 2>&1; then
  strix_sync_llama_swap() {
    local config_file="$1" port="$2" container="${3:-}"
    step "Syncing llama-swap (tasks/sync-models.py)"
    local before="" after
    if [[ -f "$config_file" ]]; then
      before="$(sha256sum "$config_file" 2>/dev/null | cut -d' ' -f1)"
    fi
    if ! python3 "${SCRIPT_DIR:-.}/sync-models.py"; then
      err_msg "sync-models.py failed — check ${config_file} and re-run."
      return 1
    fi

    if [[ "${STRIX_HEALTH_TIMEOUT_BUMPED:-0}" == "1" && -n "$before" && -f "$config_file" ]]; then
      after="$(sha256sum "$config_file" 2>/dev/null | cut -d' ' -f1)"
      if [[ "$before" == "$after" ]]; then
        info "The raise changed config.yaml but sync-models.py found nothing to write — restarting llama-swap so the new healthCheckTimeout is loaded."
        warn "llama-swap restarts now. If ${container:-the model container} was running, remove it before the next load: docker rm -f ${container:-<container>}"
        sudo systemctl restart llama-swap \
          || error "could not restart llama-swap — run: sudo systemctl restart llama-swap (and re-run this script)."
        local deadline=$((SECONDS + 60))
        until curl -sf --max-time 5 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; do
          ((SECONDS < deadline)) \
            || {
            err_msg "llama-swap did not answer /health within 60 s after the restart — check: systemctl status llama-swap; journalctl -u llama-swap -n 50"
            return 1
          }
          sleep 2
        done
      fi
    fi
    STRIX_HEALTH_TIMEOUT_BUMPED=0
    success "llama-swap in sync."
  }
fi

# strix_stop_running_model <project_dir> <force> <container_name>
#   --force: stop the container that would otherwise keep the old weights
#   mapped while the new ones load. Two engines holding weights is the fastest
#   way to an OOM on a 128 GiB box, so the stop happens before anything is
#   downloaded, and without --force it is said rather than done.
if ! declare -F strix_stop_running_model > /dev/null 2>&1; then
  strix_stop_running_model() {
    local project_dir="$1" force="${2:-0}" container="${3:-}"
    [[ -n "$container" ]] || return 0
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "$container"; then
      if [[ "$force" == "1" ]]; then
        warn "Stopping running model container ${container} (--force)"
        docker stop -t 30 "$container" >/dev/null 2>&1 || true
      else
        warn "Model container ${container} is running. Its weights stay mapped while the new ones load; re-run with --force to stop it first, or expect to need headroom for both."
      fi
    fi
    [[ -d "$project_dir" ]] || return 0
    return 0
  }
fi

# =============================================================================
# ENV READING
# =============================================================================

# strix_env_value <file> <KEY>
#   env_file_get plus the one thing its generic rule cannot do: values in the
#   service .env are double-quoted (the file is sourced, so `KEY=a b` without
#   quotes would run `b` as a command), and a reader that does not strip them
#   compares `"qwen38-27b-gufo"` against `qwen38-27b-gufo` and concludes they
#   are different things.
if ! declare -F strix_env_value > /dev/null 2>&1; then
  strix_env_value() {
    local value
    value="$(env_file_get "$1" "$2" 2>/dev/null)" || return 1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
      value="${value:1:${#value} - 2}"
    fi
    printf '%s\n' "$value"
  }
fi

# =============================================================================
# SIBLING CROSS-CHECK
# =============================================================================

# strix_sibling_port_warning <port> <sibling_env_file...>
#   Each Strix stack binds a fixed host-network port, and the pair (8901, 8902)
#   is only a convention. A collision surfaces at first load, when both
#   containers try to bind — by which point the operator has already waited
#   through two model loads to notice.
#
#   Reads the sibling's own .env PORT through strix_env_value, so a deliberately
#   re-set port is honoured and a quoted one is compared unquoted. Never fatal, because re-setting a port is the
#   operator's business; saying it once, at install time, is the point.
# strix_sibling_container_warning <model_name> <sibling_env_file>
#   "Who else is on this box?" — printed as one status line, not an alarm.
#
#   The two Strix stacks are separate installs that share one llama-swap, one
#   host network and one GPU aperture, so the interesting question is not only
#   "do the ports match" (handled by strix_sibling_port_warning) but "what is
#   actually installed next door". Without this line, --check on a box with both
#   stacks answers one model and silently leaves the operator to discover the
#   other one the way everything is discovered: at first load, slowly.
#
#   A missing sibling prints nothing. That is the point: a box with one stack
#   must not read as though something is wrong.
if ! declare -F strix_sibling_container_warning > /dev/null 2>&1; then
  strix_sibling_container_warning() {
    local model="$1" env_file="$2"
    [[ -f "$env_file" ]] || return 0
    local peer_port peer_container peer_model
    peer_port="$(strix_env_value "$env_file" PORT || true)"
    peer_container="$(strix_env_value "$env_file" CONTAINER_NAME || true)"
    peer_model="$(strix_env_value "$env_file" GUFO_MODEL_NAME || true)"
    peer_hint=''
    [[ -n "${peer_container:-}" ]] && peer_hint='(load one at a time — see --help)'
    echo -e "  ${BOLD}Sibling:${RESET}     ${peer_model:-another Gufo stack} at ${env_file%/.env}"
    echo -e "                   port ${peer_port:-?} / container ${peer_container:-?}  ${peer_hint}"
    if [[ -n "${peer_model:-}" && "$peer_model" == "$model" ]]; then
      warn "Both stacks publish the same model id (${model}) — llama-swap's routing will be ambiguous. Give one side a different id or alias."
    fi
    return 0
  }
fi

if ! declare -F strix_sibling_port_warning > /dev/null 2>&1; then
  strix_sibling_port_warning() {
    local port="$1"
    shift
    local env_file peer
    for env_file in "$@"; do
      [[ -f "$env_file" ]] || continue
      peer="$(strix_env_value "$env_file" PORT || true)"
      if [[ "$peer" == "$port" ]]; then
        warn "${env_file} also sets port ${port} — the two Gufo containers collide on the host network at first load. Give one side another port (GUFO_PORT / GUFO_27B_PORT), then re-run both tasks."
      fi
    done
    return 0
  }
fi

# =============================================================================
# STATE FILE UPDATES
# =============================================================================

# strix_state_write <file> <KEY=VALUE>...
#   Upsert keys into the service directory's KEY=value state file, keeping
#   every other line, and install the result at mode 600.
#
#   Needed because helpers.sh's env_file_write takes its content on stdin and
#   replaces the whole file: using it directly for one key would quietly
#   delete every other record on the file — including the revision records that
#   make --check able to answer "what did this install actually pull?".
#
#   Order-preserving: an existing key is rewritten in place, a new key is
#   appended. A state file is read by humans as well as by env_file_get.
if ! declare -F strix_state_write > /dev/null 2>&1; then
  strix_state_write() {
    local file="$1"
    shift
    local -A wanted=() emitted=()
    local pair key tmp line
    for pair in "$@"; do
      key="${pair%%=*}"
      wanted["$key"]="${pair#*=}"
      emitted["$key"]=0
    done

    tmp="$(mktempfile state)"
    if [[ -f "$file" ]]; then
      while IFS= read -r line; do
        key=""
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
          key="${BASH_REMATCH[1]}"
        fi
        if [[ -n "$key" && -n "${wanted[$key]+x}" ]]; then
          printf '%s=%s\n' "$key" "${wanted[$key]}" >>"$tmp"
          emitted["$key"]=1
        else
          printf '%s\n' "$line" >>"$tmp"
        fi
      done <"$file"
    fi
    for key in "${!wanted[@]}"; do
      if [[ "${emitted[$key]}" == "0" ]]; then
        printf '%s=%s\n' "$key" "${wanted[$key]}" >>"$tmp"
      fi
    done

    env_file_write "$file" <"$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
    rm -f -- "$tmp"
    return 0
  }
fi


# strix_hf_cache_revision <cache_dir>
#   Revision a local cache entry resolves to right now: the newest
#   snapshots/<sha>/ that actually holds weights, so a half-fetched directory
#   cannot win the newest-first tie. .git is unreliable across hf versions, and
#   a GGUF repo often has no config.json, so weights decide.
if ! declare -F strix_hf_cache_revision > /dev/null 2>&1; then
  strix_hf_cache_revision() {
    local dir="$1"
    STRIX_HF_CACHE_REVISION=""
    STRIX_HF_CACHE_COUNT=0
    [[ -d "${dir}/snapshots" ]] || return 1
    local -a snaps=() usable=()
    mapfile -t snaps < <(find "${dir}/snapshots" -mindepth 1 -maxdepth 1 -type d \
      -printf '%T@\t%f\n' 2>/dev/null | sort -k1,1nr -k2,2)
    (( ${#snaps[@]} > 0 )) || return 1
    local line name
    for line in "${snaps[@]}"; do
      name="$(printf '%s\n' "$line" | cut -f2)"
      # A checkpoint may be a file in the snapshot root (27B) or a directory of
      # shards inside it (Flash-Next), so "has weights" has to look both ways.
      # Root-only used to mean every Flash-Next cache looked empty and the
      # revision fell back to whatever directory was newest, half-fetched or not.
      if compgen -G "${dir}/snapshots/${name}/*.gguf" >/dev/null 2>&1 ||
        compgen -G "${dir}/snapshots/${name}/*/*.gguf" >/dev/null 2>&1; then
        usable+=("$line")
      fi
    done
    (( ${#usable[@]} > 0 )) && snaps=("${usable[@]}")
    name="$(printf '%s\n' "${snaps[0]}" | cut -f2)"
    [[ -n "$name" ]] || return 1
    STRIX_HF_CACHE_REVISION="$name"
    STRIX_HF_CACHE_COUNT="${#snaps[@]}"
    return 0
  }
fi

# strix_hf_upstream_revision <repo_id>
#   What "main" resolves to right now. Best-effort by construction: an empty
#   value means UNKNOWN (offline, gated, mirror), never agreement.
if ! declare -F strix_hf_upstream_revision > /dev/null 2>&1; then
  strix_hf_upstream_revision() {
    local id="$1"
    STRIX_HF_UPSTREAM_REVISION=""
    local body
    if command -v curl >/dev/null 2>&1; then
      body="$(curl -sfL --max-time 10 "${HF_ENDPOINT:-https://huggingface.co}/api/models/${id}" 2>/dev/null || true)"
    fi
    if [[ -n "$body" ]]; then
      STRIX_HF_UPSTREAM_REVISION="$(printf '%s' "$body" | jq -r '.sha // empty' 2>/dev/null || true)"
    fi
    [[ -n "$STRIX_HF_UPSTREAM_REVISION" ]]
  }
fi

# strix_checkpoint_revision_record <state_file> <repo_id> <cache_dir>
#   Record the revision installed, keyed by repo, in the service dir's
#   KEY=value state file — so install and --check read the same thing.
if ! declare -F strix_checkpoint_revision_record > /dev/null 2>&1; then
  strix_checkpoint_revision_record() {
    local state_file="$1" repo="$2" cache_dir="$3"
    local now=""
    strix_hf_cache_revision "$cache_dir" && now="$STRIX_HF_CACHE_REVISION"
    if [[ -z "$now" ]]; then
      warn "checkpoint revision for ${repo}: no local snapshot resolved — nothing recorded"
      return 0
    fi
    local key="REVISION_${repo//[\/.-]/_}"
    local prev
    prev="$(strix_env_value "$state_file" "$key" || true)"
    if ! strix_state_write "$state_file" "${key}=${now}"; then
      warn "could not record checkpoint revision in ${state_file}"
      return 0
    fi
    if [[ -n "$prev" && "$prev" != "$now" ]]; then
      info "checkpoint revision for ${repo}: ${prev:0:12} -> ${now:0:12}"
    else
      info "checkpoint revision for ${repo}: ${now:0:12} (recorded)"
    fi
  }
fi

# strix_checkpoint_revision_recheck <state_file> <repo_id>...
#   Did upstream move since we installed? Warning only, always. A cached
#   snapshot that still works must converge, and refusing to run over a drift
#   the operator did not ask for is worse than the drift.
if ! declare -F strix_checkpoint_revision_recheck > /dev/null 2>&1; then
  strix_checkpoint_revision_recheck() {
    local state_file="$1"
    shift
    (( $# > 0 )) || return 0
    local repo key recorded upstream
    for repo in "$@"; do
      key="REVISION_${repo//[\/.-]/_}"
      recorded="$(strix_env_value "$state_file" "$key" || true)"
      [[ -n "$recorded" ]] || continue
      strix_hf_upstream_revision "$repo" || true
      upstream="$STRIX_HF_UPSTREAM_REVISION"
      if [[ -z "$upstream" ]]; then
        info "checkpoint revision for ${repo}: installed ${recorded:0:12}, upstream unknown (offline or gated)"
      elif [[ "$upstream" != "$recorded" ]]; then
        warn "checkpoint revision for ${repo} drifted: installed ${recorded:0:12}, upstream main is ${upstream:0:12}. The cached copy is used as-is — delete its snapshot directory under the cache dir to take the newer one."
      else
        info "checkpoint revision for ${repo}: ${recorded:0:12} (matches upstream)"
      fi
    done
  }
fi

# =============================================================================
# ENGINE VERSION
# =============================================================================

# strix_record_engine_version <state_file> <image_ref>
#   Which engine build this install last ran against, so --check can answer
#   "did the image change underneath us?" without having to run anything.
#
#   Two records: the reference (and the image id the pull resolved) plus the
#   engine's own version string. The string is the one that drifts when a tag is
#   re-pointed, which is why it is probed rather than inferred from the tag.
#
#   The probe starts a throwaway container, so it is best-effort, skippable
#   with STRIX_ENGINE_VERSION_PROBE=0, and never fails a run: a stack that
#   cannot report its own version number is still a working stack.
if ! declare -F strix_record_engine_version > /dev/null 2>&1; then
  strix_record_engine_version() {
    local state_file="$1" ref="$2"
    local version="" image_id=""
    if [[ "${STRIX_ENGINE_VERSION_PROBE:-1}" == "1" ]] \
      && docker image inspect "$ref" >/dev/null 2>&1; then
      image_id="$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true)"
      version="$(timeout 180 docker run --rm --name "kwisatz-engine-probe-$$" \
        "$ref" gufo --version 2>/dev/null | head -1 | tr -d '\r' || true)"
    fi
    if [[ -n "$version" ]]; then
      strix_state_write "$state_file" "ENGINE_VERSION=${version}" || true
      info "engine version recorded: ${version}"
    else
      warn "engine version probe returned nothing — keeping the last known value (STRIX_ENGINE_VERSION_PROBE=0 skips the probe)"
    fi
    strix_state_write "$state_file" \
      "ENGINE_REF=${ref}" \
      "ENGINE_IMAGE_ID=${image_id}" \
      "ENGINE_VERSION_RECORDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      || warn "could not write the engine version record to ${state_file}"
  }
fi

# strix_engine_version_drift <state_file> <image_ref>
#   Compare the recorded engine build against what is on disk now.
if ! declare -F strix_engine_version_drift > /dev/null 2>&1; then
  strix_engine_version_drift() {
    local state_file="$1" ref="${2:-}"
    [[ -f "$state_file" ]] || return 0
    local recorded recorded_id now_id
    recorded="$(strix_env_value "$state_file" ENGINE_REF || true)"
    recorded_id="$(strix_env_value "$state_file" ENGINE_IMAGE_ID || true)"
    if [[ -z "$recorded" ]]; then
      info "engine version: not recorded yet (the install step records it)"
      return 0
    fi
    if [[ "$recorded" != "$ref" ]]; then
      warn "engine reference drifted: recorded ${recorded}, this run uses ${ref}"
    fi
    if [[ -n "$recorded_id" ]] && docker image inspect "$ref" >/dev/null 2>&1; then
      now_id="$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true)"
      if [[ -n "$now_id" && "$now_id" != "$recorded_id" ]]; then
        warn "engine image was re-pulled since it was recorded (${recorded_id:0:19} -> ${now_id:0:19}); the version string in ${state_file} is stale."
      else
        info "engine image unchanged (${recorded_id:0:19})"
      fi
    fi
  }
fi

# =============================================================================
# SMOKE TEST
# =============================================================================

# One minimal chat completion against one endpoint, given a request body.
#
# Split out because a timeout must be able to name which side timed out.
# Inference latency is minutes; a container that is up is not a container that
# answers, and if the helper is opaque the operator cannot tell whether the
# engine or the proxy failed.
# llama-swap can be configured with `apiKeys:` in its config.yaml. It then
# rejects every request that carries no key — except /health, which answers
# unauthenticated. That combination is what makes this a silent failure: "the
# proxy is reachable" stays green, /running, /v1/models and
# /v1/chat/completions all answer 401, and a smoke test polls a deadline it can
# never satisfy while reading it as a slow load.
#
# Resolved once per run, used in a header only: the key is never printed and
# never substituted into a generated file, per the secrets rule. LLAMA_SWAP_API_KEY
# wins; otherwise the first apiKeys entry of the live llama-swap config.
_strix_llama_swap_auth() {
  local key="${LLAMA_SWAP_API_KEY:-}"
  if [[ -z "$key" ]]; then
    local cfg="${LLAMA_SWAP_CONFIG:-${LLAMA_SWAP_DIR:-/srv/llama-swap}/config/config.yaml}"
    if [[ -r "$cfg" ]] && command -v python3 >/dev/null 2>&1; then
      key="$(python3 - "$cfg" 2>/dev/null <<'PY' || true
import sys
import yaml

try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
keys = cfg.get("apiKeys") or []
print(keys[0] if keys else "")
PY
)"
    fi
  fi
  _STRIX_AUTH_ARGS=()
  [[ -n "$key" ]] && _STRIX_AUTH_ARGS=(-H "Authorization: Bearer ${key}")
  _STRIX_AUTH_DONE=1
  return 0
}

# curl with the proxy's key attached when it has one. The header arguments go
# first so the caller's own flags stay readable; a box without apiKeys gets the
# plain curl it used to get.
_strix_curl() {
  [[ -n "${_STRIX_AUTH_DONE:-}" ]] || _strix_llama_swap_auth
  curl ${_STRIX_AUTH_ARGS[@]+"${_STRIX_AUTH_ARGS[@]}"} "$@"
}

_strix_chat_completion() {
  local url="$1"
  local body="$2"
  local timeout="${3:-120}"
  _strix_curl -sf --max-time "$timeout" \
    -H 'Content-Type: application/json' \
    -d "$body" \
    "${url}/v1/chat/completions" 2>/dev/null
}

# The request the smoke test sends.
#
# Three details, all of them load-bearing, and all of them copied from the
# TensorFold helpers that have been doing this against the same model family:
#
#   chat_template_kwargs.enable_thinking=false — Qwen3.8 returns its reasoning
#     in `reasoning_content` and only the answer in `message.content`, so with
#     the engine's default thinking mode a 32-token budget can produce HTTP 200
#     and an empty content field. That is a working engine answering "no" to the
#     only question a smoke test asks, which is the worst kind of failure: it
#     reports a good install as broken, on every install, forever.
#   temperature 0 — greedy, so the answer does not depend on a sampler the
#     engine might not have agreed to.
#   32 tokens on "Reply with OK." — big enough to prove the whole path, small
#     enough that no long-context bug can be involved.
_strix_smoke_body() {
  printf '{"model":"%s","max_tokens":32,"temperature":0,"chat_template_kwargs":{"enable_thinking":false},"messages":[{"role":"user","content":"Reply with OK."}]}' "$1"
}

# True when the response carries a non-empty assistant message.
#
# Checking the payload and not just the HTTP status is the point: 200 with an
# empty choices array is a real thing that happens to a container that is
# running and broken.
_strix_answers() {
  local json="${1:-}"
  [[ -n "$json" ]] || return 1
  local content
  content="$(jq -r '.choices[0].message.content // empty' <<<"$json" 2>/dev/null)" \
    || return 1
  [[ -n "$content" ]]
}

# Wait until the engine's own readiness answer.
#
# This is the Strix-specific part of the smoke test, and it is the reason the
# tensorfold shape needs one change: Gufo binds its port *before* the weights
# are resident, so a TCP or /health probe goes green while the model is still
# being mapped. /v1/models is the endpoint that means "I will answer you".
#
#   strix_wait_for_engine_readiness <url> <timeout> [<model-id>]
#
# When <model-id> is given, the id must appear in the listing — that catches
# the "wrong model is served" case that a bare 200 would pass.
strix_wait_for_engine_readiness() {
  local url="$1"
  local timeout="${2:-120}"
  local model="${3:-}"
  local i body
  for ((i = 0; i < timeout; i += 2)); do
    body="$(curl -sf --max-time 10 "${url}/v1/models" 2>/dev/null || true)"
    if [[ -n "$body" ]]; then
      if [[ -z "$model" ]]; then
        return 0
      fi
      if jq -e --arg m "$model" '[.data[]?.id] | index($m)' \
        <<<"$body" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

# End-to-end smoke test.
#
# The two-endpoint distinction is what makes a failure actionable:
#
#   127.0.0.1:<proxy-port>/v1/chat/completions  -> llama-swap is on the path
#   127.0.0.1:<engine-port>/v1/chat/completions -> the engine answers by itself
#
# A timeout on the first is the proxy's problem; on the second it is the
# engine's. Reporting both together is reporting nothing.
#
#   strix_smoke_test <name> <proxy-url> <engine-port> <timeout>
#
# Shape, and the reason for it: the trigger runs in the background while a
# bounded poll watches. The first request through llama-swap IS the model load,
# and a 115 GB checkpoint holds that request open for minutes — a synchronous
# trigger would sit inside curl for its own whole timeout, and a hung proxy and
# a slow load would be the same message.
strix_smoke_test() {
  local model_name="$1"
  local proxy_url="$2"
  local engine_port="$3"
  local timeout="${4:-600}"

  step "Smoke test"

  # Ask the proxy once, authenticated, before anything else. /health is exempt
  # from apiKeys, so this is the only cheap probe that distinguishes "the model
  # is slow to load" from "no request has been accepted at all" — and that
  # difference is ten minutes of waiting for nothing.
  local code
  code="$(_strix_curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "${proxy_url}/v1/models" 2>/dev/null || true)"
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    err_msg "llama-swap answered HTTP ${code} on ${proxy_url}/v1/models: it is configured"
    err_msg "with apiKeys and this run has no key to send, so no request — including the"
    err_msg "one that would load the model — has been accepted. Run the task once with:"
    err_msg "  LLAMA_SWAP_API_KEY=<the key in ${LLAMA_SWAP_DIR:-/srv/llama-swap}/config/config.yaml> $0"
    return 1
  fi

  local body
  body="$(_strix_smoke_body "$model_name")"
  local deadline=$(( $(date +%s) + timeout ))

  local trigger
  trigger="$(mktempfile smoke-trigger.json)"
  _strix_curl -s --max-time $((timeout + 120)) \
    -H 'Content-Type: application/json' -d "$body" \
    "${proxy_url}/v1/chat/completions" >"$trigger" 2>/dev/null &
  local trigger_pid=$!

  # Is it loaded — by llama-swap's /running, or by the engine's own endpoint?
  # /v1/models and not /health because Gufo binds the port before the weights
  # are resident, and it must list THIS id: "a model is up" is not the question.
  local loaded=0 body_resp=""
  while (($(date +%s) < deadline)); do
    if _strix_curl -sf --max-time 10 "http://127.0.0.1:${LLAMA_SWAP_PORT:-8080}/running" 2>/dev/null |
      grep -qi "$model_name"; then
      loaded=1
      break
    fi
    if body_resp="$(curl -sf --max-time 10 "http://127.0.0.1:${engine_port}/v1/models" 2>/dev/null)" \
      && jq -e --arg m "$model_name" '[.data[]?.id] | index($m)' <<<"$body_resp" >/dev/null 2>&1; then
      loaded=1
      break
    fi
    # The trigger came back by itself — answered, or failed fast. Its response
    # is the evidence; waiting for nothing is not information.
    if ! kill -0 "$trigger_pid" 2>/dev/null; then
      loaded=1
      break
    fi
    sleep 5
  done
  if [[ "$loaded" != "1" ]]; then
    warn "Nothing reported ${model_name} as loaded within ${timeout}s — asking both sides anyway"
  fi

  # The assertion. Retry until the deadline: a response that arrived before the
  # load finished is not a failure, it is the wrong moment.
  local json=""
  while :; do
    if [[ -s "$trigger" ]]; then
      json="$(cat "$trigger" 2>/dev/null || true)"
      if _strix_answers "$json"; then
        break
      fi
    fi
    if (($(date +%s) >= deadline)); then
      break
    fi
    json="$(_strix_chat_completion "$proxy_url" "$body" 120)"
    if _strix_answers "$json"; then
      break
    fi
    sleep 5
  done

  kill "$trigger_pid" 2>/dev/null || true
  wait "$trigger_pid" 2>/dev/null || true
  rm -f -- "$trigger"

  if _strix_answers "$json"; then
    info "Smoke test passed — ${model_name} answered through llama-swap"
    return 0
  fi

  # Which side broke. This is what separates a smoke test that helps from one
  # that repeats that something failed.
  local direct
  direct="$(_strix_chat_completion "http://127.0.0.1:${engine_port}" "$body" 120)"
  if _strix_answers "$direct"; then
    warn "Smoke test failed: the engine answers directly, the proxy path did not — check llama-swap logs"
    warn "  journalctl -u llama-swap --no-pager -n 50"
  else
    warn "Smoke test failed: ${model_name} gave no assistant answer on port ${engine_port}"
    warn "  docker logs $(docker ps --filter publish="${engine_port}" --format '{{.Names}}' | head -1)"
    warn "  and did the load itself finish:  docker ps -a --filter name=${model_name}"
  fi
  return 1
}

# Is llama-swap actually up?
#
# Distinguishes three states because "not reachable" is not one state and the
# fix differs completely: installed but stopped (start it), never installed
# (run setup-llama-swap.sh), running but unhealthy (check its logs).
strix_require_llama_swap_up() {
  local model="${1:-}"
  local port="${2:-${LLAMA_SWAP_PORT:-8080}}"
  local health_url="http://127.0.0.1:${port}/health"
  local models_url="http://127.0.0.1:${port}/v1/models"
  if ! curl -sf --max-time 5 "$health_url" >/dev/null 2>&1; then
    if ss -tlnp 2>/dev/null | grep -q ":${port}"; then
      err_msg "llama-swap port ${port} is open but /health is not answering."
      err_msg "Check: journalctl -u llama-swap --no-pager -n 50"
      return 1
    fi
    err_msg "llama-swap is not running (nothing listens on port ${port})."
    err_msg "Install it first:  ${SCRIPT_DIR:-.}/setup-llama-swap.sh"
    return 1
  fi
  info "llama-swap is reachable ($health_url)"
  # The catalog half. A restart or a failed sync can leave llama-swap healthy
  # and simply not knowing about this model, and "healthy" without the id is
  # the exact state that makes --skip-smoke useless as a gate.
  if [[ -n "$model" ]]; then
    local body
    if body="$(_strix_curl -sf --max-time 5 "$models_url" 2>/dev/null)" \
      && jq -e --arg m "$model" '[.data[]?.id] | index($m)' <<<"$body" >/dev/null 2>&1; then
      info "llama-swap lists ${model}"
    else
      err_msg "llama-swap is healthy but does not list ${model} in ${models_url}."
      err_msg "The entry did not make it into config.yaml — re-run and check the sync output, or:"
      err_msg "  grep -n '${model}' ${LLAMA_SWAP_DIR:-/srv/llama-swap}/config/config.yaml"
      return 1
    fi
  fi
  return 0
}

# =============================================================================
# PREFLIGHT
# =============================================================================

# Everything that can fail before a single byte is written, in the order that
# makes the cheapest failure first.
#
# The order is not arbitrary: docker missing is cheap, the hardware gate is
# cheap, the tuning state is cheap, and the 95 GB download is the most
# expensive thing this stack can do. Reporting the expensive one first is how
# a five-second problem turns into an hour of wasted bandwidth.
strix_preflight_sanity() {
  step "Preflight sanity checks"
  strix_require_docker
  strix_require_tooling
  strix_require_llama_swap
  strix_require_strix_hal "${1:-this stack}"
  strix_require_tuning "${1:-this stack}"
  strix_require_locked_memory
  strix_require_devices
  strix_warn_swap
  success "Preflight passed"
}

# Validate the serving settings a task is about to write.
if ! declare -F strix_validate_serving_settings > /dev/null 2>&1; then
  strix_validate_serving_settings() {
    local port="${1:?strix_validate_serving_settings: no port}"
    local proxy_port="${2:-${LLAMA_SWAP_PORT:-8080}}"
    validate_port "$port" || return 1
    validate_port "$proxy_port" || return 1
    if [[ "$port" == "$proxy_port" ]]; then
      err_msg "Serving port ${port} is the same as llama-swap's port — the engine would compete with the proxy that fronts it."
      return 1
    fi
  }
fi

# =============================================================================
# STATUS (for --check)
#
# Read-only by construction: --check reports what IS true about this machine
# today, never what the task thinks it should be. A --check that writes would
# turn a diagnostic into a second install path, and the two would drift.
# =============================================================================

# strix_status_gpu
if ! declare -F strix_status_gpu > /dev/null 2>&1; then
  strix_status_gpu() {
    # || true: --check must print what it found, not abort on a machine that
    # fails the gate. Every branch below reads the published globals instead.
    strix_hal_gpu || true
    # --check must be able to print this without running any gate first.
    STRIX_KERNEL_HAVE="${STRIX_KERNEL_HAVE:-$(strix_kernel_release)}"
    STRIX_KERNEL_WANT="${STRIX_KERNEL_WANT:-${STRIX_MIN_KERNEL:-6.18.9}}"
    if [[ -z "${STRIX_KERNEL_OK:-}" && -n "$STRIX_KERNEL_HAVE" ]]; then
      if strix_version_ge "$STRIX_KERNEL_WANT" "$STRIX_KERNEL_HAVE"; then
        STRIX_KERNEL_OK=1
      else
        STRIX_KERNEL_OK=0
      fi
    fi
    if [[ -z "${STRIX_RAM_TOTAL_GIB:-}" ]]; then
      STRIX_RAM_TOTAL_GIB="$(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo 2>/dev/null)"
    fi
    if [[ -n "$STRIX_RAM_TOTAL_GIB" ]]; then
      if ((STRIX_RAM_TOTAL_GIB >= ${STRIX_MIN_RAM_GIB:-125})); then
        STRIX_RAM_OK=1
      else
        STRIX_RAM_OK=0
      fi
    fi
    if [[ "${STRIX_GPU_OK:-0}" == "1" ]]; then
      echo -e "  ${BOLD}GPU:${RESET}         ${GREEN}${STRIX_GPU_NAME:-gfx1151}${RESET} (${STRIX_PCI_ID:-PCI})"
    else
      echo -e "  ${BOLD}GPU:${RESET}         ${RED}no gfx1151 device${RESET} (expected a device whose KFD node reports GC 11.5.1, bound to amdgpu)"
    fi
    echo -e "  ${BOLD}Kernel:${RESET}      ${STRIX_KERNEL_HAVE:-?} ${BOLD}/${RESET} ${STRIX_KERNEL_WANT:-?} required   $(
      [[ "${STRIX_KERNEL_OK:-0}" == "1" ]] && echo "${GREEN}ok${RESET}" || echo "${RED}too old${RESET}")"
    echo -e "  ${BOLD}RAM:${RESET}           ${STRIX_RAM_TOTAL_GIB:-?} GiB total ($(
      [[ "${STRIX_RAM_OK:-0}" == "1" ]] && echo "${GREEN}ok${RESET}" || echo "${YELLOW}below the ${STRIX_MIN_RAM_GIB:-125} GiB floor${RESET}"))"
  }
fi

# strix_status_gtt
if ! declare -F strix_status_gtt > /dev/null 2>&1; then
  strix_status_gtt() {
    strix_gtt_state "${1:-${GPU_RESERVE_GIB:-120}}" || true
    local col=GREEN word="$STRIX_GTT"
    case "$STRIX_GTT" in
    active) col=GREEN ;;
    inactive) col=RED ;;
    mismatched) col=YELLOW ;;
    *) col=RED ;;
    esac
    echo -e "  ${BOLD}GPU reserve:${RESET} ${!col}${word}${RESET}  (expected ${STRIX_RESERVE_EXPECTED_GIB} GiB)"
    echo -e "                   ${STRIX_GTT_DETAIL}"
    if [[ "$STRIX_REBOOT_REQUIRED" == "1" ]]; then
      echo -e "                   ${YELLOW}reboot required${RESET} — sudo update-grub && sudo reboot"
    fi
  }
fi

# strix_status_locked_memory
if ! declare -F strix_status_locked_memory > /dev/null 2>&1; then
  strix_status_locked_memory() {
    local pid line value unit
    pid="$(pgrep -x dockerd 2>/dev/null | head -1 || true)"
    if [[ -z "$pid" ]]; then
      echo -e "  ${BOLD}Memlock:${RESET}     ${YELLOW}dockerd not found${RESET}"
      return 0
    fi
    line="$(grep -m1 'Max locked memory' "/proc/${pid}/limits" 2>/dev/null || true)"
    value="$(awk '{print $(NF-2)}' <<<"$line")"
    unit="$(awk '{print $(NF-1)}' <<<"$line")"
    if [[ "$value" == "unlimited" || "$value" == "infinity" ]]; then
      echo -e "  ${BOLD}Memlock:${RESET}     ${GREEN}unlimited${RESET} (dockerd)"
    else
      echo -e "  ${BOLD}Memlock:${RESET}     ${YELLOW}${value:-?} ${unit:-?}${RESET} (dockerd — needs unlimited to load a model this size)"
    fi
  }
fi

# strix_status_swap
if ! declare -F strix_status_swap > /dev/null 2>&1; then
  strix_status_swap() {
    local zram=0 dev
    while read -r dev; do
      [[ "$dev" == "/dev/zram"* ]] && zram=1
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)
    if [[ $zram -eq 1 ]]; then
      echo -e "  ${BOLD}Swap:${RESET}        ${YELLOW}zram active${RESET} — the model will page into compressed RAM; disable it"
    else
      echo -e "  ${BOLD}Swap:${RESET}        ${GREEN}no zram${RESET}"
    fi
  }
fi

# strix_status_devices
if ! declare -F strix_status_devices > /dev/null 2>&1; then
  strix_status_devices() {
    local out="" dev
    for dev in /dev/kfd /dev/dri; do
      [[ -e "$dev" ]] && out+="${dev} " || out+="${YELLOW}${dev} missing${RESET} "
    done
    echo -e "  ${BOLD}Devices:${RESET}     ${out% }"
  }
fi

# strix_status_weights <cache_dir>...
if ! declare -F strix_status_weights > /dev/null 2>&1; then
  strix_status_weights() {
    local dir repo rev
    for dir in "$@"; do
      repo="$(strix_hf_repo_from_cache_dir "$dir")"
      if strix_hf_cache_revision "$dir"; then
        rev="$STRIX_HF_CACHE_REVISION"
        echo -e "  ${BOLD}Weights:${RESET}     ${dir} ${GREEN}present${RESET} @${rev:0:12}"
        echo -e "                   ${repo}"
      else
        echo -e "  ${BOLD}Weights:${RESET}     ${YELLOW}not cached${RESET} — ${dir} (bash gufo-prepare.sh downloads it)"
      fi
    done
  }
fi

# strix_status_engine_image <ref>
if ! declare -F strix_status_engine_image > /dev/null 2>&1; then
  strix_status_engine_image() {
    local ref="$1"
    if docker image inspect "$ref" >/dev/null 2>&1; then
      echo -e "  ${BOLD}Engine:${RESET}      ${GREEN}${ref}${RESET}"
    else
      echo -e "  ${BOLD}Engine:${RESET}      ${YELLOW}not pulled${RESET} — ${ref} (the install step pulls it)"
    fi
  }
fi

# strix_status_catalog <models.yml> <model_name>
if ! declare -F strix_status_catalog > /dev/null 2>&1; then
  strix_status_catalog() {
    local catalog="$1" name="$2"
    if [[ ! -f "$catalog" ]]; then
      echo -e "  ${BOLD}Catalog:${RESET}     ${YELLOW}${catalog} does not exist${RESET} (run tasks/sync-models.py)"
      return 0
    fi
    if grep -qE "^[[:space:]]*-?[[:space:]]*name:[[:space:]]*${name}[[:space:]]*$" "$catalog" 2>/dev/null; then
      echo -e "  ${BOLD}Catalog:${RESET}     ${GREEN}${name}${RESET} in $(basename "$catalog")"
    else
      echo -e "  ${BOLD}Catalog:${RESET}     ${YELLOW}no entry for ${name}${RESET} in $(basename "$catalog")"
    fi
  }
fi

# strix_status_llama_swap_entry <config.yaml> <model_name>
if ! declare -F strix_status_llama_swap_entry > /dev/null 2>&1; then
  strix_status_llama_swap_entry() {
    local config="$1" name="$2"
    if [[ ! -r "$config" ]]; then
      echo -e "  ${BOLD}llama-swap:${RESET}  ${YELLOW}${config} not readable${RESET}"
      return 0
    fi
    # sync-models.py writes the model as a MAP KEY (`qwen3.8-27b-gufo:`), not
    # as a `name:` field; checking only for `name:` reports a live entry as
    # missing, which sends operators on a pointless re-run. Accept both.
    if grep -qE "name:[[:space:]]*${name}[[:space:]]*$" "$config" 2>/dev/null ||
      grep -qE "^[[:space:]]*${name}:[[:space:]]*(\{|$)" "$config" 2>/dev/null; then
      echo -e "  ${BOLD}llama-swap:${RESET}  ${GREEN}entry in config.yaml${RESET}"
    else
      echo -e "  ${BOLD}llama-swap:${RESET}  ${YELLOW}no entry in config.yaml${RESET} (re-run the setup task)"
    fi
  }
fi

# strix_status_llama_swap_writable <config.yaml>
if ! declare -F strix_status_llama_swap_writable > /dev/null 2>&1; then
  strix_status_llama_swap_writable() {
    local config="$1"
    if [[ ! -e "$config" ]]; then
      # No file yet is the normal state before the first sync; calling it
      # "read-only" sends people to a chown they do not need.
      echo -e "  ${BOLD}Config:${RESET}      ${YELLOW}${config} does not exist yet${RESET} (the first sync creates it)"
    elif [[ -w "$config" || -w "$(dirname "$config")" ]]; then
      echo -e "  ${BOLD}Config:${RESET}      ${GREEN}writable${RESET} (${config})"
    else
      echo -e "  ${BOLD}Config:${RESET}      ${RED}read-only${RESET} (${config} — sudo chown $(id -un):$(id -gn) ${config})"
    fi
  }
fi

# strix_status_container <name>
if ! declare -F strix_status_container > /dev/null 2>&1; then
  strix_status_container() {
    local container="$1" state
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
      state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo '?')"
      echo -e "  ${BOLD}Container:${RESET}   ${container} (${state})"
    else
      echo -e "  ${BOLD}Container:${RESET}   ${YELLOW}not running${RESET} (llama-swap starts it on demand)"
    fi
  }
fi

# strix_status_proxy <port>
if ! declare -F strix_status_proxy > /dev/null 2>&1; then
  strix_status_proxy() {
    local port="$1"
    if curl -sf --max-time 3 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      echo -e "  ${BOLD}Proxy:${RESET}       ${GREEN}llama-swap healthy on port ${port}${RESET}"
    else
      echo -e "  ${BOLD}Proxy:${RESET}       ${YELLOW}llama-swap not answering on port ${port}${RESET}"
    fi
  }
fi

# strix_status_engine <engine_port> <model_name>
#   Is the engine listening, and is it ready by the endpoint that means
#   ready? /v1/models, not the port: Gufo binds before the weights are resident.
if ! declare -F strix_status_engine > /dev/null 2>&1; then
  strix_status_engine() {
    local port="$1" model="${2:-}" body
    if body="$(curl -sf --max-time 3 "http://127.0.0.1:${port}/v1/models" 2>/dev/null)"; then
      if [[ -n "$model" ]] \
        && ! jq -e --arg m "$model" '[.data[]?.id] | index($m)' <<<"$body" >/dev/null 2>&1; then
        echo -e "  ${BOLD}Engine API:${RESET}    ${YELLOW}port ${port} answers /v1/models but does not list ${model}${RESET}"
      else
        echo -e "  ${BOLD}Engine API:${RESET}    ${GREEN}ready on 127.0.0.1:${port}${RESET} (/v1/models)"
      fi
    elif (echo >/dev/tcp/"127.0.0.1"/"$port") 2>/dev/null; then
      echo -e "  ${BOLD}Engine API:${RESET}    ${YELLOW}port ${port} open, /v1/models not answering${RESET} (weights still loading?)"
    else
      echo -e "  ${BOLD}Engine API:${RESET}    ${YELLOW}not running${RESET} (port ${port} closed)"
    fi
  }
fi

# strix_status_disk <path> <gb-needed>
if ! declare -F strix_status_disk > /dev/null 2>&1; then
  strix_status_disk() {
    local where="${1:-.}" need="${2:-0}" avail_kb avail_gb col=GREEN
    avail_kb=$(df -Pk "$where" 2>/dev/null | awk 'NR==2 {print $4}') || {
      echo -e "  ${BOLD}Disk:${RESET}        ${YELLOW}could not read ${where}${RESET}"
      return 0
    }
    avail_gb=$((avail_kb / 1048576))
    ((avail_gb >= need)) || col=YELLOW
    echo -e "  ${BOLD}Disk:${RESET}        ${!col}${avail_gb} GB free${RESET} on ${where} ($need GB needed)"
  }
fi
