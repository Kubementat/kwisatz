#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-agentsview.sh — Install and configure agentsview (session log viewer)
# =============================================================================
#
# Installs the pinned agentsview release binary (sha256-verified) to
# ~/.local/bin, writes ~/.agentsview/config.toml with update checks disabled
# (telemetry is disabled via env var, see --help) and optionally ingests
# session directories synced from other machines (hub mode). With a
# PostgreSQL URL, installs a systemd *user* service that runs
# `agentsview pg push --watch`.
# Research: docs/research/agentsview.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATE_DIR="$(realpath "${SCRIPT_DIR}/../templates/agentsview")"
# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

AGENTSVIEW_VERSION_DEFAULT="0.44.0"

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs the pinned agentsview binary to \$AGENTSVIEW_BIN_DIR and writes
\$AGENTSVIEW_DATA_DIR/config.toml with update checks disabled.

Modes (selected by env vars):
  local (default)  agentsview auto-detects local agent logs (Claude Code,
                   Codex, OpenCode, Pi, ...) under \$HOME.
  hub              AGENTSVIEW_SESSION_SOURCES lists directories synced from
                   other machines; each becomes a [[session_sources]] entry.
  pg push          AGENTSVIEW_PG_URL set (or already stored in pg.env) ->
                   systemd user service running 'agentsview pg push --watch'.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  AGENTSVIEW_VERSION           Release to install, e.g. 0.44.0, or 'latest' (default: ${AGENTSVIEW_VERSION_DEFAULT})
  AGENTSVIEW_BIN_DIR           Install dir (default: \$HOME/.local/bin)
  AGENTSVIEW_DATA_DIR          Data dir (default: \$HOME/.agentsview)
  AGENTSVIEW_MACHINE_NAME      Display label, local_machine_name (default: hostname)
  AGENTSVIEW_SESSION_SOURCES   Hub mode. Entries separated by ';', each
                               agent|dir|machine-id, e.g.
                               'claude|/srv/sessions/box/claude/projects|<install-id>'
                               machine-id = peer's ~/.agentsview/telemetry-install-id
  AGENTSVIEW_PG_URL            PostgreSQL URL (contains credentials). Stored in
                               \$AGENTSVIEW_DATA_DIR/pg.env (mode 600), read back
                               on re-runs; never written to config.toml or the unit.
  AGENTSVIEW_FORCE_CONFIG      true = overwrite an existing config.toml (a .bak is kept).
                               Default: an existing config.toml is left untouched
                               (agentsview also writes to it) and a diff is shown.

${BOLD}Notes:${RESET}
  - Telemetry has no config key: AGENTSVIEW_TELEMETRY_ENABLED=0 is set in the
    service unit and in ~/.profile (managed line). Daemons started elsewhere
    (e.g. a desktop launcher) need it set too.
  - The service is a custom unit (not 'agentsview pg service install', which
    rejects env-provided URLs and would force the password into config.toml).
  - Headless machines need lingering: loginctl enable-linger \$USER (hinted, not run).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1 (see --help)" ;;
  esac
done

AGENTSVIEW_VERSION="${AGENTSVIEW_VERSION:-$AGENTSVIEW_VERSION_DEFAULT}"
AGENTSVIEW_BIN_DIR="${AGENTSVIEW_BIN_DIR:-$HOME/.local/bin}"
AGENTSVIEW_DATA_DIR="${AGENTSVIEW_DATA_DIR:-$HOME/.agentsview}"
AGENTSVIEW_MACHINE_NAME="${AGENTSVIEW_MACHINE_NAME:-$(hostname)}"
AGENTSVIEW_SESSION_SOURCES="${AGENTSVIEW_SESSION_SOURCES:-}"
AGENTSVIEW_FORCE_CONFIG="${AGENTSVIEW_FORCE_CONFIG:-false}"
AGENTSVIEW_DISABLE_UPDATE_CHECK="true"
export AGENTSVIEW_DATA_DIR AGENTSVIEW_BIN_DIR AGENTSVIEW_MACHINE_NAME AGENTSVIEW_DISABLE_UPDATE_CHECK

REPO="kenn-io/agentsview"
PG_ENV_FILE="${AGENTSVIEW_DATA_DIR}/pg.env"
CONFIG_FILE="${AGENTSVIEW_DATA_DIR}/config.toml"
UNIT_NAME="agentsview-pg-push.service"
UNIT_FILE="$HOME/.config/systemd/user/${UNIT_NAME}"

# --- install binary ----------------------------------------------------------
step "Installing agentsview ${AGENTSVIEW_VERSION}"
[[ "$(uname -s)" == "Linux" ]] || error "This script supports Linux only"
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) error "Unsupported architecture: $(uname -m)" ;;
esac

VERSION="${AGENTSVIEW_VERSION#v}"
if [[ "$VERSION" == "latest" ]]; then
  final_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")"
  [[ "$final_url" == */releases/tag/v* ]] || error "Could not resolve latest agentsview release"
  VERSION="${final_url##*/releases/tag/v}"
fi

installed=""
if [[ -x "${AGENTSVIEW_BIN_DIR}/agentsview" ]]; then
  installed="$(AGENTSVIEW_NO_DAEMON=1 "${AGENTSVIEW_BIN_DIR}/agentsview" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
fi
if [[ "$installed" == "$VERSION" ]]; then
  success "agentsview ${VERSION} already installed"
else
  tarball="agentsview_${VERSION}_linux_${ARCH}.tar.gz"
  base="https://github.com/${REPO}/releases/download/v${VERSION}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "${base}/${tarball}" -o "${tmp}/${tarball}" || error "Download failed: ${base}/${tarball}"
  curl -fsSL "${base}/SHA256SUMS" -o "${tmp}/SHA256SUMS" || error "Download failed: ${base}/SHA256SUMS"
  (cd "$tmp" && awk -v f="$tarball" '$2==f' SHA256SUMS | sha256sum -c -) || error "Checksum verification failed for ${tarball}"
  tar -xzf "${tmp}/${tarball}" -C "$tmp" agentsview
  mkdir -p "$AGENTSVIEW_BIN_DIR"
  install -m 755 "${tmp}/agentsview" "${AGENTSVIEW_BIN_DIR}/agentsview"
  success "Installed agentsview ${VERSION} to ${AGENTSVIEW_BIN_DIR}"
fi

# --- config ------------------------------------------------------------------
step "Writing ${CONFIG_FILE}"
mkdir -p "$AGENTSVIEW_DATA_DIR"
chmod 700 "$AGENTSVIEW_DATA_DIR"

rendered="$(mktemp)"
envsubst < "${TEMPLATE_DIR}/config.toml.tpl" > "$rendered"
if [[ -n "$AGENTSVIEW_SESSION_SOURCES" ]]; then
  IFS=';' read -ra _entries <<< "$AGENTSVIEW_SESSION_SOURCES"
  for _e in "${_entries[@]}"; do
    [[ -n "$_e" ]] || continue
    IFS='|' read -r SRC_AGENT SRC_DIR SRC_MACHINE <<< "$_e"
    [[ -n "$SRC_AGENT" && -n "$SRC_DIR" && -n "$SRC_MACHINE" ]] \
      || error "Bad AGENTSVIEW_SESSION_SOURCES entry '${_e}' (want agent|dir|machine-id)"
    export SRC_AGENT SRC_DIR SRC_MACHINE
    envsubst < "${TEMPLATE_DIR}/session-source.toml.tpl" >> "$rendered"
  done
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  install -m 600 "$rendered" "$CONFIG_FILE"
  success "Created config.toml"
elif cmp -s "$rendered" "$CONFIG_FILE"; then
  success "config.toml already up to date"
elif [[ "$AGENTSVIEW_FORCE_CONFIG" == "true" ]]; then
  cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak"
  install -m 600 "$rendered" "$CONFIG_FILE"
  success "Overwrote config.toml (backup: config.toml.bak)"
else
  warn "config.toml differs from the rendered config; left untouched (agentsview may have added keys)."
  warn "Set AGENTSVIEW_FORCE_CONFIG=true to overwrite. Diff (existing vs desired):"
  diff -u "$CONFIG_FILE" "$rendered" || true
fi
rm -f "$rendered"

# --- telemetry off for shells ------------------------------------------------
PROFILE_LINE='export AGENTSVIEW_TELEMETRY_ENABLED=0'
if ! grep -qxF "$PROFILE_LINE" "$HOME/.profile" 2>/dev/null; then
  printf '\n# agentsview: disable anonymous telemetry (kwisatz)\n%s\n' "$PROFILE_LINE" >> "$HOME/.profile"
  info "Added telemetry opt-out to ~/.profile (applies to new login shells)"
fi

# --- postgres push service ---------------------------------------------------
PG_URL="${AGENTSVIEW_PG_URL:-$(env_file_get "$PG_ENV_FILE" AGENTSVIEW_PG_URL || true)}"
if [[ -z "$PG_URL" ]]; then
  info "No AGENTSVIEW_PG_URL set: skipping pg push service"
else
  step "Configuring ${UNIT_NAME}"
  printf 'AGENTSVIEW_PG_URL=%s\n' "$PG_URL" | env_file_write "$PG_ENV_FILE"
  mkdir -p "$(dirname "$UNIT_FILE")"
  unit_tmp="$(mktemp)"
  envsubst < "${TEMPLATE_DIR}/agentsview-pg-push.service.tpl" > "$unit_tmp"
  install -m 644 "$unit_tmp" "$UNIT_FILE"
  rm -f "$unit_tmp"
  systemctl --user daemon-reload
  systemctl --user enable "$UNIT_NAME" >/dev/null
  systemctl --user restart "$UNIT_NAME"
  sleep 3
  systemctl --user is-active --quiet "$UNIT_NAME" \
    || error "${UNIT_NAME} is not active: journalctl --user -u ${UNIT_NAME}"
  success "${UNIT_NAME} active"
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then
    warn "Lingering is off: the service stops at logout. Run: loginctl enable-linger \"$USER\""
  fi
fi

success "agentsview setup complete. Try: ${AGENTSVIEW_BIN_DIR}/agentsview serve"
