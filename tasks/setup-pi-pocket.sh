#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-pi-pocket.sh — Install Pi Pocket (pi-pocket) in Docker Compose
# =============================================================================
#
# Description:
#   Deploys Pi Pocket, the multiplayer web app around the Pi coding agent
#   (https://github.com/TannerMidd/pi-pocket), with Docker Compose. Upstream
#   publishes no container image, so the script clones the pinned tag from
#   versions.yml and builds docker/Dockerfile locally (cf. setup-nanobot.sh);
#   the image is rebuilt only when that ref changes or FORCE=true.
#
#   All state lives in bind mounts under PI_POCKET_HOME, so the image stays
#   disposable. Secrets (provider keys) live in PI_POCKET_HOME/.env
#   (mode 600) and are reused on re-runs; the generated docker-compose.yml
#   contains no secret values.
#
# Usage:
#   ./setup-pi-pocket.sh                  # install with defaults
#   ./setup-pi-pocket.sh --help           # show help and all configuration options
#   PI_POCKET_TRAEFIK=true PI_POCKET_DOMAIN=pi.example.com ./setup-pi-pocket.sh
#
# Re-runs converge: the compose file is re-rendered, secrets are reused (never
# rotated), and 'docker compose up -d' reconciles the stack. See the plan:
# docs/plans/pi-pocket-docker-plan.md
# =============================================================================

set -euo pipefail

# Determine script directory and source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}


# ─────────────────────────────────────────────────────────────────────────────
# USAGE / HELP
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Deploys Pi Pocket (pi-pocket, https://github.com/TannerMidd/pi-pocket) with
Docker Compose. Upstream ships no container image: the source is cloned at the
tag pinned in versions.yml and built locally into a pi-pocket:<tag> image.
All state lives in bind mounts under PI_POCKET_HOME (default: /srv/pi-pocket).

${BOLD}Options:${RESET}
  --interactive   Offer converge/tear-down of an existing stack and prompt on
                  other risky conditions (default: converge, no prompt)
  -h, --help      Show this help and exit

${BOLD}Environment variables${RESET} (all optional):

  Installation:
    PI_POCKET_HOME          Data directory (default: /srv/pi-pocket)
    PI_POCKET_SRC           Source checkout used as build context
                            (default: \$PI_POCKET_HOME/src)
    PI_POCKET_SRC_REF       Git tag to check out / build
                            (default: the pi-pocket pin from versions.yml)
    PI_POCKET_IMAGE         Local image name built from the checkout
                            (default: pi-pocket:<tag without leading v>)
    FORCE                   "true" rebuilds the image even when the .built-ref
                            marker says it is current (default: false)

  Networking:
    PI_POCKET_PORT          Host port published for 8787 inside the container
                            (default: 8787)
    PI_POCKET_BIND          Host address the port is published on (default:
                            0.0.0.0; forced to 127.0.0.1 in Traefik mode)
    PI_POCKET_ACCESS        Access mode inside the container. Only "lan" is
                            supported; "local" cannot work behind a published
                            port and is rejected (default: lan)

  Traefik reverse-proxy integration (opt-in):
    PI_POCKET_TRAEFIK       Set to "true" to route through Traefik (default: false)
    PI_POCKET_DOMAIN        Domain for Traefik access (required when PI_POCKET_TRAEFIK=true)
    PROXY_NETWORK           Traefik's external Docker network name (default: proxy)

  Mounts:
    PI_POCKET_PI_DIR        Pi's agent folder, mounted at /home/node/.pi
                            (default: \$PI_POCKET_HOME/data/pi — isolated from
                            the host. Set it to \$HOME/.pi to share the host's
                            sign-ins, skills and sessions with the container;
                            that is a deliberate, security-relevant choice)
    PI_POCKET_WORKSPACE_DIR Projects directory, mounted at /workspace
                            (default: \$PI_POCKET_HOME/workspace)
    PI_POCKET_EXTRA_BINDS   Space-separated host:container pairs for extra
                            project folders, rendered into
                            docker-compose.override.yml (default: empty).
                            Example: PI_POCKET_EXTRA_BINDS="/srv/code:/workspace/code"

  App behaviour:
    PI_POCKET_BROWSER_ARGS  Chromium flags inside the container (default:
                            "--no-sandbox --disable-dev-shm-usage", required
                            for uid 1000 without user-namespace setup)

  Startup:
    WAIT_TIMEOUT            Max seconds to wait for the stack to become
                            healthy after 'docker compose up -d' (default: 240)

  Provider keys (ANTHROPIC_API_KEY, OPENAI_API_KEY, …) are NOT script
  variables: add them by hand to PI_POCKET_HOME/.env (mode 600). The compose
  file carries them only as \${VAR:-} placeholders resolved at runtime.

  The layout keys PI_POCKET_PORT, PI_POCKET_BIND, PI_POCKET_TRAEFIK,
  PI_POCKET_DOMAIN, PI_POCKET_ACCESS and PI_POCKET_BROWSER_ARGS are stored in
  that .env and reused on re-runs, so a converge run without exports keeps the
  installed port/mode. An explicit export on this run always wins; to move a
  converged run (e.g. loopback -> LAN), export the new value.

${BOLD}Examples:${RESET}
  $0
  PI_POCKET_PORT=9000 $0
  PI_POCKET_TRAEFIK=true PI_POCKET_DOMAIN=pi.example.com $0
  PI_POCKET_PI_DIR="\$HOME/.pi" $0   # share host Pi sign-ins (opt-in, read the warning)
EOF
  exit 0
}


# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive) INTERACTIVE=true ;;
    -h|--help) usage ;;
    *) error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done


# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these variables before running (or export them)
# ─────────────────────────────────────────────────────────────────────────────

# Capture operator-supplied values BEFORE defaults, so .env reuse cannot
# override an explicit export on this run (the planka POSTGRES_PASSWORD pattern).
_PI_POCKET_ACCESS_SUPPLIED="${PI_POCKET_ACCESS:-}"
_PI_POCKET_BROWSER_ARGS_SUPPLIED="${PI_POCKET_BROWSER_ARGS:-}"
_PI_POCKET_PORT_SUPPLIED="${PI_POCKET_PORT:-}"
_PI_POCKET_BIND_SUPPLIED="${PI_POCKET_BIND:-}"
_PI_POCKET_TRAEFIK_SUPPLIED="${PI_POCKET_TRAEFIK:-}"
_PI_POCKET_DOMAIN_SUPPLIED="${PI_POCKET_DOMAIN:-}"

PI_POCKET_HOME="${PI_POCKET_HOME:-/srv/pi-pocket}"
PI_POCKET_SRC_REF="${PI_POCKET_SRC_REF:-$(kw_version pi-pocket)}"
PI_POCKET_IMAGE="${PI_POCKET_IMAGE:-pi-pocket:${PI_POCKET_SRC_REF#v}}"
PI_POCKET_SRC="${PI_POCKET_SRC:-${PI_POCKET_HOME}/src}"
PI_POCKET_PORT="${PI_POCKET_PORT:-8787}"
PI_POCKET_BIND="${PI_POCKET_BIND:-0.0.0.0}"
PI_POCKET_ACCESS="${PI_POCKET_ACCESS:-lan}"
PI_POCKET_BROWSER_ARGS="${PI_POCKET_BROWSER_ARGS:---no-sandbox --disable-dev-shm-usage}"

# Traefik reverse-proxy integration (opt-in)
PI_POCKET_TRAEFIK="${PI_POCKET_TRAEFIK:-false}"
PI_POCKET_DOMAIN="${PI_POCKET_DOMAIN:-}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"

# Mounts (data / extensions / themes are derived, not overridable by design)
PI_POCKET_DATA_DIR="${PI_POCKET_HOME}/data"
PI_POCKET_EXTENSIONS_DIR="${PI_POCKET_HOME}/data/extensions"
PI_POCKET_THEMES_DIR="${PI_POCKET_HOME}/data/themes"
PI_POCKET_PI_DIR="${PI_POCKET_PI_DIR:-${PI_POCKET_HOME}/data/pi}"
PI_POCKET_WORKSPACE_DIR="${PI_POCKET_WORKSPACE_DIR:-${PI_POCKET_HOME}/workspace}"
PI_POCKET_EXTRA_BINDS="${PI_POCKET_EXTRA_BINDS:-}"

# Startup
FORCE="${FORCE:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-240}"

ENV_FILE="${PI_POCKET_HOME}/.env"
COMPOSE_FILE="${PI_POCKET_HOME}/docker-compose.yml"
OVERRIDE_FILE="${PI_POCKET_HOME}/docker-compose.override.yml"
BUILT_REF_FILE="${PI_POCKET_HOME}/.built-ref"
PI_POCKET_URL=""   # resolved in pre-flight


# ─────────────────────────────────────────────────────────────────────────────
# LOCAL HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# First non-loopback IPv4 address of this host (empty output if none found).
detect_lan_ip() {
  local ip
  for ip in $(hostname -I 2>/dev/null); do
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != 127.* && "$ip" != 169.254.* ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# All docker compose calls share the same files; with extra binds configured
# the override file is part of every invocation (passing -f disables compose's
# automatic override discovery, so it must be explicit).
compose() {
  if [[ -f "$OVERRIDE_FILE" ]]; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" "$@"
  else
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  fi
}


# ─────────────────────────────────────────────────────────────────────────────
# REUSE STORED SETTINGS — explicit export > stored .env > default
# ─────────────────────────────────────────────────────────────────────────────
#
# Read back BEFORE pre-flight, so the checks (access mode, Traefik, port
# conflict) see the values this run will actually use. Nothing is rotated —
# the write step further down re-emits exactly these values.

if [[ -f "$ENV_FILE" ]]; then
  info "Found ${ENV_FILE} — reusing its values (provider keys included)."
  if [[ -z "$_PI_POCKET_ACCESS_SUPPLIED" ]]; then
    _v="$(env_file_get "$ENV_FILE" PI_POCKET_ACCESS)"
    PI_POCKET_ACCESS="${_v:-lan}"
  fi
  if [[ -z "$_PI_POCKET_BROWSER_ARGS_SUPPLIED" ]]; then
    _v="$(env_file_get "$ENV_FILE" PI_POCKET_BROWSER_ARGS)"
    if [[ -n "$_v" ]]; then PI_POCKET_BROWSER_ARGS="$_v"; fi
  fi
  _v="$(env_file_get "$ENV_FILE" PI_POCKET_PORT)"
  if [[ -z "$_PI_POCKET_PORT_SUPPLIED" && -n "$_v" ]]; then PI_POCKET_PORT="$_v"; fi
  _v="$(env_file_get "$ENV_FILE" PI_POCKET_BIND)"
  if [[ -z "$_PI_POCKET_BIND_SUPPLIED" && -n "$_v" ]]; then PI_POCKET_BIND="$_v"; fi
  _v="$(env_file_get "$ENV_FILE" PI_POCKET_TRAEFIK)"
  if [[ -z "$_PI_POCKET_TRAEFIK_SUPPLIED" && -n "$_v" ]]; then PI_POCKET_TRAEFIK="$_v"; fi
  _v="$(env_file_get "$ENV_FILE" PI_POCKET_DOMAIN)"
  if [[ -z "$_PI_POCKET_DOMAIN_SUPPLIED" && -n "$_v" ]]; then PI_POCKET_DOMAIN="$_v"; fi
  unset _v
fi


# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Running pre-flight checks"

command -v docker >/dev/null 2>&1 || error "Docker is not installed — run setup-docker.sh first."
docker info >/dev/null 2>&1 || error "Docker daemon is not running. Start it with: sudo systemctl start docker"
command -v git >/dev/null 2>&1 || error "git is not installed — run setup-basics.sh first."
command -v envsubst >/dev/null 2>&1 || error "envsubst is not installed — apt-get install gettext-base."
command -v curl >/dev/null 2>&1 || error "curl is not installed."

case "$PI_POCKET_ACCESS" in
  lan)   ;;
  local) error "PI_POCKET_ACCESS=local cannot work behind a published port (it listens on the container's own 127.0.0.1) — use lan." ;;
  *)     error "Unsupported PI_POCKET_ACCESS '${PI_POCKET_ACCESS}' — v1 supports only lan (cloudflare/tailscale are manual .env paths, see docs/plans/pi-pocket-docker-plan.md)." ;;
esac

if [[ "$PI_POCKET_TRAEFIK" == "true" ]]; then
  ensure_proxy_network || error "Traefik proxy network '${PROXY_NETWORK}' not found — run setup-traefik.sh first."
  [[ -n "$PI_POCKET_DOMAIN" ]] || error "PI_POCKET_DOMAIN must be set when PI_POCKET_TRAEFIK=true."
  ensure_traefik_running
  PI_POCKET_BIND="127.0.0.1"
  PI_POCKET_URL="https://${PI_POCKET_DOMAIN}"
  _mode="traefik"
else
  _lan_ip="$(detect_lan_ip || true)"
  if [[ "$PI_POCKET_BIND" == "127.0.0.1" || "$PI_POCKET_BIND" == "localhost" ]]; then
    PI_POCKET_URL="http://localhost:${PI_POCKET_PORT}"
  else
    PI_POCKET_URL="http://${_lan_ip:-localhost}:${PI_POCKET_PORT}"
  fi
  _mode="direct"
fi
info "Mode: ${_mode}; public URL: ${PI_POCKET_URL}"

# Port conflict hint (a listener here will make 'up -d' fail or steal traffic).
if command -v ss >/dev/null 2>&1; then
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PI_POCKET_PORT}\$"; then
    warn "Port ${PI_POCKET_PORT} already has a listener — check for another service (PI_POCKET_PORT moves both sides)."
  fi
fi

# Warn up front when the host Pi folder is shared (decision 4 of the plan).
if [[ "$(realpath -m "$PI_POCKET_PI_DIR" 2>/dev/null || echo x)" == "$(realpath -m "$HOME/.pi" 2>/dev/null || echo y)" ]]; then
  warn "PI_POCKET_PI_DIR points at the host's \$HOME/.pi — the container will read the"
  warn "host's Pi sign-ins (auth.json), skills and sessions, and write its sessions there."
  warn "Anyone who steers a Pi Pocket session then commands that folder."
fi

success "Pre-flight checks passed."


# ─────────────────────────────────────────────────────────────────────────────
# SECRETS AND LAYOUT — REUSE WHAT IS THERE, NEVER ROTATE
# ─────────────────────────────────────────────────────────────────────────────
#
# ${ENV_FILE} holds the layout keys this script manages (ACCESS,
# BROWSER_ARGS, PORT, BIND, TRAEFIK, DOMAIN — read back and converged in the
# pre-flight section) plus whatever the operator adds by hand (provider keys).
# The compose file never contains secret values — only ${VAR} placeholders
# resolved at runtime via --env-file.

step "Writing ${ENV_FILE} (mode 600)"
# Re-runs must not rotate anything: keys we do not manage are carried over
# verbatim, and the managed keys are written last so they win (older, possibly
# indented duplicates of them are dropped here). No timestamp line — a no-op
# re-run produces byte-identical content.
_env_new="$(mktemp)"
{
  printf '# Pi Pocket — mode 600. Re-runs reuse these values; provider keys (e.g. ANTHROPIC_API_KEY) are added here by hand.\n'
  grep -vE '^[[:space:]]*(# Pi Pocket|PI_POCKET_(ACCESS|BROWSER_ARGS|PORT|BIND|TRAEFIK|DOMAIN)=)' "$ENV_FILE" 2>/dev/null || true
  printf 'PI_POCKET_ACCESS=%s\n'        "${PI_POCKET_ACCESS}"
  printf 'PI_POCKET_BROWSER_ARGS=%s\n'  "${PI_POCKET_BROWSER_ARGS}"
  printf 'PI_POCKET_PORT=%s\n'          "${PI_POCKET_PORT}"
  printf 'PI_POCKET_BIND=%s\n'          "${PI_POCKET_BIND}"
  printf 'PI_POCKET_TRAEFIK=%s\n'       "${PI_POCKET_TRAEFIK}"
  printf 'PI_POCKET_DOMAIN=%s\n'        "${PI_POCKET_DOMAIN}"
} > "$_env_new"

# Parent dir must exist before the install; storage dirs come one step later.
sudo mkdir -p "${PI_POCKET_HOME}"
if [[ -f "$ENV_FILE" ]] && ! sudo cmp -s "$_env_new" "$ENV_FILE"; then
  sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "$ENV_FILE" "${ENV_FILE}.bak"
fi
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "$_env_new" "$ENV_FILE"
rm -f "$_env_new"
success "Settings stored in ${ENV_FILE} (mode 600, owner: $(id -un))."


# ─────────────────────────────────────────────────────────────────────────────
# STOP & REMOVE EXISTING COMPOSE STACK (if any)
# ─────────────────────────────────────────────────────────────────────────────

step "Checking for an existing Pi Pocket compose stack"

if [[ -f "$COMPOSE_FILE" ]]; then
  warn "Existing docker-compose.yml found at ${COMPOSE_FILE}."
  # Re-run policy: the stack is CONVERGED — compose file re-rendered, secrets
  # reused (never rotated), 'docker compose up -d' reconciles. Tear-down only
  # on explicit interactive 'y'.
  info "Re-running will converge the existing stack (no tear-down). State under ${PI_POCKET_HOME}/data is preserved."
  RECREATE=false
  if [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "    Stack exists. Converge (default) or tear down and re-create? [y/N] " answer
    [[ "${answer,,}" == "y" ]] && RECREATE=true
  fi
  if [[ "$RECREATE" == "true" ]]; then
    info "Stopping and removing existing stack..."
    compose down || true
    success "Old stack removed."
  fi
fi


# ─────────────────────────────────────────────────────────────────────────────
# CREATE HOST DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────

step "Creating host directories under ${PI_POCKET_HOME}"

sudo mkdir -p "${PI_POCKET_DATA_DIR}/extensions" "${PI_POCKET_DATA_DIR}/themes" \
              "${PI_POCKET_DATA_DIR}/pi" "${PI_POCKET_WORKSPACE_DIR}"

# Everything under the data root must be writable by uid 1000 (the container's
# user). An PI_POCKET_PI_DIR outside the root (e.g. $HOME/.pi) is deliberately
# left alone — its ownership is the operator's decision.
if [[ ! -d "$PI_POCKET_PI_DIR" ]]; then
  sudo mkdir -p "$PI_POCKET_PI_DIR"
fi
if [[ "$(realpath -m "$PI_POCKET_PI_DIR")" == "$(realpath -m "$PI_POCKET_HOME")"* ]]; then
  sudo chown -R 1000:1000 "$PI_POCKET_PI_DIR" || warn "Could not chown ${PI_POCKET_PI_DIR}."
else
  warn "PI_POCKET_PI_DIR is outside ${PI_POCKET_HOME} — leaving its ownership alone."
  warn "Make sure it is owned by uid/gid 1000 or the container cannot write it."
fi
sudo chown -R 1000:1000 "${PI_POCKET_HOME}/data" "${PI_POCKET_WORKSPACE_DIR}" 2>/dev/null || {
  warn "Could not change ownership of ${PI_POCKET_HOME}. You may need to run this script with sudo."
}
success "Directories ready."


# ─────────────────────────────────────────────────────────────────────────────
# GENERATE DOCKER COMPOSE FILES
# ─────────────────────────────────────────────────────────────────────────────

step "Generating ${COMPOSE_FILE}"

TEMPLATE_DIR="${SCRIPT_DIR}/../templates/pi-pocket"
TEMPLATE_FILE="${TEMPLATE_DIR}/docker-compose.${_mode}.yml"
_tmp="$(mktemp)"

# Export layout values ONLY — no secrets. ${VAR} defaults in the template
# (provider keys, ACCESS, BROWSER_ARGS) are intentionally NOT in this list:
# envsubst leaves them literal so compose resolves them from ${ENV_FILE}.
export PI_POCKET_IMAGE PI_POCKET_SRC PI_POCKET_PORT PI_POCKET_BIND \
       PI_POCKET_DATA_DIR PI_POCKET_EXTENSIONS_DIR PI_POCKET_THEMES_DIR \
       PI_POCKET_PI_DIR PI_POCKET_WORKSPACE_DIR
if [[ "$_mode" == "traefik" ]]; then
  export PROXY_NETWORK PI_POCKET_DOMAIN
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${PI_POCKET_IMAGE} ${PI_POCKET_SRC} ${PI_POCKET_PORT} ${PI_POCKET_BIND} ${PROXY_NETWORK} ${PI_POCKET_DOMAIN} ${PI_POCKET_DATA_DIR} ${PI_POCKET_EXTENSIONS_DIR} ${PI_POCKET_THEMES_DIR} ${PI_POCKET_PI_DIR} ${PI_POCKET_WORKSPACE_DIR}' \
    < "$TEMPLATE_FILE" > "$_tmp"
else
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${PI_POCKET_IMAGE} ${PI_POCKET_SRC} ${PI_POCKET_PORT} ${PI_POCKET_BIND} ${PI_POCKET_DATA_DIR} ${PI_POCKET_EXTENSIONS_DIR} ${PI_POCKET_THEMES_DIR} ${PI_POCKET_PI_DIR} ${PI_POCKET_WORKSPACE_DIR}' \
    < "$TEMPLATE_FILE" > "$_tmp"
fi
sudo install -m 644 -o "$(id -un)" -g "$(id -gn)" "$_tmp" "$COMPOSE_FILE"
rm -f "$_tmp"
success "docker-compose.yml written to ${COMPOSE_FILE}"

# Extra binds: a rendered override file next to the main one, removed when the
# variable is unset, so stale project folders never linger.
if [[ -n "$PI_POCKET_EXTRA_BINDS" ]]; then
  info "Rendering ${OVERRIDE_FILE} from PI_POCKET_EXTRA_BINDS"
  _ovr="$(mktemp)"
  {
    printf '# Generated by setup-pi-pocket.sh — extra binds from PI_POCKET_EXTRA_BINDS.\n'
    printf '# Delete this file (or unset the variable and re-run) to remove the mounts.\n'
    printf 'services:\n  pi-pocket:\n    volumes:\n'
    _pairs=(); read -ra _pairs <<< "$PI_POCKET_EXTRA_BINDS"
    for _p in "${_pairs[@]}"; do
      [[ "$_p" == /*:/* ]] || error "PI_POCKET_EXTRA_BINDS entry '$_p' is not host:container (both sides must be absolute paths)"
      printf '      - %s\n' "$_p"
    done
  } > "$_ovr"
  sudo install -m 644 -o "$(id -un)" -g "$(id -gn)" "$_ovr" "$OVERRIDE_FILE"
  rm -f "$_ovr"
else
  sudo rm -f "$OVERRIDE_FILE"
fi

# The compose command shown to the user afterwards — the same files the
# internal compose() helper uses, so copy-pasteed commands include extra binds.
COMPOSE_CMD="docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE}"
if [[ -f "$OVERRIDE_FILE" ]]; then
  COMPOSE_CMD+=" -f ${OVERRIDE_FILE}"
fi


# ─────────────────────────────────────────────────────────────────────────────
# SOURCE CHECKOUT + IMAGE BUILD (marker-gated; upstream ships no image)
# ─────────────────────────────────────────────────────────────────────────────

step "Preparing the source checkout at ${PI_POCKET_SRC_REF}"

if [[ -d "${PI_POCKET_SRC}/.git" ]]; then
  if [[ -n "$(git -C "$PI_POCKET_SRC" status --porcelain)" ]]; then
    error "${PI_POCKET_SRC} has uncommitted changes (an edited build context?). Commit or remove them, then re-run."
  fi
  git -C "$PI_POCKET_SRC" fetch --tags --quiet origin || error "git fetch failed (network?)"
else
  info "Cloning https://github.com/TannerMidd/pi-pocket to ${PI_POCKET_SRC}"
  sudo mkdir -p "$PI_POCKET_SRC" && sudo chown "$(id -u):$(id -g)" "$PI_POCKET_SRC"
  git clone --quiet https://github.com/TannerMidd/pi-pocket "$PI_POCKET_SRC" \
    || error "git clone failed (network?)"
fi
git -C "$PI_POCKET_SRC" checkout --quiet --detach "$PI_POCKET_SRC_REF" \
  || error "cannot check out ${PI_POCKET_SRC_REF} (network, or the tag was removed)"
# Keep the checkout owned by the invoking user: it is only the build context
# (never mounted into the container), and root-owned files would trip git's
# dubious-ownership check in the 'git status'/'git fetch' of the next run.
sudo chown -R "$(id -u):$(id -g)" "$PI_POCKET_SRC" 2>/dev/null || warn "Could not chown ${PI_POCKET_SRC}."

# The digest is a hint that the tag was moved under us — warn, never fail.
if [[ "$(git -C "$PI_POCKET_SRC" rev-parse HEAD)" != "$(kw_pin pi-pocket digest)" ]]; then
  warn "${PI_POCKET_SRC_REF} resolves to $(git -C "$PI_POCKET_SRC" rev-parse --short HEAD),"
  warn "not the commit pinned in versions.yml ($(kw_pin pi-pocket digest | cut -c1-7)). Verify deliberately."
fi

step "Building the image (only when the ref changed)"
if [[ "$FORCE" == "true" ]] || [[ ! -f "$BUILT_REF_FILE" ]] \
   || ! docker image inspect "$PI_POCKET_IMAGE" >/dev/null 2>&1 \
   || [[ "$(cat "$BUILT_REF_FILE" 2>/dev/null)" != "$PI_POCKET_SRC_REF" ]]; then
  info "Building ${PI_POCKET_IMAGE} from ${PI_POCKET_SRC} (Node + Chromium; this can take several minutes)..."
  compose build || error "Image build failed — see the output above."
  printf '%s\n' "$PI_POCKET_SRC_REF" | sudo tee "$BUILT_REF_FILE" >/dev/null
  success "Built ${PI_POCKET_IMAGE} at ${PI_POCKET_SRC_REF}."
else
  info "Image ${PI_POCKET_IMAGE} is current for ${PI_POCKET_SRC_REF}; skipping the build (FORCE=true to rebuild)."
fi


# ─────────────────────────────────────────────────────────────────────────────
# START THE STACK + HEALTH GATES
# ─────────────────────────────────────────────────────────────────────────────

step "Starting Pi Pocket stack (detached)"
compose up -d

# Health gate: prove the containers are actually up before reporting success.
mapfile -t _ids < <(compose ps -q)
wait_for_healthy "${WAIT_TIMEOUT}" "${_ids[@]}" \
  || error "Pi Pocket stack did not come up — see '${COMPOSE_CMD} logs'"

# HTTP readiness on the published (loopback-reachable) port, bounded.
step "Waiting for the web UI on ${PI_POCKET_BIND}:${PI_POCKET_PORT}"
# 0.0.0.0 is reachable via loopback; an explicit bind must be polled directly.
if [[ "$PI_POCKET_BIND" == "0.0.0.0" ]]; then _poll=127.0.0.1; else _poll="$PI_POCKET_BIND"; fi
MAX_WAIT=120
INTERVAL=5
ELAPSED=0
READY=false
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://${_poll}:${PI_POCKET_PORT}" || true)"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" ]]; then
    READY=true
    break
  fi
  echo -ne "\r    Waited ${ELAPSED}s / ${MAX_WAIT}s (HTTP ${HTTP_CODE:-?}) ..."
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo ""
if [[ "$READY" == "true" ]]; then
  success "Pi Pocket is responding (HTTP ${HTTP_CODE})."
else
  warn "Pi Pocket did not respond within ${MAX_WAIT}s — it may still be starting; check the logs below."
fi


# ─────────────────────────────────────────────────────────────────────────────
# OWNER SIGN-IN LINK (cosmetic fix for a container-internal address)
# ─────────────────────────────────────────────────────────────────────────────
#
# The launcher prints the owner sign-in link with the container's own address
# (often 172.x.x.x), which nothing off-host can open. Keep the path + token and
# swap in the public URL. Non-fatal by design: if the log line format changes,
# print the raw line rather than fail the run.

step "Owner sign-in link"
# The newest line wins: compose logs survive restarts, so head -n1 would
# print an old, likely already-consumed token on every converge re-run.
link="$(compose logs --no-log-prefix 2>/dev/null | grep -oE '[^[:space:]]*/login\?token=[^[:space:]]*' | tail -n1 || true)"
if [[ -n "$link" ]]; then
  if [[ "$link" == *"://"* ]]; then
    _hp="${link#*://}"; path="/${_hp#*/}"        # drop scheme + host, keep /login?token=...
  else
    path="/${link#/}"
  fi
  success "Owner sign-in link (one use per browser; treat it as credential material):"
  echo -e "    ${BOLD}${PI_POCKET_URL}${path}${RESET}"
  warn "The raw log line names the container's own address; ${PI_POCKET_URL} is where it is reachable."
else
  warn "No /login?token= line found in the logs yet — read it later with:"
  echo -e "    ${COMPOSE_CMD} logs | grep '/login?token='"
fi


# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Pi Pocket setup complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Mode${RESET}             ${_mode}"
echo -e "  ${BOLD}URL${RESET}              ${PI_POCKET_URL}"
if [[ "$_mode" != "traefik" ]]; then
  echo -e "  ${BOLD}Local port${RESET}       http://localhost:${PI_POCKET_PORT}  (published on ${PI_POCKET_BIND})"
fi
echo -e "  ${BOLD}Image${RESET}            ${PI_POCKET_IMAGE}  (built from ${PI_POCKET_SRC_REF})"
echo -e "  ${BOLD}State${RESET}            ${PI_POCKET_DATA_DIR}  (+ extensions/, themes/, pi/, workspace/ under it)"
echo -e "  ${BOLD}Pi folder${RESET}        ${PI_POCKET_PI_DIR}"
echo -e "  ${BOLD}Workspace${RESET}        ${PI_POCKET_WORKSPACE_DIR}"
echo -e "  ${BOLD}Settings${RESET}         ${ENV_FILE}  (mode 600 — add provider keys here)"
echo -e "  ${BOLD}Compose file${RESET}     ${COMPOSE_FILE}"
echo ""
warn "State and provider keys live in the bind mounts, not in the image. Keep the"
warn "port off the public internet. Anyone who steers a session runs commands in"
warn "this container as uid 1000 — that is the real security boundary."
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Follow logs        :  ${COMPOSE_CMD} logs -f"
echo -e "  Stop stack         :  ${COMPOSE_CMD} down"
echo -e "  Start stack        :  ${COMPOSE_CMD} up -d"
echo -e "  Shell into app     :  docker exec -it pi-pocket bash"
echo -e "  Rebuild image      :  FORCE=true $0"
if [[ "$_mode" == "traefik" ]]; then
  echo ""
  echo -e "${CYAN}  # Traefik-specific debug commands${RESET}"
  echo -e "  Check access logs:  docker logs traefik | grep ${PI_POCKET_DOMAIN}"
  echo -e "  Verify DNS        :  dig ${PI_POCKET_DOMAIN}"
fi
echo ""
