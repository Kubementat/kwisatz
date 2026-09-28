#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-agentsview.sh — Install and configure agentsview (session log viewer)
# =============================================================================
#
# Installs the pinned agentsview release binary (sha256-verified) to
# ~/.local/bin, writes ~/.agentsview/config.toml with update checks disabled
# (telemetry is disabled via env var, see --help) and optionally ingests
# session directories synced from other machines (hub mode).
#
# Additionally installs a systemd *system* service `agentsview.service` that
# runs the agentsview server (web UI + API + background sync) on
# AGENTSVIEW_PORT (default 7777). The config gets `require_auth = true` and
# a generated bearer token (read back on re-runs, never rotated); when the
# server binds a non-loopback address a UFW inbound rule is added.
#
# With a PostgreSQL URL, installs a systemd *user* service that runs
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

Installs the pinned agentsview binary to \$AGENTSVIEW_BIN_DIR, writes
\$AGENTSVIEW_DATA_DIR/config.toml (update checks disabled, bearer-token auth
enabled) and installs the systemd system service 'agentsview.service' running
the agentsview server (web UI + API) on AGENTSVIEW_PORT. A UFW inbound rule
is added when the server binds a non-loopback address.

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
  AGENTSVIEW_PORT              Server port (default: 7777)
  AGENTSVIEW_HOST              Server bind address (default: 0.0.0.0 = LAN,
                               auth-protected; 127.0.0.1 = loopback only,
                               no UFW rule)
  AGENTSVIEW_HEALTH_TIMEOUT    Seconds to wait for the server to answer
                               /api/v1/stats (default: 120)
  AGENTSVIEW_PG_URL            PostgreSQL URL (contains credentials). Stored in
                               \$AGENTSVIEW_DATA_DIR/pg.env (mode 600), read back
                               on re-runs; never written to config.toml or the unit.
  AGENTSVIEW_FORCE_CONFIG      true = overwrite an existing config.toml (a .bak is kept).
                               Default: an existing config.toml is left untouched
                               (agentsview also writes to it) and a diff is shown.

${BOLD}Notes:${RESET}
  - The server requires a bearer token for every API request
    (require_auth = true in config.toml). The token is auto-generated on
    first run, read back on re-runs (never rotated) and printed in the
    summary. Use it as: curl -H 'Authorization: Bearer <token>' <url>
  - agentsview has no env-var for the token, so it lives in config.toml
    (mode 600 inside a mode-700 data dir) -- the one documented exception
    to the no-secrets-in-rendered-files rule; the unit file is secret-free.
  - The server unit runs as the invoking user (agentsview indexes that
    user's agent logs). Re-runs converge: the unit is only re-applied and
    the service restarted when the rendered unit actually changed.
  - Telemetry has no config key: AGENTSVIEW_TELEMETRY_ENABLED=0 is set in
    the service units and in ~/.profile (managed line). Daemons started
    elsewhere (e.g. a desktop launcher) need it set too.
  - The pg push service is a custom unit (not 'agentsview pg service
    install', which rejects env-provided URLs and would force the password
    into config.toml). Headless machines need lingering:
    loginctl enable-linger \$USER (hinted, not run).
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
AGENTSVIEW_PORT="${AGENTSVIEW_PORT:-7777}"
AGENTSVIEW_HOST="${AGENTSVIEW_HOST:-0.0.0.0}"
AGENTSVIEW_HEALTH_TIMEOUT="${AGENTSVIEW_HEALTH_TIMEOUT:-120}"
AGENTSVIEW_DISABLE_UPDATE_CHECK="true"
export AGENTSVIEW_DATA_DIR AGENTSVIEW_BIN_DIR AGENTSVIEW_MACHINE_NAME AGENTSVIEW_DISABLE_UPDATE_CHECK
# The server unit runs as the invoking user (agentsview indexes that user's
# agent logs). SUDO_USER catches the common `sudo ./setup-agentsview.sh` case.
AGENTSVIEW_SERVICE_USER="${SUDO_USER:-$(id -un)}"

REPO="kenn-io/agentsview"
PG_ENV_FILE="${AGENTSVIEW_DATA_DIR}/pg.env"
CONFIG_FILE="${AGENTSVIEW_DATA_DIR}/config.toml"
UNIT_NAME="agentsview-pg-push.service"
UNIT_FILE="$HOME/.config/systemd/user/${UNIT_NAME}"
SERVER_UNIT_NAME="agentsview.service"
SERVER_UNIT_FILE="/etc/systemd/system/${SERVER_UNIT_NAME}"

# --- pre-flight --------------------------------------------------------------
step "Running pre-flight checks"
[[ "$(uname -s)" == "Linux" ]] || error "This script supports Linux only"
command -v systemctl &>/dev/null || error "systemctl not found -- this script requires systemd"
command -v sudo &>/dev/null || error "sudo not found -- required for the systemd unit and UFW"
# Sudo is used for the systemd unit, daemon-reload and UFW. Passwordless sudo
# is NOT required: in an interactive TTY sudo prompts for the password on
# first use and then caches it for the remaining calls.
command -v openssl &>/dev/null || error "openssl not found -- required to generate the auth token (apt install openssl)"
command -v envsubst &>/dev/null || error "envsubst not found -- required for template rendering (apt install gettext-base)"
command -v curl &>/dev/null || error "curl not found -- required for the health gate (apt install curl)"
if ! [[ "${AGENTSVIEW_PORT}" =~ ^[0-9]+$ ]] || (( AGENTSVIEW_PORT < 1 || AGENTSVIEW_PORT > 65535 )); then
  error "AGENTSVIEW_PORT '${AGENTSVIEW_PORT}' is not a valid port (1-65535)"
fi
[[ -n "${AGENTSVIEW_HOST}" ]] || error "AGENTSVIEW_HOST must not be empty"
[[ "${AGENTSVIEW_SERVICE_USER}" != "root" ]] \
  || warn "Running as root without SUDO_USER: the server service will run as root and index /root agent logs. Run via sudo as a regular user, or set SUDO_USER."

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

# --- auth token --------------------------------------------------------------
# agentsview has no env-var for the bearer token, so it lives in config.toml.
# Read it back before rendering: an existing token is never rotated (re-runs
# must not invalidate tokens other machines already use for remote sync).
TOKEN_FILE_LINE="auth_token"
if [[ -f "$CONFIG_FILE" ]]; then
  AGENTSVIEW_AUTH_TOKEN="$(grep -Eo "${TOKEN_FILE_LINE}[[:space:]]*=[[:space:]]*\"[^\"]+\"" "$CONFIG_FILE" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
fi
AGENTSVIEW_AUTH_TOKEN="${AGENTSVIEW_AUTH_TOKEN:-}"
if [[ -n "$AGENTSVIEW_AUTH_TOKEN" ]]; then
  info "Reusing existing auth token from ${CONFIG_FILE} (not rotated)"
else
  AGENTSVIEW_AUTH_TOKEN="$(openssl rand -hex 24)"
  info "Generated a new auth token"
fi
export AGENTSVIEW_AUTH_TOKEN AGENTSVIEW_HOST AGENTSVIEW_PORT AGENTSVIEW_SERVICE_USER

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
  warn "If the existing config lacks require_auth/auth_token, agentsview generates its own at startup -- the live token is re-read below."
fi
rm -f "$rendered"

# --- server service ----------------------------------------------------------
step "Configuring ${SERVER_UNIT_NAME} (server on ${AGENTSVIEW_HOST}:${AGENTSVIEW_PORT})"
unit_tmp="$(mktempfile agentsview.service)"
# Render as the invoking user (envsubst reads the rendering environment), then
# install via sudo -- never `sudo envsubst`.
# shellcheck disable=SC2016  # envsubst expects the literal variable list
envsubst '${AGENTSVIEW_SERVICE_USER} ${AGENTSVIEW_DATA_DIR} ${AGENTSVIEW_BIN_DIR} ${AGENTSVIEW_HOST} ${AGENTSVIEW_PORT}' \
  < "${TEMPLATE_DIR}/agentsview.service.tpl" > "${unit_tmp}"

unit_changed=0
if [[ ! -f "${SERVER_UNIT_FILE}" ]]; then
  unit_changed=1
elif ! cmp -s "${unit_tmp}" "${SERVER_UNIT_FILE}"; then
  unit_changed=1
fi

if (( unit_changed )); then
  sudo install -m 644 "${unit_tmp}" "${SERVER_UNIT_FILE}"
  sudo systemctl daemon-reload
  sudo systemctl enable "${SERVER_UNIT_NAME}" >/dev/null
  if sudo systemctl is-active "${SERVER_UNIT_NAME}" &>/dev/null; then
    sudo systemctl restart "${SERVER_UNIT_NAME}"
  else
    sudo systemctl start "${SERVER_UNIT_NAME}"
  fi
  success "Service installed, enabled and (re)started"
else
  info "Unit unchanged."
  if sudo systemctl is-active "${SERVER_UNIT_NAME}" &>/dev/null; then
    info "Service already running -- not restarting a healthy service."
  else
    sudo systemctl enable "${SERVER_UNIT_NAME}" >/dev/null
    sudo systemctl start "${SERVER_UNIT_NAME}"
    success "Service started"
  fi
fi

# --- server health gate ------------------------------------------------------
# agentsview auto-generates a missing auth_token during startup -- re-read the
# config so the health check and the printed token are the live ones.
sleep 2
live_token="$(grep -Eo "${TOKEN_FILE_LINE}[[:space:]]*=[[:space:]]*\"[^\"]+\"" "$CONFIG_FILE" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
if [[ -n "${live_token}" && "${live_token}" != "${AGENTSVIEW_AUTH_TOKEN}" ]]; then
  warn "The running server uses a different token (agentsview generated one at startup)."
  AGENTSVIEW_AUTH_TOKEN="${live_token}"
fi

step "Waiting for the server to answer /api/v1/stats (timeout: ${AGENTSVIEW_HEALTH_TIMEOUT}s)"
HEALTH_URL="http://127.0.0.1:${AGENTSVIEW_PORT}/api/v1/stats"
ELAPSED=0
READY=false
while (( ELAPSED < AGENTSVIEW_HEALTH_TIMEOUT )); do
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${AGENTSVIEW_AUTH_TOKEN}" "${HEALTH_URL}" 2>/dev/null || true)"
  [[ -n "${HTTP_CODE}" ]] || HTTP_CODE="000"
  if [[ "${HTTP_CODE}" == "200" ]]; then
    READY=true
    break
  fi
  echo -ne "\r    waited ${ELAPSED}s / ${AGENTSVIEW_HEALTH_TIMEOUT}s … (HTTP ${HTTP_CODE})   "
  sleep 5
  ELAPSED=$(( ELAPSED + 5 ))
done
echo ""
if [[ "${READY}" != "true" ]]; then
  warn "agentsview did not answer ${HEALTH_URL} within ${AGENTSVIEW_HEALTH_TIMEOUT}s."
  warn "Check:  sudo systemctl status ${SERVER_UNIT_NAME}"
  warn "        sudo journalctl -u ${SERVER_UNIT_NAME} -n 50 --no-pager"
  error "agentsview server is not healthy -- see the journal for the cause."
fi
success "agentsview server is up and answering ${HEALTH_URL} (bearer auth required)"

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

# --- firewall ----------------------------------------------------------------
if [[ "${AGENTSVIEW_HOST}" == "127.0.0.1" || "${AGENTSVIEW_HOST}" == "localhost" ]]; then
  info "Server bound to loopback -- no UFW rule required."
else
  ufw_firewall_section "agentsview" "${AGENTSVIEW_PORT}" tcp "agentsview-api"
fi

# --- summary -----------------------------------------------------------------
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  agentsview setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Server URL${RESET}   http://${AGENTSVIEW_HOST}:${AGENTSVIEW_PORT}"
echo -e "  ${BOLD}API base${RESET}     http://<host>:${AGENTSVIEW_PORT}/api/v1/..."
echo -e "  ${BOLD}Auth token${RESET}   ${AGENTSVIEW_AUTH_TOKEN}"
echo -e "  ${BOLD}Unit${RESET}         ${SERVER_UNIT_FILE}"
echo -e "  ${BOLD}Config${RESET}       ${CONFIG_FILE}"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Status:   sudo systemctl status ${SERVER_UNIT_NAME}"
echo -e "  Restart:  sudo systemctl restart ${SERVER_UNIT_NAME}"
echo -e "  Logs:     sudo journalctl -u ${SERVER_UNIT_NAME} -f"
echo -e "  API:      curl -H 'Authorization: Bearer ${AGENTSVIEW_AUTH_TOKEN}' http://127.0.0.1:${AGENTSVIEW_PORT}/api/v1/stats"
echo ""
echo -e "${YELLOW}  Notes:${RESET}"
echo -e "  • Every API request needs the bearer token above (require_auth = true)."
echo -e "  • For remote sync, a collector adds a [[remote_hosts]] entry with"
echo -e "    url = \"http://<host>:${AGENTSVIEW_PORT}\" and this token."
echo -e "  • The token is never rotated on re-runs -- it is read back from"
echo -e "    ${CONFIG_FILE}; only AGENTSVIEW_FORCE_CONFIG=true rewrites the file."
echo ""
