#!/usr/bin/env bash
# shellcheck disable=SC1091
# =============================================================================
# setup-strix-halo-tuning.sh
# Prepares an AMD Strix Halo machine (Ryzen AI MAX+ 395 / Radeon 8060S /
# gfx1151) for large-model inference: the GPU memory reserve the models need,
# the kernel knobs that keep it stable, swap policy, and the ROCm/Vulkan bits.
#
# This is the ONLY script in the repo that writes GRUB or sysctl. That is a
# deliberate boundary, not an accident: nothing else in this tree touches the
# kernel command line, the blast radius here is machine-wide, the "reboot
# required" message needs exactly one owner, and the two model tasks
# (setup-gufo-strix-halo-qwen38-{flash,27b}.sh) therefore only READ the result
# — they never run update-grub and never write /etc/sysctl.d.
#
# What it writes (cold run — exactly two files, plus one backup):
#   /etc/default/grub.d/99-kwisatz-strix-halo.cfg   GPU aperture + TTM pages
#   /etc/sysctl.d/99-strix-halo-llm.conf            vm.swappiness
#
# Why the pair: amdgpu.gttsize sets the GPU's access window in MiB, and
# ttm.pages_limit sets how many 4 KiB pages the TTM allocator will back. The
# model is paged into the aperture, so both must say the same GiB or an
# allocation dies past the smaller number. The widely-copied forum pair
#   amdgpu.gttsize=131072 ttm.pages_limit=31457280
# is 128 GiB of window against 120 GiB of pages — a disagreement that shows up
# as "the model crashes at 90 GB", not as a boot error, so --check compares
# them and reports `mismatched` explicitly.
#
# Workflow (idempotent, converges on re-run):
#   1. pre-flight: Ubuntu, sudo, the Strix Halo hardware gate (before writing
#      anything, so a wrong machine cannot be tuned)
#   2. packages: rocm-smi, mesa-vulkan-drivers, linux-firmware
#      (STRIX_INSTALL_PACKAGES=0 skips them; nothing is ever removed)
#   3. render both drop-ins from templates/ (mode 644; a foreign file at the
#      target gets one .bak, never a second one)
#   4. ZRAM swap: detect and disable, with what was found printed. Packages are
#      NOT removed, and a swap partition is left alone
#   5. loginctl enable-linger so the user's services survive logout
#   6. update-grub (unless --skip-update-grub), then the active-vs-written
#      comparison and the status report
#
# Usage:
#   ./setup-strix-halo-tuning.sh                        # install / converge
#   GPU_RESERVE_GIB=116 ./setup-strix-halo-tuning.sh    # desktop-class reserve
#   ./setup-strix-halo-tuning.sh --check                # report only, no writes
#   ./setup-strix-halo-tuning.sh --skip-update-grub     # write, reboot later
#   ./setup-strix-halo-tuning.sh --force                # rewrite even if equal
#   ./setup-strix-halo-tuning.sh --help
#
# Privileged commands run through sudo, so the intended invocation is the
# account that owns the box rather than a root shell. Running it as root
# (sudo -E ./setup-strix-halo-tuning.sh) is supported too; SUDO_USER then keeps
# the linger target that account instead of root. Root privilege is settled in
# the first step — the credential is reused when still valid, and asked for once
# when a terminal is attached — so a prompt never lands in the middle of a run.
#
# What never happens: a reboot, an interactive prompt, a package removal, or a
# silent success when the running kernel does not match what was written. The
# reboot is the one documented non-convergeable case: the script prints
# "written, not active" plus the exact command and exits 0.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/strix-halo-tuning"

# shellcheck source=../lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"
# Floor the Strix Halo gate compares MemTotal against. Assigned BEFORE the
# helper is sourced, because the helper publishes its own default (125) at
# source time and its "${VAR:-125}" form would leave that value standing.
#
# 125 was a stand-in for "this is the 128 GiB SKU", but MemTotal is not the
# physical part: with the BIOS carve-out set correctly the same machine reports
# ~124 GiB once the kernel and the display have taken their share, so 125
# refused a correctly configured 128 GiB box. 120 keeps the 32 GiB and 64 GiB
# SKUs out, which is what the floor is for.
STRIX_MIN_RAM_GIB="${STRIX_MIN_RAM_GIB:-120}"
# shellcheck source=../lib/strix-halo-helper.sh
source "${SCRIPT_DIR}/../lib/strix-halo-helper.sh"

# ── Tunables ──────────────────────────────────────────────────────────────────
# One knob for the whole file. gttsize and pages_limit are derived from it in
# lib/strix-halo-helper.sh (strix_gtt_math), so they cannot drift apart.
#
# 120 GiB is the headless-inference number (≈8 GiB of the 128 GiB SKU stays for
# the OS, page cache and KV cache). 116 GiB is the "this box also runs a
# desktop" number. Either is one env var away; --reserve is the CLI form.
GPU_RESERVE_GIB="${GPU_RESERVE_GIB:-120}"
# A 128 GiB machine that swaps weights into compressed RAM is slower than one
# that OOMs early, because the OOM is diagnosable and the thrash is not.
VM_SWAPPINESS="${VM_SWAPPINESS:-10}"
# Kernel arguments that follow the Strix Halo guidance: IOMMU off for the iGPU
# path, the amdgpu fault-recovery pair. Leading space is part of the value.
AMDGPU_EXTRA_ARGS="${AMDGPU_EXTRA_ARGS:- amd_iommu=off amdgpu.noretry=0 amdgpu.gpu_recovery=1}"
# 1 = install the userspace the engine needs. Set to 0 to keep a package
# manager untouched; the script then only warns about what is missing.
STRIX_INSTALL_PACKAGES="${STRIX_INSTALL_PACKAGES:-1}"
STRIX_PACKAGES=(rocm-smi mesa-vulkan-drivers linux-firmware)

# ── Account for the per-user privileged bits ────────────────────────────
# Linger is a per-account setting, and its polkit action is auth_admin: run
# directly as a plain user it is denied rather than allowed, so it goes through
# sudo. Everything privileged here is sudo-wrapped for the same reason, which is
# why the normal invocation is the invoking user and not a root shell — but
# `sudo ./setup-strix-halo-tuning.sh` has to work too, and there `id -un` is
# root. Lingering root would leave the operator's services dead after logout
# while reporting success, so SUDO_USER wins whenever the euid really is root.
# TUNING_USER overrides both, for boxes whose models run under a dedicated user.
if [[ -z "${TUNING_USER:-}" ]]; then
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    TUNING_USER="$SUDO_USER"
  else
    TUNING_USER="$(id -un)"
  fi
fi
[[ -n "$TUNING_USER" ]] || die "could not determine the account to enable lingering for"
export TUNING_USER

# ── Paths ─────────────────────────────────────────────────────────────────────
GRUB_DROPIN="/etc/default/grub.d/99-kwisatz-strix-halo.cfg"
SYSCTL_DROPIN="/etc/sysctl.d/99-strix-halo-llm.conf"
STRIX_GRUB_DROPIN="${GRUB_DROPIN}"
export STRIX_GRUB_DROPIN

MODE="install"
FORCE=0
SKIP_UPDATE_GRUB=0
RESERVE_OVERRIDE=""

usage() {
  cat <<EOF
setup-strix-halo-tuning.sh — GPU reserve + kernel tuning for AMD Strix Halo

Writes two files (/etc/default/grub.d/99-kwisatz-strix-halo.cfg,
/etc/sysctl.d/99-strix-halo-llm.conf) derived from one knob:
GPU_RESERVE_GIB (default ${GPU_RESERVE_GIB}).

USAGE
  setup-strix-halo-tuning.sh [options]
      Normal invocation: the account that owns the box, with every privileged
      command run through sudo.

  sudo -E setup-strix-halo-tuning.sh [options]
      The same run taken with root privileges; SUDO_USER then names the account
      that gets linger, not root.

  Privilege is resolved up front, before anything is written: the credential is
  reused if it is still valid, sudo is asked for once if this is a terminal, and
  a run with no terminal to answer in stops rather than hanging.

  When the run is not attached to a terminal (another script, a pipeline, cron),
  give it a credential first: sudo -v && $(basename "$0")

OPTIONS
  --reserve <GiB>     GPU aperture to reserve (default ${GPU_RESERVE_GIB};
                      sets GPU_RESERVE_GIB). 116 = also runs a desktop.
  --check             report every probe, derived-vs-detected side by side,
                      and exit without writing anything
  --force             rewrite both drop-ins even when they already match
  --skip-update-grub  write the drop-ins, do not run update-grub (reboot will
                      then be required before anything is active)
  -h, --help          this text

ENVIRONMENT
  GPU_RESERVE_GIB        ${GPU_RESERVE_GIB}
                         the one knob; gttsize and ttm.pages_limit derive from
                         it
  STRIX_MIN_RAM_GIB      ${STRIX_MIN_RAM_GIB}
                         MemTotal the hardware gate demands (see the comment by
                         the lib source line); lower it only on a machine that
                         really is smaller than this sizing assumes
  TUNING_USER            ${TUNING_USER}
                         account enabled for linger. Defaults to your own
                         account, or to SUDO_USER when run with root privileges
  VM_SWAPPINESS          ${VM_SWAPPINESS}
                         written into the sysctl drop-in
  AMDGPU_EXTRA_ARGS      "${AMDGPU_EXTRA_ARGS}"
                         kernel arguments appended after the reserve pair
  STRIX_INSTALL_PACKAGES 1 (0 = never touch apt)
  STRIX_PACKAGES         "${STRIX_PACKAGES[*]}"

WHAT THIS DOES NOT DO
  It never reboots, never prompts, and never removes a package. A re-run
  re-renders both files from templates and re-runs update-grub; nothing else
  changes. If /proc/cmdline does not match what was written the script prints
  "written, not active" plus the exact command and exits 0 — the reboot is the
  one case a re-run cannot converge.

EXAMPLES
  $(basename "$0")                              # cold install, 120 GiB reserve
  GPU_RESERVE_GIB=116 $(basename "$0")           # same, smaller reserve
  sudo -E $(basename "$0") --reserve 116         # as root, desktop-class reserve
  $(basename "$0") --check                       # what is true right now

SEE ALSO
  setup-gufo-strix-halo-qwen38-27b.sh / -flash.sh — the models that gate on
  this tuning being active, and lib/strix-halo-helper.sh for the state machine
  behind the "written but not active" state.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --check) MODE="check" ;;
  --force) FORCE=1 ;;
  --skip-update-grub) SKIP_UPDATE_GRUB=1 ;;
  --reserve)
    RESERVE_OVERRIDE="${2:-}"
    [[ -n "$RESERVE_OVERRIDE" && "$RESERVE_OVERRIDE" =~ ^[0-9]+$ ]] \
      || die "--reserve needs a whole number of GiB (e.g. --reserve 116)"
    GPU_RESERVE_GIB="$RESERVE_OVERRIDE"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    # error terminates, so the hint belongs in the same line rather than in a
    # following usage() that could never run.
    error "Unknown argument: $1  (use --help for usage)"
    ;;
  esac
  shift
done

if [[ "$GPU_RESERVE_GIB" != "0" && ("$GPU_RESERVE_GIB" -lt 4 || "$GPU_RESERVE_GIB" -gt 250) ]]; then
  die "GPU_RESERVE_GIB=${GPU_RESERVE_GIB} is not plausible (4..250 GiB) — a single-knob number that is this wrong is a typo, not a tuning"
fi

# ── Report ────────────────────────────────────────────────────────────────────
# Same order as a run: hardware, then the tuning state, then the things that
# only matter once the first two are right. --check walks the same list as the
# install path, because two status implementations would drift from each other
# long before anyone noticed.
print_status() {
  echo
  echo "Strix Halo tuning — GPU_RESERVE_GIB=${GPU_RESERVE_GIB}"
  echo
  strix_status_gpu
  strix_status_gtt "$GPU_RESERVE_GIB"
  strix_status_locked_memory
  strix_status_swap
  strix_status_devices
  strix_status_memory_budget
  echo
  if [[ -f "$GRUB_DROPIN" ]]; then
    echo -e "  ${BOLD}Grub drop-in:${RESET} ${GRUB_DROPIN} (present)"
  else
    echo -e "  ${BOLD}Grub drop-in:${RESET} ${YELLOW}${GRUB_DROPIN} not written${RESET}"
  fi
  if [[ -f "$SYSCTL_DROPIN" ]]; then
    echo -e "  ${BOLD}Sysctl:${RESET}       ${SYSCTL_DROPIN} ($(grep -h '^vm.swappiness' "$SYSCTL_DROPIN" 2>/dev/null | head -1))"
  else
    echo -e "  ${BOLD}Sysctl:${RESET}       ${YELLOW}${SYSCTL_DROPIN} not written${RESET}"
  fi
  echo -e "  ${BOLD}Linger:${RESET}       $(loginctl show-user "$TUNING_USER" 2>/dev/null | grep -m1 '^Linger=' || echo 'Linger=?') (${TUNING_USER})"
}

# ── Check ─────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "check" ]]; then
  print_status
  if [[ "${STRIX_GPU_OK:-0}" != "1" ]]; then
    echo
    warn "Not a Strix Halo (gfx1151) machine — this tuning is for that hardware."
  fi
  if [[ "${STRIX_REBOOT_REQUIRED:-0}" == "1" ]]; then
    echo
    warn "Tuning is written but not active: sudo update-grub && sudo reboot"
  fi
  exit 0
fi

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
# Privilege arrives through sudo, so this script's normal invocation is a
# sudo-capable user rather than a root shell. The one thing that must not happen
# is a password prompt appearing in the middle of a run — that would hang a
# run-setup.sh pass with nobody at the keyboard. So the credential is acquired
# here, once, before anything is written, and only when a terminal is attached:
#   root already             → nothing to ask
#   credential still valid   → nothing to ask
#   password needed, tty     → exactly one prompt, now
#   password needed, no tty  → stop, because there is no one to answer it
require_sudo_credentials() {
  if [[ "$(id -u)" -eq 0 ]]; then
    info "Running with root privileges (linger target: ${TUNING_USER})"
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    warn "Not running as root — commands requiring root privileges will use sudo"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    # One die, not a chain of err_msg calls: err_msg returns 1, and under set -e
    # the first one would abort the run before the advice below it was reached.
    die "no sudo credential is available, and this run has no terminal to ask for one.
  Nothing has been executed yet, so nothing has changed. Two ways forward:
    1. run it where you can type the password:    ./$(basename "$0")
    2. give it a credential that needs no prompt: sudo -v && ./$(basename "$0")"
  fi
  info "A few commands need root privileges (apt, install, sysctl, update-grub, loginctl)"
  if ! sudo -v; then
    die "sudo authentication failed — this account cannot write /etc/default/grub.d and /etc/sysctl.d. Re-run as a sudo-capable account, or with: sudo ./$(basename "$0")"
  fi
  warn "Not running as root — commands requiring root privileges will use sudo"
}

step "Checking the machine"
require_sudo_credentials

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  warn "not an Ubuntu system — the GRUB/sysctl paths assume Ubuntu"
fi

# The hardware gate runs before any write. A wrong machine that gets "harmless"
# tuning is a machine that later fails for a reason nobody can see.
strix_require_strix_hal "this tuning" || die "refusing to tune a machine that is not the Strix Halo hardware this stack targets"

# ── 2. Packages ───────────────────────────────────────────────────────────────
step "Checking userspace packages"
if [[ "$STRIX_INSTALL_PACKAGES" == "1" ]]; then
  if sudo apt-get update -qq; then
    # --no-install-recommends: the recommended set here pulls desktop Vulkan
    # layers onto a headless inference box.
    sudo apt-get install -y --no-install-recommends "${STRIX_PACKAGES[@]}" \
      || warn "apt-get install failed for: ${STRIX_PACKAGES[*]} — continuing, the packages may already be present by other names"
  else
    warn "apt-get update failed — cannot install ${STRIX_PACKAGES[*]} (set STRIX_INSTALL_PACKAGES=0 to silence)"
  fi
else
  info "STRIX_INSTALL_PACKAGES=0 — leaving apt alone"
  for p in "${STRIX_PACKAGES[@]}"; do
    command -v "$p" >/dev/null 2>&1 || dpkg -l "$p" 2>/dev/null | grep -q '^ii' \
      || warn "package not found: $p (the engine needs its userspace)"
  done
fi

# ── 3. Drop-ins ───────────────────────────────────────────────────────────────
# Every render is mktemp + sudo install as the invoking user; sudo envsubst is
# never used, because it would let a template's typo be owned by root and make
# the next re-run's diff unreviewable.
install_dropin() {
  local template="$1" target="$2" varlist="$3" mode="$4"
  local tmp
  if [[ ! -r "$template" ]]; then
    err_msg "template not readable: $template"
    return 1
  fi
  tmp="$(mktempfile "$(basename "$target")")"
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  if ! envsubst "$varlist" <"$template" >"$tmp"; then
    err_msg "Rendering $template failed"
    rm -f -- "$tmp"
    return 1
  fi

  if [[ -f "$target" ]]; then
    if [[ "$FORCE" != "1" ]] && cmp -s "$tmp" "$target"; then
      info "Unchanged: $target"
      rm -f -- "$tmp"
      return 0
    fi
    # A file that is not ours gets exactly one backup, on the first time we
    # overwrite it. A re-run must not bury the operator's file under .bak.bak.
    if [[ ! -e "${target}.bak" ]] && ! grep -q "kwisatz" "$target" 2>/dev/null; then
      sudo cp -a "$target" "${target}.bak"
      warn "pre-existing foreign file backed up to ${target}.bak"
    fi
  fi

  if sudo install -m "$mode" -o root -g root "$tmp" "$target" 2>/dev/null; then
    rm -f -- "$tmp"
    success "Wrote $target"
  else
    err_msg "Could not install $target"
    rm -f -- "$tmp"
    return 1
  fi
}

step "Writing the GPU-reserve drop-in"
# strix_gtt_math PRINTS the pair, it does not assign it. It has to be captured:
# calling it on its own line leaves GTT_SIZE_MIB and TTM_PAGES_LIMIT unset,
# envsubst substitutes two empty strings, and the boot line comes out as
#   amdgpu.gttsize= ttm.pages_limit=
# which ttm rejects outright ("invalid for parameter 'pages_limit'") and which
# keeps amdgpu from probing at all — no /dev/kfd, no KFD node, no render node,
# so every later gate reports "no gfx1151 device" on a box that has one.
read -r GTT_SIZE_MIB TTM_PAGES_LIMIT <<<"$(strix_gtt_math "$GPU_RESERVE_GIB")"
[[ -n "$GTT_SIZE_MIB" && -n "$TTM_PAGES_LIMIT" ]] \
  || die "could not derive the reserve pair from GPU_RESERVE_GIB=${GPU_RESERVE_GIB}"
export GTT_SIZE_MIB TTM_PAGES_LIMIT GPU_RESERVE_GIB AMDGPU_EXTRA_ARGS
# shellcheck disable=SC2016  # envsubst expects the literal variable list
install_dropin "${TEMPLATE_DIR}/99-kwisatz-strix-halo.cfg" "$GRUB_DROPIN" \
  '${GTT_SIZE_MIB} ${TTM_PAGES_LIMIT} ${GPU_RESERVE_GIB} ${AMDGPU_EXTRA_ARGS}' 644 \
  || die "could not write $GRUB_DROPIN"

# Read the installed file back before trusting it. An empty value here is what
# took the GPU away for a whole boot, and the file's own example pair inside a
# comment looks like a valid setting to any grep that scans the whole file, so
# this looks only at what is not commented out.
if ! grep -v '^[[:space:]]*#' "$GRUB_DROPIN" 2>/dev/null \
  | grep -qE "amdgpu\.gttsize=${GTT_SIZE_MIB}.*ttm\.pages_limit=${TTM_PAGES_LIMIT}"; then
  die "$GRUB_DROPIN does not carry the reserve pair ${GTT_SIZE_MIB}/${TTM_PAGES_LIMIT} outside its comments — refusing to leave a boot line that would keep amdgpu from loading"
fi

step "Writing the sysctl drop-in"
export VM_SWAPPINESS
# shellcheck disable=SC2016  # envsubst expects the literal variable list
install_dropin "${TEMPLATE_DIR}/99-strix-halo-llm.conf" "$SYSCTL_DROPIN" \
  '${VM_SWAPPINESS}' 644 \
  || die "could not write $SYSCTL_DROPIN"
if command -v sysctl >/dev/null 2>&1; then
  sudo sysctl --system >/dev/null 2>&1 || sudo sysctl -p "$SYSCTL_DROPIN" >/dev/null 2>&1 \
    || warn "sysctl could not apply $SYSCTL_DROPIN now (it applies at boot)"
fi

# ── 4. ZRAM ───────────────────────────────────────────────────────────────────
# zram on a 128 GiB inference box is actively harmful: compressed RAM is the
# page pool, so paging weights in competes with the model for the same memory
# it is paging. We disable it and say what we found; we never remove a package,
# and we never touch a real swap partition.
step "Checking swap"
zram_devices=()
while read -r dev; do
  [[ "$dev" == /dev/zram* ]] && zram_devices+=("$dev")
done < <(swapon --show=NAME --noheadings 2>/dev/null || true)
if [[ "${#zram_devices[@]}" -gt 0 ]]; then
  warn "zram swap devices active: ${zram_devices[*]}"
  for dev in "${zram_devices[@]}"; do
    sudo swapoff "$dev" || warn "swapoff $dev failed (still active)"
  done
  # Mask what created them rather than delete anything. zram-generator's unit,
  # or ubuntu's zram-tools service.
  for unit in zram-generator-defaults zramswap; do
    if systemctl list-unit-files "${unit}.service" --all 2>/dev/null | grep -q "$unit"; then
      sudo systemctl disable --now "${unit}.service" 2>/dev/null || true
      sudo systemctl mask "${unit}.service" 2>/dev/null \
        || warn "could not mask ${unit}.service — mask it yourself"
      info "masked ${unit}.service (package left installed)"
    fi
  done
  info "If this is not wanted: sudo systemctl unmask the unit and re-enable it"
else
  info "no zram swap active"
fi
if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
  warn "swap is still active on non-zram devices — see swapon --show; that is deliberate, a real partition is not this script's business"
fi

# ── 5. Linger ─────────────────────────────────────────────────────────────────
# Linger is per-account, so it follows TUNING_USER rather than whoever happens
# to hold the euid, and it needs root either way (see the note under Tunables).
step "Enabling lingering for ${TUNING_USER}"
if ! command -v loginctl >/dev/null 2>&1; then
  warn "loginctl not found — cannot enable lingering for ${TUNING_USER}"
elif sudo loginctl enable-linger "$TUNING_USER" 2>/dev/null; then
  info "user services survive logout"
else
  warn "loginctl enable-linger failed for ${TUNING_USER} — llama-swap and its models must then be started by a system service"
fi

# ── 6. update-grub + active-vs-written ────────────────────────────────────────
if [[ "$SKIP_UPDATE_GRUB" == "1" ]]; then
  step "Skipping update-grub (--skip-update-grub)"
  warn "the drop-in is written but not in any grub.cfg — run sudo update-grub before rebooting"
elif command -v update-grub >/dev/null 2>&1; then
  step "Running update-grub"
  sudo update-grub || die "update-grub failed — the drop-in is written but will not be picked up"
elif command -v grub-mkconfig >/dev/null 2>&1; then
  step "Running grub-mkconfig"
  sudo grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig failed"
else
  warn "neither update-grub nor grub-mkconfig found — this may not be a GRUB boot"
  warn "add amdgpu.gttsize=${GTT_SIZE_MIB} ttm.pages_limit=${TTM_PAGES_LIMIT} to your boot loader manually"
fi

# Written-vs-active is the state that matters, and it is the one that lies most
# often (an apt kernel upgrade replaces the grub.cfg this wrote).
print_status
echo
if [[ "${STRIX_REBOOT_REQUIRED:-0}" == "1" ]]; then
  warn "Written, not active. The running kernel still has the old reserve."
  warn "Apply it with:  sudo update-grub && sudo reboot"
  info "The model tasks will refuse to start until that is done, on purpose."
elif [[ "${STRIX_GTT:-}" == "mismatched" ]]; then
  err_msg "The kernel has a mismatched pair — see the detail above."
  err_msg "Fix it by re-running with the same --reserve rather than by editing this file"
  err_msg "(the pair is derived, so a hand-edited drop-in is exactly how the two halves disagree)"
  exit 1
fi

success "Strix Halo tuning complete"
info "Next: $(basename "$0") --check should read 'active', then run tasks/setup-llama-swap.sh and the model task"
