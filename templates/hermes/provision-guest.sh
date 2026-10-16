#!/usr/bin/env bash
# =============================================================================
# provision-guest.sh — Install and converge Hermes Agent inside the Hermes VM
# =============================================================================
#
# Copied into the guest and executed over SSH by tasks/setup-hermes.sh, as the
# guest's cloud user (non-root, passwordless sudo). Not meant to run on the
# host. Idempotent: safe to re-run.
#
# The unit files it installs are expected next to this script (copied by the
# host): hermes-backup.service, hermes-backup.timer, hermes-serve.service.
#
# Environment (set by tasks/setup-hermes.sh):
#   HERMES_COMMIT      - hermes-agent commit to install (required)
#   HERMES_SERVE       - "true" to run `hermes serve` (default: false)
#   HERMES_SERVE_PORT  - port of `hermes serve` (default: 9119)
#   HERMES_LLM_BASE_URL / HERMES_LLM_MODEL / HERMES_LLM_API_KEY
#                      - optional: wire the main model to an OpenAI-compatible
#                         endpoint (llama-swap / vLLM / llama.cpp-server)
#   WAIT_TIMEOUT       - max seconds to wait for a service (default: 180)
#
# Secrets: nothing secret is rendered into files. Dashboard credentials are
# generated here, and the HERMES_LLM_API_KEY (if given) is stored, in
# ~/.hermes/.env (mode 600) — both are read back before writing and never
# printed, and neither is ever written into config.yaml.
# =============================================================================

set -euo pipefail

: "${HERMES_COMMIT:?HERMES_COMMIT is required}"
HERMES_SERVE="${HERMES_SERVE:-false}"
HERMES_SERVE_PORT="${HERMES_SERVE_PORT:-9119}"
HERMES_LLM_BASE_URL="${HERMES_LLM_BASE_URL:-}"
HERMES_LLM_MODEL="${HERMES_LLM_MODEL:-}"
HERMES_LLM_API_KEY="${HERMES_LLM_API_KEY:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
HERMES_HOME="${HOME}/.hermes"
INSTALL_DIR="${HERMES_HOME}/hermes-agent"
ENV_FILE="${HERMES_HOME}/.env"
UNIT_DIR="${HOME}/.config/systemd/user"
# Installer taken from the pinned commit itself, so its content is pinned too.
INSTALLER_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh"

export PATH="${HOME}/.local/bin:${PATH}"
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR

log()  { echo "[hermes-guest] $*"; }
fail() { echo "[hermes-guest] ERROR: $*" >&2; exit 1; }

# wait_active <unit> — bounded wait until a user unit is active, then make sure
# it is still active a few seconds later (catches an immediate crash loop).
wait_active() {
  local unit="$1" waited=0
  until systemctl --user is-active --quiet "${unit}"; do
    if (( waited >= WAIT_TIMEOUT )); then
      systemctl --user status "${unit}" --no-pager -n 30 || true
      fail "${unit} is not active after ${WAIT_TIMEOUT}s"
    fi
    sleep 3; waited=$(( waited + 3 ))
  done
  sleep 5
  if ! systemctl --user is-active --quiet "${unit}"; then
    systemctl --user status "${unit}" --no-pager -n 30 || true
    fail "${unit} started but did not stay active"
  fi
  log "${unit} is active"
}

# install_unit <file> — install a user unit; prints "changed" when it differs.
install_unit() {
  local src="${HERE}/$1" dest="${UNIT_DIR}/$1"
  [[ -f "${src}" ]] || fail "unit file missing next to provision-guest.sh: $1"
  if ! cmp -s "${src}" "${dest}" 2>/dev/null; then
    install -D -m 0644 "${src}" "${dest}"
    echo "changed"
  fi
}

# ---------------------------------------------------------------------------
# 1. Base system
# ---------------------------------------------------------------------------
if command -v cloud-init &>/dev/null; then
  log "Waiting for cloud-init to finish"
  cloud-init status --wait >/dev/null 2>&1 || true
fi

for mnt in /workspace /mnt/backups; do
  mountpoint -q "${mnt}" \
    || fail "${mnt} is not mounted — the VM was created without its host shares (see setup-hermes.sh --help)"
done

missing=()
for pkg in git curl ca-certificates build-essential openssl; do
  dpkg-query -W -f='${db:Status-Status}' "${pkg}" 2>/dev/null | grep -qx installed || missing+=("${pkg}")
done
if (( ${#missing[@]} > 0 )); then
  log "Installing apt packages: ${missing[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
fi

# ---------------------------------------------------------------------------
# 2. Hermes Agent at the pinned commit
# ---------------------------------------------------------------------------
current_commit="$(git -C "${INSTALL_DIR}" rev-parse HEAD 2>/dev/null || true)"
installer_ran=false
if [[ "${current_commit}" == "${HERMES_COMMIT}" ]] && command -v hermes &>/dev/null; then
  log "Hermes Agent already at pinned commit ${HERMES_COMMIT} — skipping the installer"
else
  log "Installing Hermes Agent at commit ${HERMES_COMMIT} (currently: ${current_commit:-not installed})"
  installer="$(mktemp --suffix=.install.sh)"
  curl -fsSL "${INSTALLER_URL}" -o "${installer}" || fail "download failed: ${INSTALLER_URL}"
  log "Installer sha256=$(sha256sum "${installer}" | cut -d' ' -f1)"
  bash "${installer}" --non-interactive --commit "${HERMES_COMMIT}" \
    || fail "Hermes installer failed — see ${HERMES_HOME}/logs/install.log"
  rm -f "${installer}"
  installer_ran=true
  current_commit="$(git -C "${INSTALL_DIR}" rev-parse HEAD 2>/dev/null || true)"
  [[ "${current_commit}" == "${HERMES_COMMIT}" ]] \
    || fail "installer finished but ${INSTALL_DIR} is at '${current_commit}', expected ${HERMES_COMMIT}"
fi
command -v hermes &>/dev/null || fail "hermes command not found in ${HOME}/.local/bin after install"
log "hermes version: $(hermes --version 2>&1 | head -n1)"

# ---------------------------------------------------------------------------
# 3. systemd user session (linger) + daily backup timer
# ---------------------------------------------------------------------------
if [[ "$(loginctl show-user "${USER}" -p Linger --value 2>/dev/null)" != "yes" ]]; then
  log "Enabling linger for ${USER}"
  sudo loginctl enable-linger "${USER}"
fi
waited=0
until systemctl --user show-environment &>/dev/null; do
  (( waited >= 30 )) && fail "systemd user manager for ${USER} is not reachable"
  sleep 2; waited=$(( waited + 2 ))
done

backup_service_changed="$(install_unit hermes-backup.service)"
backup_timer_changed="$(install_unit hermes-backup.timer)"
if [[ -n "${backup_service_changed}${backup_timer_changed}" ]]; then
  systemctl --user daemon-reload
fi
systemctl --user enable --now hermes-backup.timer
systemctl --user is-active --quiet hermes-backup.timer || fail "hermes-backup.timer is not active"
log "hermes-backup.timer is active (daily, archives in /mnt/backups)"

# ---------------------------------------------------------------------------
# 4. Diagnostics (informational: an unconfigured install reports problems)
# ---------------------------------------------------------------------------
log "Running hermes doctor"
hermes doctor </dev/null || log "hermes doctor reported problems (see output above)"

# ---------------------------------------------------------------------------
# 5. OpenAI-compatible local endpoint (opt-in): llama-swap / vLLM / llama.cpp
#    servers etc. The provider switch is deliberate — HERMES_LLM_* is the
#    source of truth for every re-run. The API key is only appended when the
#    env file has none; re-runs never rotate it.
# ---------------------------------------------------------------------------
llm_configured=false
if [[ -n "${HERMES_LLM_BASE_URL}" ]]; then
  [[ -n "${HERMES_LLM_MODEL}" ]] || fail "HERMES_LLM_MODEL is required when HERMES_LLM_BASE_URL is set"
  log "Configuring main model for local endpoint ${HERMES_LLM_BASE_URL} (model: ${HERMES_LLM_MODEL})"
  mkdir -p "${HERMES_HOME}"
  touch "${ENV_FILE}"
  # API key: read back before writing — an existing OPENAI_API_KEY is kept.
  if grep -q '^OPENAI_API_KEY=' "${ENV_FILE}" 2>/dev/null; then
    log "OPENAI_API_KEY already present in ${ENV_FILE} — keeping it"
  elif [[ -n "${HERMES_LLM_API_KEY}" ]]; then
    log "Storing the endpoint API key in ${ENV_FILE}"
    (umask 077; printf 'OPENAI_API_KEY=%s\n' "${HERMES_LLM_API_KEY}" >> "${ENV_FILE}")
  else
    log "No API key given — the endpoint must accept keyless requests"
  fi
  # Base URL is a layout value: updated on every run (in .env, where the
  # openai-api provider reads it, and in config.yaml for visibility).
  if grep -q '^OPENAI_BASE_URL=' "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^OPENAI_BASE_URL=.*|OPENAI_BASE_URL=${HERMES_LLM_BASE_URL}|" "${ENV_FILE}"
  else
    printf 'OPENAI_BASE_URL=%s\n' "${HERMES_LLM_BASE_URL}" >> "${ENV_FILE}"
  fi
  chmod 600 "${ENV_FILE}"
  hermes config set model.provider openai-api </dev/null \
    || fail "hermes config set model.provider failed"
  hermes config set model.base_url "${HERMES_LLM_BASE_URL}" </dev/null \
    || fail "hermes config set model.base_url failed"
  hermes config set model.default "${HERMES_LLM_MODEL}" </dev/null \
    || fail "hermes config set model.default failed"
  hermes config set model.api_mode chat_completions </dev/null \
    || fail "hermes config set model.api_mode failed"
  llm_configured=true
  log "Main model wired to ${HERMES_LLM_MODEL} via the openai-api provider"
fi

# ---------------------------------------------------------------------------
# 6. Messaging gateway (idles until platforms are configured with
#    `hermes setup`; `hermes gateway restart` picks up new settings)
# ---------------------------------------------------------------------------
if ! systemctl --user cat hermes-gateway.service &>/dev/null; then
  log "Installing the gateway user service"
  hermes gateway install </dev/null || fail "hermes gateway install failed"
elif [[ "${installer_ran}" == true || "${llm_configured}" == true ]]; then
  log "Restarting the gateway after the Hermes update / model endpoint change"
  hermes gateway restart </dev/null || true
fi
systemctl --user enable --now hermes-gateway.service
wait_active hermes-gateway.service

# ---------------------------------------------------------------------------
# 7. hermes serve (Desktop remote gateway / dashboard) — opt-in
# ---------------------------------------------------------------------------
if [[ "${HERMES_SERVE}" == true ]]; then
  # A non-loopback bind requires auth. Read back before generating: existing
  # credentials are never rotated.
  if ! grep -q '^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' "${ENV_FILE}" 2>/dev/null; then
    log "Generating dashboard basic-auth credentials in ${ENV_FILE}"
    mkdir -p "${HERMES_HOME}"
    (
      umask 077
      {
        echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin"
        echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$(openssl rand -hex 16)"
        echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -base64 32)"
      } >> "${ENV_FILE}"
    )
  fi
  chmod 600 "${ENV_FILE}"

  serve_changed="$(install_unit hermes-serve.service)"
  if [[ -n "${serve_changed}" || "${installer_ran}" == true ]]; then
    systemctl --user daemon-reload
    systemctl --user enable hermes-serve.service
    systemctl --user restart hermes-serve.service
  else
    systemctl --user enable --now hermes-serve.service
  fi
  wait_active hermes-serve.service

  waited=0
  until curl -s -o /dev/null --max-time 5 "http://127.0.0.1:${HERMES_SERVE_PORT}/"; do
    if (( waited >= WAIT_TIMEOUT )); then
      fail "hermes serve does not answer on port ${HERMES_SERVE_PORT} after ${WAIT_TIMEOUT}s"
    fi
    sleep 3; waited=$(( waited + 3 ))
  done
  log "hermes serve answers on port ${HERMES_SERVE_PORT}"
elif systemctl --user is-enabled --quiet hermes-serve.service 2>/dev/null; then
  log "HERMES_SERVE is not true, but hermes-serve.service is still enabled — left untouched."
  log "Disable it with: systemctl --user disable --now hermes-serve.service"
fi
