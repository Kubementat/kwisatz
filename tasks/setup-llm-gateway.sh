#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-llm-gateway.sh — private LiteLLM gateway in front of the llama-swap boxes
# =============================================================================
#
# DESCRIPTION:
#   Deploys one private, OpenAI- and Anthropic-compatible endpoint (the
#   gateway) in front of the llama-swap boxes. Agents use one base URL and one
#   key; LiteLLM picks the box that serves each request, pins every turn of a
#   session to the box that served turn 1 (prefix-cache reuse), honours hard
#   per-deployment capacity caps, and retries/fails over to a peer.
#
#   The gateway runs on this host at /srv/llm-gateway, listening on the
#   explicit addresses in gateway.yml. Nothing is exposed publicly and UFW is
#   not used for this port: Docker's published ports bypass UFW, so the source
#   allow-list is enforced in Docker's DOCKER-USER chain by a tagged
#   llm-gateway-firewall.service.
#
# KEY ACTIONS:
#   1. Pre-flight: Docker/Compose, python3+PyYAML, curl, envsubst, iptables,
#      DOCKER-USER, gateway.yml, assigned addresses, free port
#   2. Ensure /srv/llm-gateway/.env (mode 600, root): generate the master key
#      once, keep every existing value, require every referenced upstream key
#   3. Validate + render config.yaml, compose.ports.yml and firewall.sh
#   4. Start or converge the container, prove liveliness and /v1/models
#   5. Install + apply the DOCKER-USER source filter and its systemd unit
#   6. Print endpoint URLs, agent wiring and the break-glass path
#
# FILES:
#   <repo>/gateway.yml                     routing config (gitignored, you own it;
#                                          GATEWAY_YML overrides it)
#   ${LLM_GATEWAY_DIR}/.env                secrets (mode 600, root)
#   ${LLM_GATEWAY_DIR}/config.yaml         rendered LiteLLM config
#   ${LLM_GATEWAY_DIR}/compose.ports.yml   rendered explicit port bindings
#   ${LLM_GATEWAY_DIR}/firewall.sh         rendered DOCKER-USER filter
#   ${LLM_GATEWAY_DIR}/docker-compose.yml  static template + image/port
#
# FLAGS:
#   --check       Report state without changing anything (exit 0 only if all pass)
#   --render-only Validate + render the files, then exit without Docker
#   --force       Re-render and re-create the container (secrets are never rotated)
#   --warm        Warm shared-group models after start (loads weights!)
#   --interactive Show diffs and prompt before re-creating (needs a TTY)
#   -h, --help    Show this help
#
# ENVIRONMENT (defaults):
#   LLM_GATEWAY_DIR                /srv/llm-gateway
#   LLM_GATEWAY_PORT               <listen.port from gateway.yml>; a mismatch is exit 1
#   LLM_GATEWAY_IMAGE              versions.yml key litellm
#   GATEWAY_YML                    <repo>/gateway.yml
#   WAIT_TIMEOUT                   180
#   GATEWAY_WARM                   false
#   GATEWAY_STRICT_BACKENDS        false
#   GATEWAY_ALLOW_MISSING_ADDRESSES false
#   GATEWAY_ALLOW_NO_SOURCE_FILTER false
#
# BREAK-GLASS:
#   Stop the gateway with:
#     cd /srv/llm-gateway && sudo docker compose -f docker-compose.yml \
#       -f compose.ports.yml down
#   Agents keep working against http://<box>:9292/v1 with that box's key.
#
# RE-RUN POLICY:
#   Converge by default: re-render, then restart only when config.yaml changed,
#   re-create only when compose/.env changed, and never `down -v`. A restart or
#   re-create drops all session pins (no Redis) — expected, one cold prefill.
#
# See README_LLM_GATEWAY.md for the full operator guide.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
LIB_PATH="$(realpath "${SCRIPT_DIR}/../lib/helpers.sh")"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates/llm-gateway"

# shellcheck disable=SC1090
source "${LIB_PATH}" || {
  echo "[ERROR] Shared library not found: ${LIB_PATH}" >&2
  exit 1
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [--check|--render-only|--force|--warm|--interactive] [--help]

Private LiteLLM gateway in front of the llama-swap boxes. One base URL and one
key for every agent; the gateway picks the box, pins sessions and fails over.

${BOLD}Options:${RESET}
  --check             Report state only; exit 0 only when every check passes
  --render-only       Validate gateway.yml + .env and render the files, no Docker
  --force             Re-render and re-create the container (secrets preserved)
  --warm              Warm shared-group models after start (loads weights!)
  --interactive       Show rendered diffs and ask before re-creating (TTY only)
  -h, --help          Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  LLM_GATEWAY_DIR                 Generated project directory (/srv/llm-gateway)
  LLM_GATEWAY_PORT                Effective port; must equal listen.port
  LLM_GATEWAY_IMAGE               Pinned image ($(kw_image litellm))
  GATEWAY_YML                     Routing config (default: <repo>/gateway.yml)
  WAIT_TIMEOUT                    Health/smoke wait in seconds (180)
  GATEWAY_WARM                    Warm shared models after start (false)
  GATEWAY_STRICT_BACKENDS         Fail when a required backend is down (false)
  GATEWAY_ALLOW_MISSING_ADDRESSES Skip unassigned listen addresses (false)
  GATEWAY_ALLOW_NO_SOURCE_FILTER  Address binding only, no DOCKER-USER (false)

${BOLD}Endpoints${RESET} (after a successful run):
  OpenAI-compatible     http://<listen address>:<port>/v1
  Anthropic-compatible  http://<listen address>:<port>   (POST /v1/messages)
  Health (liveness)     http://<listen address>:<port>/health/liveliness

${BOLD}Secrets${RESET} live in ${LLM_GATEWAY_DIR:-/srv/llm-gateway}/.env (mode 600, root).
The rendered config contains only os.environ/NAME references.

${BOLD}Break-glass${RESET}: stop the gateway and keep using each box directly:
  cd /srv/llm-gateway && sudo docker compose -f docker-compose.yml \\
    -f compose.ports.yml down
  curl http://<box>:9292/v1/chat/completions -H "Authorization: Bearer <box key>"

${BOLD}Re-run policy${RESET}: converge by default. config.yaml changes restart the
container; compose/.env changes re-create it; secrets are never rotated. No
'down' and never 'down -v'.
EOF
}

# =============================================================================
# ARGUMENTS + CONFIGURATION
# =============================================================================

CHECK=false
FORCE=false
INTERACTIVE=false
RENDER_ONLY=false
WARM="${GATEWAY_WARM:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --check) CHECK=true ;;
    --force) FORCE=true ;;
    --interactive) INTERACTIVE=true ;;
    --render-only) RENDER_ONLY=true ;;
    --warm) WARM=true ;;
    *) error "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

if [[ "$INTERACTIVE" == "true" && ! -t 0 ]]; then
  error "--interactive requires a TTY (stdin is not a terminal); re-run from a login shell"
fi

: "${LLM_GATEWAY_DIR:=/srv/llm-gateway}"
LLM_GATEWAY_IMAGE="${LLM_GATEWAY_IMAGE:-$(kw_image litellm)}"
: "${WAIT_TIMEOUT:=180}"
: "${GATEWAY_STRICT_BACKENDS:=false}"
: "${GATEWAY_ALLOW_MISSING_ADDRESSES:=false}"
: "${GATEWAY_ALLOW_NO_SOURCE_FILTER:=false}"

GATEWAY_YML="${GATEWAY_YML:-${REPO_ROOT}/gateway.yml}"
if [[ "$GATEWAY_YML" != /* ]]; then
  GATEWAY_YML="${REPO_ROOT}/${GATEWAY_YML}"
fi

COMPOSE_FILE="${LLM_GATEWAY_DIR}/docker-compose.yml"
PORTS_FILE="${LLM_GATEWAY_DIR}/compose.ports.yml"
CONFIG_FILE="${LLM_GATEWAY_DIR}/config.yaml"
FIREWALL_SCRIPT="${LLM_GATEWAY_DIR}/firewall.sh"
ENV_FILE="${LLM_GATEWAY_DIR}/.env"
RENDERER="${SCRIPT_DIR}/render-llm-gateway-config.py"
CONTAINER="llm-gateway"
FIREWALL_CHAIN="KWISATZ-LLM-GATEWAY"
FIREWALL_UNIT="llm-gateway-firewall.service"
UNIT_FILE="/etc/systemd/system/${FIREWALL_UNIT}"

warn_moving_image "${LLM_GATEWAY_IMAGE}" "LLM_GATEWAY_IMAGE"

# Effective values filled by pre-flight.
LLM_GATEWAY_PORT="${LLM_GATEWAY_PORT:-}"
CONFIG_PORT=""
MASTER_KEY=""
declare -a ADDRESSES=()
declare -a MISSING_ADDRESSES=()
declare -a ALLOW_FROM=()
declare -a BACKEND_NAMES=()
declare -a BACKEND_URLS=()
declare -a BACKEND_KEYS=()
declare -a BACKEND_EFFORT=()
declare -a MODEL_NAMES=()
declare -a DEP_MODELS=()
declare -a DEP_IDS=()
declare -a DEP_BACKENDS=()
declare -a DEP_ORDERS=()
declare -a DEP_RESIDENT=()

STACK_CREATED_THIS_RUN=0
DIFF_DIR=""

cleanup_on_failure() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  if (( STACK_CREATED_THIS_RUN == 1 )); then
    warn "Setup failed (exit ${exit_code}) — removing the container started by this run."
    sudo docker compose -f "$COMPOSE_FILE" -f "$PORTS_FILE" down --remove-orphans 2>/dev/null || true
  fi
  [[ -n "$DIFF_DIR" ]] && rm -rf "$DIFF_DIR"
  _mktemp_cleanup
  return 0
}
trap cleanup_on_failure EXIT

# =============================================================================
# HELPERS
# =============================================================================

_dc() {
  # The .env file is root-owned 0600, so compose must read it as root.
  sudo docker compose -f "$COMPOSE_FILE" -f "$PORTS_FILE" "$@"
}

_hash() {
  local file="$1"
  if [[ ! -e "$file" ]]; then
    printf 'missing\n'
    return 0
  fi
  if [[ -r "$file" ]]; then
    sha256sum "$file" | awk '{print $1}'
  else
    sudo sha256sum "$file" | awk '{print $1}'
  fi
}

_env_get() {
  local file="$1" key="$2"
  if [[ -r "$file" ]]; then
    env_file_get "$file" "$key" 2>/dev/null || true
  else
    sudo sed -n "s/^[[:space:]]*${key}=//p" "$file" 2>/dev/null | tail -n1 || true
  fi
}

_env_set() {
  # Rewrite one KEY=VALUE line, preserving every other line (unknown keys too).
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktempfile env)"
  KEY="$key" VALUE="$value" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"] }
    index($0, k "=") == 1 { next }
    { print }
    END { print k "=" v }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f -- "$tmp"
}

_container_running() {
  local state
  state="$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null \
    || sudo docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null \
    || true)"
  [[ "$state" == "true" ]]
}

_container_exists() {
  docker inspect "$CONTAINER" >/dev/null 2>&1 || sudo docker inspect "$CONTAINER" >/dev/null 2>&1
}

_container_state() {
  local state
  # docker inspect writes a bare newline to stdout when the container does not
  # exist; strip newlines so callers can match on the first word.
  state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$CONTAINER" 2>/dev/null \
    || sudo docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "$CONTAINER" 2>/dev/null \
    || true)"
  state="$(tr -d '\n' <<< "$state")"
  printf '%s\n' "${state:-missing none}"
}

_probe_backend() {
  # Bounded GET /health, then GET /v1/models. Never a completion (C7).
  local base="${1%/}" key="${2:-}" health models
  local -a auth=()
  health="${base%/v1}/health"
  models="${base}/models"
  if [[ -n "$key" ]]; then
    auth=(-H "Authorization: Bearer ${key}")
  fi
  if curl -fsS --max-time 10 "${auth[@]}" "$health" >/dev/null 2>&1; then
    return 0
  fi
  curl -fsS --max-time 10 "${auth[@]}" "$models" >/dev/null 2>&1
}

_parse_plan() {
  # Parse --print-plan tab-separated records into the global arrays.
  #
  # Splitting with `IFS=$'\t' read` is wrong here: tab is IFS *whitespace*, so a
  # run of two tabs is one delimiter and the empty api_key_env field of a backend
  # that needs no key would silently shift `false` into the key name (and the
  # task would then demand a key called "false"). mapfile over tab-as-newline
  # keeps every field in its column, empty ones included.
  local plan="$1" line kind
  local -a fields
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    mapfile -t fields <<< "${line//$'\t'/$'\n'}"
    kind="${fields[0]}"
    case "$kind" in
      port) CONFIG_PORT="${fields[1]}" ;;
      address) ADDRESSES+=("${fields[1]}") ;;
      allow_from) ALLOW_FROM+=("${fields[1]}") ;;
      backend)
        BACKEND_NAMES+=("${fields[1]}")
        BACKEND_URLS+=("${fields[2]}")
        BACKEND_KEYS+=("${fields[3]}")
        BACKEND_EFFORT+=("${fields[4]}")
        ;;
      model) MODEL_NAMES+=("${fields[1]}") ;;
      deployment)
        DEP_MODELS+=("${fields[1]}")
        DEP_IDS+=("${fields[2]}")
        DEP_BACKENDS+=("${fields[3]}")
        DEP_ORDERS+=("${fields[4]}")
        DEP_RESIDENT+=("${fields[5]}")
        ;;
    esac
  done <<< "$plan"
}

_require_python() {
  command -v python3 >/dev/null 2>&1 \
    || error "python3 is not installed. Run tasks/setup-basics.sh first."
  python3 -c 'import yaml' >/dev/null 2>&1 \
    || error "PyYAML is not installed (required by the gateway renderer). Install with: sudo apt install python3-yaml"
  PYTHON_BIN="$(command -v python3)"
}

_require_tools() {
  local cmd
  for cmd in docker curl envsubst iptables openssl; do
    command -v "$cmd" >/dev/null 2>&1 || {
      case "$cmd" in
        docker) error "docker is not installed. Run tasks/setup-docker.sh first." ;;
        envsubst) error "envsubst is not installed. Install with: sudo apt-get install gettext-base" ;;
        iptables) error "iptables is not installed. Run tasks/setup-basics.sh first." ;;
        openssl) error "openssl is not installed. Install with: sudo apt install openssl" ;;
        *) error "$cmd is not installed." ;;
      esac
    }
  done
  docker compose version >/dev/null 2>&1 \
    || sudo docker compose version >/dev/null 2>&1 \
    || error "Docker Compose v2 is required ('docker compose'). Run tasks/setup-docker.sh first."
  docker info >/dev/null 2>&1 \
    || sudo docker info >/dev/null 2>&1 \
    || error "The Docker daemon is not running. Start it with: sudo systemctl start docker"

  if ! sudo iptables -S DOCKER-USER >/dev/null 2>&1; then
    if [[ "$GATEWAY_ALLOW_NO_SOURCE_FILTER" == "true" ]]; then
      warn "DOCKER-USER is unavailable — continuing with address binding only (GATEWAY_ALLOW_NO_SOURCE_FILTER=true)."
    else
      error "Docker's DOCKER-USER iptables chain was not found. Enable Docker iptables management (do not run Docker with --iptables=false), or set GATEWAY_ALLOW_NO_SOURCE_FILTER=true to rely on address binding only."
    fi
  fi
}

_require_gateway_yml() {
  if [[ -f "$GATEWAY_YML" && -r "$GATEWAY_YML" ]]; then
    success "Routing config: ${GATEWAY_YML}"
    return 0
  fi

  local example="${REPO_ROOT}/gateway.yml.example"
  if [[ ! -e "$GATEWAY_YML" && -f "$example" ]]; then
    if cp "$example" "$GATEWAY_YML" 2>/dev/null; then
      success "Created ${GATEWAY_YML} from gateway.yml.example"
    else
      warn "Could not create ${GATEWAY_YML} (permission denied). Copy ${example} there manually."
    fi
  fi

  cat >&2 <<EOF

${RED}[ERROR]${RESET} gateway.yml not found at ${GATEWAY_YML}

Edit it before the first run:
${BOLD}  - listen.addresses${RESET}   every address on THIS host to publish on
${BOLD}  - listen.allow_from${RESET}  source CIDRs allowed to reach the port
${BOLD}  - backends.*.base_url${RESET} each llama-swap box ("http://<host>:9292/v1")
${BOLD}  - backends.*.api_key_env${RESET} only when that box sets llama-swap apiKeys
${BOLD}  - models[].deployments[].model${RESET} each box's own llama-swap model id

Secrets go in ${ENV_FILE} (mode 600), never in gateway.yml.
EOF
  exit 1
}

_resolve_port() {
  if ! CONFIG_PORT="$(python3 "$RENDERER" --config "$GATEWAY_YML" --print-port 2>/dev/null)"; then
    error "gateway.yml failed validation — run: python3 ${RENDERER} --config ${GATEWAY_YML} --print-plan"
  fi
  if [[ -n "$LLM_GATEWAY_PORT" && "$LLM_GATEWAY_PORT" != "$CONFIG_PORT" ]]; then
    error "LLM_GATEWAY_PORT=${LLM_GATEWAY_PORT} does not match listen.port=${CONFIG_PORT} in ${GATEWAY_YML}"
  fi
  LLM_GATEWAY_PORT="$CONFIG_PORT"
  export LLM_GATEWAY_PORT
}

_load_plan() {
  local plan
  if ! plan="$(python3 "$RENDERER" --config "$GATEWAY_YML" --print-plan)"; then
    error "gateway.yml failed validation (see the errors above)"
  fi
  _parse_plan "$plan"
  (( ${#ADDRESSES[@]} > 0 )) || error "gateway.yml lists no usable listen address"
  (( ${#MODEL_NAMES[@]} > 0 )) || error "gateway.yml lists no public model"
}

_declared_addresses_unassigned() {
  # Print the declared listen addresses that no local interface owns.
  local assigned address
  assigned="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
  for address in "${ADDRESSES[@]}"; do
    grep -qxF "$address" <<< "$assigned" || printf '%s\n' "$address"
  done
}

_validate_addresses() {
  local address missing_address skip kept=()
  local -a missing=()
  mapfile -t missing < <(_declared_addresses_unassigned)
  MISSING_ADDRESSES=("${missing[@]}")

  if (( ${#missing[@]} > 0 )); then
    if [[ "$GATEWAY_ALLOW_MISSING_ADDRESSES" == "true" ]]; then
      warn "Skipping unassigned listen address(es): ${missing[*]} (GATEWAY_ALLOW_MISSING_ADDRESSES=true)"
      for address in "${ADDRESSES[@]}"; do
        skip=false
        for missing_address in "${missing[@]}"; do
          [[ "$address" == "$missing_address" ]] && skip=true && break
        done
        [[ "$skip" == "true" ]] || kept+=("$address")
      done
      ADDRESSES=("${kept[@]}")
      (( ${#ADDRESSES[@]} > 0 )) || error "No assigned listen address remains — fix gateway.yml or start the missing interface"
    else
      for address in "${missing[@]}"; do
        err_msg "listen address ${address} is not assigned to a local interface (check: ip -4 addr; NetBird: ip -4 addr show wt0; libvirt: ip -4 addr show virbr0)" || true
      done
      error "Unassigned listen address(es): ${missing[*]}. Start the interface, fix gateway.yml, or set GATEWAY_ALLOW_MISSING_ADDRESSES=true to skip them."
    fi
  fi
  success "All ${#ADDRESSES[@]} listen address(es) are assigned."
}

_check_port_free() {
  local holders
  holders="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E "[:.]${LLM_GATEWAY_PORT}$" || true)"
  [[ -n "$holders" ]] || return 0

  if [[ -f "$COMPOSE_FILE" && -f "$PORTS_FILE" ]] \
    && _dc ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${LLM_GATEWAY_PORT}->"; then
    info "Port ${LLM_GATEWAY_PORT} is already held by the llm-gateway container."
    return 0
  fi

  warn "Port ${LLM_GATEWAY_PORT} is already in use:"
  ss -ltnp 2>/dev/null | grep -E "[:.]${LLM_GATEWAY_PORT}[[:space:]]" >&2 || true
  error "Port ${LLM_GATEWAY_PORT} is held by a foreign process (see 'ss -ltnp' above)."
}

_ensure_env() {
  step "Ensuring gateway secrets"
  sudo install -d -m 0755 -o root -g root "$LLM_GATEWAY_DIR"

  if [[ ! -f "$ENV_FILE" ]]; then
    sudo install -m 0600 -o root -g root "${TEMPLATES_DIR}/env.template" "$ENV_FILE"
    success "Created ${ENV_FILE} (mode 600, root)"
  fi

  local work
  work="$(mktempfile env)"
  if [[ -r "$ENV_FILE" ]]; then
    cat "$ENV_FILE" > "$work"
  else
    # shellcheck disable=SC2024  # the redirect is by this user into a user-owned temp file
    sudo cat "$ENV_FILE" > "$work"
  fi

  local master
  master="$(_env_get "$work" LITELLM_MASTER_KEY)"
  if [[ -z "$master" ]]; then
    master="sk-$(openssl rand -hex 32)"
    _env_set "$work" LITELLM_MASTER_KEY "$master"
    success "Generated LITELLM_MASTER_KEY (sk- + 64 hex characters)"
  else
    info "Reusing the existing LITELLM_MASTER_KEY"
  fi

  local index name value missing=()
  declare -A seen_missing=()
  for index in "${!BACKEND_KEYS[@]}"; do
    name="${BACKEND_KEYS[$index]}"
    [[ -n "$name" ]] || continue
    value="$(_env_get "$work" "$name")"
    if [[ -z "$value" ]]; then
      [[ -n "${seen_missing[$name]:-}" ]] || missing+=("$name")
      seen_missing["$name"]=1
    elif [[ "$value" == *$'\r'* ]]; then
      error "${name} in ${ENV_FILE} contains a carriage return; env_file parsing would break"
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    err_msg "Missing or empty upstream key(s) in ${ENV_FILE}:" || true
    for name in "${missing[@]}"; do
      err_msg "  - ${name}   (add a line: ${name}=sk-...)" || true
    done
    error "Refusing to render: ${#missing[@]} referenced api_key_env value(s) are missing. Add them to ${ENV_FILE} and re-run."
  fi

  if sudo cmp -s "$work" "$ENV_FILE" 2>/dev/null; then
    sudo chown root:root "$ENV_FILE" 2>/dev/null || error "Cannot chown ${ENV_FILE} to root. Run: sudo chown root:root ${ENV_FILE}"
    sudo chmod 600 "$ENV_FILE" 2>/dev/null || error "Cannot chmod ${ENV_FILE} to 600. Run: sudo chmod 600 ${ENV_FILE}"
  else
    sudo install -m 0600 -o root -g root "$work" "$ENV_FILE"
    success "Updated ${ENV_FILE} (mode 600, root)"
  fi

  MASTER_KEY="$(_env_get "$ENV_FILE" LITELLM_MASTER_KEY)"
  [[ -n "$MASTER_KEY" ]] || error "LITELLM_MASTER_KEY is still empty in ${ENV_FILE}"

  info "Secret file: ${ENV_FILE}"
  info "Key names: LITELLM_MASTER_KEY${BACKEND_KEYS[*]:+ + referenced backend keys} (values never printed)"
}

_backend_reachability() {
  step "Checking backend reachability (no completions, no cold loads)"
  local index name key failures=0
  for index in "${!BACKEND_NAMES[@]}"; do
    [[ "${BACKEND_EFFORT[$index]}" == "true" ]] && continue
    name="${BACKEND_NAMES[$index]}"
    key=""
    if [[ -n "${BACKEND_KEYS[$index]}" ]]; then
      key="$(_env_get "$ENV_FILE" "${BACKEND_KEYS[$index]}")"
    fi
    if _probe_backend "${BACKEND_URLS[$index]}" "$key"; then
      success "Backend ${name} reachable (${BACKEND_URLS[$index]})"
    else
      failures=$((failures + 1))
      warn "Backend ${name} is not reachable at ${BACKEND_URLS[$index]} — the gateway still starts; requests retry and fail over."
    fi
  done

  if (( failures > 0 )) && [[ "$GATEWAY_STRICT_BACKENDS" == "true" ]]; then
    error "GATEWAY_STRICT_BACKENDS=true and ${failures} backend(s) are unreachable."
  fi
}

_render_compose() {
  command -v envsubst >/dev/null 2>&1 \
    || error "envsubst is not installed. Install with: sudo apt-get install gettext-base"
  local template="${TEMPLATES_DIR}/docker-compose.yml" tmp
  tmp="$(mktempfile docker-compose.yml)"
  export LLM_GATEWAY_IMAGE LLM_GATEWAY_PORT
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${LLM_GATEWAY_IMAGE} ${LLM_GATEWAY_PORT}' < "$template" > "$tmp"
  chmod 644 "$tmp"
  if [[ ! -f "$COMPOSE_FILE" ]] || ! sudo cmp -s "$tmp" "$COMPOSE_FILE"; then
    sudo install -m 0644 -o root -g root "$tmp" "$COMPOSE_FILE"
    info "Rendered ${COMPOSE_FILE}"
  fi
}

_render_gateway() {
  step "Validating gateway.yml and rendering the LiteLLM configuration"
  local -a args=(
    --config "$GATEWAY_YML"
    --env-file "$ENV_FILE"
    --out-dir "$LLM_GATEWAY_DIR"
    --port "$LLM_GATEWAY_PORT"
  )
  local address
  for address in "${MISSING_ADDRESSES[@]}"; do
    args+=(--exclude-address "$address")
  done
  sudo "$PYTHON_BIN" "$RENDERER" "${args[@]}"
  success "Rendered config.yaml, compose.ports.yml and firewall.sh"
}

_validate_compose() {
  step "Validating the rendered compose configuration"
  # Only the bindings can be wildcards: the generated header says "no 0.0.0.0
  # and no ::, ever", so grepping the raw file would flag its own comment.
  local offenders
  offenders="$(sed 's/#.*//' "$PORTS_FILE" | grep -nE '0\.0\.0\.0|\[::\]|"::' || true)"
  if [[ -n "$offenders" ]]; then
    error "compose.ports.yml contains a wildcard binding — refusing to start: ${offenders}"
  fi
  if ! _dc config >/dev/null; then
    error "docker compose config rejected the merged files (see the output above)"
  fi
  success "Compose configuration is valid; bindings are explicit."
}

_install_firewall_unit() {
  local tmp
  # Keep the operator guide next to the stack: the unit's Documentation= points
  # at ${LLM_GATEWAY_DIR}/README_LLM_GATEWAY.md.
  if [[ -f "${REPO_ROOT}/README_LLM_GATEWAY.md" ]]; then
    sudo install -m 0644 -o root -g root \
      "${REPO_ROOT}/README_LLM_GATEWAY.md" "${LLM_GATEWAY_DIR}/README_LLM_GATEWAY.md"
  fi

  tmp="$(mktempfile llm-gateway-firewall.service)"
  export LLM_GATEWAY_DIR
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${LLM_GATEWAY_DIR}' < "${TEMPLATES_DIR}/llm-gateway-firewall.service" > "$tmp"
  chmod 644 "$tmp"
  if [[ ! -f "$UNIT_FILE" ]] || ! sudo cmp -s "$tmp" "$UNIT_FILE"; then
    sudo install -m 0644 -o root -g root "$tmp" "$UNIT_FILE"
    sudo systemctl daemon-reload
  fi
}

_apply_firewall() {
  step "Applying the DOCKER-USER source filter"

  if [[ "$GATEWAY_ALLOW_NO_SOURCE_FILTER" == "true" ]]; then
    warn "GATEWAY_ALLOW_NO_SOURCE_FILTER=true — no DOCKER-USER rules installed; the explicit address bindings are the only exposure control."
    return 0
  fi

  [[ -f "$FIREWALL_SCRIPT" ]] || error "Rendered firewall script is missing: ${FIREWALL_SCRIPT}"
  sudo chmod 0755 "$FIREWALL_SCRIPT"

  _install_firewall_unit
  sudo systemctl enable "$FIREWALL_UNIT" >/dev/null
  # restart runs the oneshot even when it is already active, so a re-run
  # always re-applies the current allow-list.
  sudo systemctl restart "$FIREWALL_UNIT" \
    || error "Could not apply ${FIREWALL_UNIT} — see: sudo journalctl -u ${FIREWALL_UNIT}"
  success "Source filter applied and ${FIREWALL_UNIT} enabled."
}

_snapshot_for_diff() {
  [[ "$INTERACTIVE" == "true" ]] || return 0
  DIFF_DIR="$(mktemp -d)"
  local file
  for file in config.yaml compose.ports.yml docker-compose.yml firewall.sh; do
    if [[ -f "${LLM_GATEWAY_DIR}/${file}" ]]; then
      if [[ -r "${LLM_GATEWAY_DIR}/${file}" ]]; then
        cp "${LLM_GATEWAY_DIR}/${file}" "${DIFF_DIR}/${file}"
      else
        # shellcheck disable=SC2024  # the redirect is by this user into a user-owned temp file
        sudo cat "${LLM_GATEWAY_DIR}/${file}" > "${DIFF_DIR}/${file}" 2>/dev/null || true
      fi
    fi
  done
}

_show_diff() {
  local file
  for file in config.yaml compose.ports.yml docker-compose.yml firewall.sh; do
    if [[ -f "${DIFF_DIR}/${file}" ]]; then
      diff -u "${DIFF_DIR}/${file}" "${LLM_GATEWAY_DIR}/${file}" 2>/dev/null || true
    elif [[ -f "${LLM_GATEWAY_DIR}/${file}" ]]; then
      info "new file: ${LLM_GATEWAY_DIR}/${file}"
    fi
  done
}

_wait_liveliness() {
  local waited=0
  while (( waited <= WAIT_TIMEOUT )); do
    if _dc exec -T "$CONTAINER" python -c \
      "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${LLM_GATEWAY_PORT}/health/liveliness')" \
      >/dev/null 2>&1; then
      success "LiteLLM liveliness endpoint answered."
      return 0
    fi
    (( waited == WAIT_TIMEOUT )) && break
    sleep 3
    waited=$((waited + 3))
  done

  echo "--- container status ---" >&2
  _dc ps 2>/dev/null || true
  echo "--- last 100 log lines ---" >&2
  _dc logs --tail=100 2>/dev/null || true
  return 1
}

_smoke_models() {
  step "Smoke-testing the authenticated model list"
  local url body missing
  url="http://${ADDRESSES[0]}:${LLM_GATEWAY_PORT}/v1/models"
  body="$(mktempfile models.json)"
  if ! curl -fsS --max-time 30 -H "Authorization: Bearer ${MASTER_KEY}" "$url" -o "$body"; then
    error "Authenticated GET ${url} failed — the gateway is not answering on the published address."
  fi

  missing="$(python3 - "$body" "${MODEL_NAMES[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
listed = {item.get("id") for item in document.get("data", [])}
for name in sys.argv[2:]:
    if name not in listed:
        print(name)
PY
)"

  if [[ -n "$missing" ]]; then
    err_msg "GET /v1/models did not list these public model(s):" || true
    while IFS= read -r name; do
      if [[ -n "$name" ]]; then
        err_msg "  - ${name}" || true
      fi
    done <<< "$missing"
    err_msg "Rendered model_list lives in ${CONFIG_FILE}" || true
    error "Public model list mismatch."
  fi
  success "All ${#MODEL_NAMES[@]} public model name(s) are listed."
}

_warm_shared_models() {
  [[ "$WARM" == "true" ]] || return 0
  step "Warming shared model groups (this loads weights)"
  local url index model count primary_count attempts attempt header served observed failed=0 order
  declare -A counts=()
  declare -A primary_counts=()
  declare -A min_order=()
  declare -A seen=()

  for index in "${!DEP_MODELS[@]}"; do
    model="${DEP_MODELS[$index]}"
    order="${DEP_ORDERS[$index]}"
    counts["$model"]=$(( ${counts["$model"]:-0} + 1 ))
    if [[ -z "${min_order[$model]:-}" ]] || (( order < min_order[$model] )); then
      min_order["$model"]="$order"
    fi
  done
  for index in "${!DEP_MODELS[@]}"; do
    model="${DEP_MODELS[$index]}"
    if [[ "${DEP_ORDERS[$index]}" == "${min_order[$model]}" ]]; then
      primary_counts["$model"]=$(( ${primary_counts["$model"]:-0} + 1 ))
    fi
  done

  url="http://${ADDRESSES[0]}:${LLM_GATEWAY_PORT}/v1/chat/completions"
  for model in "${MODEL_NAMES[@]}"; do
    count="${counts[$model]:-0}"
    primary_count="${primary_counts[$model]:-0}"
    # Only load-balanced groups are warmed; a single-box model loads on request.
    (( count > 1 )) || continue
    info "Warming ${model} (${count} deployment(s), ${primary_count} in the primary tier)"
    # Weighted routing may favour one deployment, so send a few attempts and
    # stop as soon as every primary-tier deployment has been observed.
    attempts=$(( primary_count * 4 ))
    (( attempts >= 2 )) || attempts=2
    for (( attempt = 0; attempt < attempts; attempt++ )); do
      header="$(mktempfile warm.hdr)"
      if curl -fsS --max-time "$WAIT_TIMEOUT" -D "$header" -o /dev/null \
        -H "Authorization: Bearer ${MASTER_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
        "$url"; then
        served="$(awk 'BEGIN {IGNORECASE=1} /^x-litellm-model-id:/ {print $2}' "$header" | tr -d '\r' | tail -n1)"
        if [[ -n "$served" && -z "${seen[$served]:-}" ]]; then
          seen["$served"]=1
          info "  served by ${served}"
        fi
      else
        failed=1
        warn "Warm request for ${model} failed (a backend may still be loading)."
      fi

      observed=0
      for index in "${!DEP_IDS[@]}"; do
        [[ "${DEP_MODELS[$index]}" == "$model" ]] || continue
        [[ "${DEP_ORDERS[$index]}" == "${min_order[$model]}" ]] || continue
        [[ -n "${seen[${DEP_IDS[$index]}]:-}" ]] && observed=$((observed + 1))
      done
      (( observed >= primary_count )) && break
    done

    for index in "${!DEP_IDS[@]}"; do
      [[ "${DEP_MODELS[$index]}" == "$model" ]] || continue
      if [[ "${DEP_ORDERS[$index]}" != "${min_order[$model]}" ]]; then
        info "  ${DEP_IDS[$index]}: order ${DEP_ORDERS[$index]} (failover) — left cold until it is selected"
      elif [[ -z "${seen[${DEP_IDS[$index]}]:-}" ]]; then
        warn "  ${DEP_IDS[$index]} was not selected during warm-up (weighted routing); it loads on first real use"
      fi
    done
  done

  if (( failed == 1 )); then
    if [[ "$GATEWAY_STRICT_BACKENDS" == "true" ]]; then
      error "Warm-up failed with GATEWAY_STRICT_BACKENDS=true."
    fi
    warn "Some warm requests failed — those models load on first real use."
  fi
}

# =============================================================================
# --check (read-only)
# =============================================================================

CHECK_FAILURES=0
_check_pass() { printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$*"; }
_check_fail() {
  printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*"
  CHECK_FAILURES=$((CHECK_FAILURES + 1))
}
_check_warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }

_check_config_and_env() {
  local tmpdir render_ok=true plan address perms owner
  local -a exclude_args=()
  step "Configuration and secrets"

  if [[ ! -f "$GATEWAY_YML" || ! -r "$GATEWAY_YML" ]]; then
    _check_fail "gateway.yml missing or unreadable at ${GATEWAY_YML}"
    return 1
  fi

  if plan="$(python3 "$RENDERER" --config "$GATEWAY_YML" --print-plan)"; then
    _check_pass "gateway.yml validates"
  else
    _check_fail "gateway.yml fails validation (see the errors above)"
    return 1
  fi
  _parse_plan "$plan"
  LLM_GATEWAY_PORT="${CONFIG_PORT}"

  if [[ -n "${LLM_GATEWAY_PORT_OVERRIDE:-}" && "$LLM_GATEWAY_PORT_OVERRIDE" != "$CONFIG_PORT" ]]; then
    _check_fail "LLM_GATEWAY_PORT=${LLM_GATEWAY_PORT_OVERRIDE} does not match listen.port=${CONFIG_PORT}"
  else
    _check_pass "effective port ${CONFIG_PORT}"
  fi

  if [[ ! -f "$ENV_FILE" ]]; then
    _check_fail "secret file missing at ${ENV_FILE}"
    return 1
  fi

  perms="$(sudo stat -c '%a' "$ENV_FILE" 2>/dev/null || true)"
  owner="$(sudo stat -c '%U' "$ENV_FILE" 2>/dev/null || true)"
  if [[ "$perms" == "600" && "$owner" == "root" ]]; then
    _check_pass "${ENV_FILE} is mode 600, owned by root"
  else
    _check_fail "${ENV_FILE} must be mode 600 owned by root (found ${perms:-unknown} ${owner:-unknown})"
  fi

  # A declared address whose interface is down is skipped at apply time, so the
  # fresh render must skip it too — otherwise every check reports drift.
  while IFS= read -r address; do
    [[ -n "$address" ]] || continue
    exclude_args+=(--exclude-address "$address")
  done < <(_declared_addresses_unassigned)

  tmpdir="$(mktemp -d)"
  if sudo "$PYTHON_BIN" "$RENDERER" --config "$GATEWAY_YML" --env-file "$ENV_FILE" \
    --out-dir "$tmpdir" --port "$CONFIG_PORT" "${exclude_args[@]}" >/dev/null 2>&1; then
    _check_pass "every referenced api_key_env is present and non-empty"
  else
    _check_fail "gateway.yml + .env validation failed; run the task without --check to see every error"
    render_ok=false
  fi

  if [[ "$render_ok" == "true" ]]; then
    for file in config.yaml compose.ports.yml firewall.sh; do
      if [[ -f "${LLM_GATEWAY_DIR}/${file}" ]] && sudo cmp -s "${tmpdir}/${file}" "${LLM_GATEWAY_DIR}/${file}"; then
        _check_pass "${file} matches a fresh render"
      else
        _check_fail "${file} is missing or drifted from the rendered config"
      fi
    done
  fi
  rm -rf "$tmpdir"
  return 0
}

_check_runtime() {
  local state health url body missing index name key
  step "Runtime"

  state="$(_container_state)"
  health="${state#* }"
  if [[ "$state" == missing* ]]; then
    _check_fail "container ${CONTAINER} is not installed"
  elif [[ "$state" == running\ * && ( "$health" == "healthy" || "$health" == "none" ) ]]; then
    _check_pass "container ${CONTAINER} is running (health: ${health})"
  else
    _check_fail "container ${CONTAINER} is not running/healthy (${state})"
  fi

  if _dc exec -T "$CONTAINER" python -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${LLM_GATEWAY_PORT}/health/liveliness')" \
    >/dev/null 2>&1; then
    _check_pass "GET /health/liveliness answers"
  else
    _check_fail "GET /health/liveliness does not answer"
  fi

  MASTER_KEY="$(_env_get "$ENV_FILE" LITELLM_MASTER_KEY)"
  if [[ -z "$MASTER_KEY" ]]; then
    _check_fail "LITELLM_MASTER_KEY is missing or empty"
  else
    url="http://${ADDRESSES[0]}:${LLM_GATEWAY_PORT}/v1/models"
    body="$(mktempfile models-check.json)"
    if curl -fsS --max-time 30 -H "Authorization: Bearer ${MASTER_KEY}" "$url" -o "$body"; then
      missing="$(python3 - "$body" "${MODEL_NAMES[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
listed = {item.get("id") for item in document.get("data", [])}
for name in sys.argv[2:]:
    if name not in listed:
        print(name)
PY
)"
      if [[ -z "$missing" ]]; then
        _check_pass "authenticated /v1/models lists every public model"
      else
        _check_fail "authenticated /v1/models is missing: $(tr '\n' ' ' <<< "$missing")"
      fi
    else
      _check_fail "authenticated GET ${url} failed"
    fi
  fi

  for index in "${!BACKEND_NAMES[@]}"; do
    [[ "${BACKEND_EFFORT[$index]}" == "true" ]] && continue
    name="${BACKEND_NAMES[$index]}"
    key=""
    if [[ -n "${BACKEND_KEYS[$index]}" ]]; then
      key="$(_env_get "$ENV_FILE" "${BACKEND_KEYS[$index]}")"
    fi
    if _probe_backend "${BACKEND_URLS[$index]}" "$key"; then
      _check_pass "backend ${name} reachable"
    else
      _check_fail "backend ${name} unreachable at ${BACKEND_URLS[$index]}"
    fi
  done
}

_check_exposure() {
  local listeners address missing_bindings=0 jump_count chain_rules cidr ok skip unassigned_address
  local -a unassigned=()
  step "Exposure and firewall"

  mapfile -t unassigned < <(_declared_addresses_unassigned)

  listeners="$(ss -ltnH 2>/dev/null | awk '{print $4}' || true)"
  for address in "${ADDRESSES[@]}"; do
    skip=false
    for unassigned_address in "${unassigned[@]}"; do
      [[ "$address" == "$unassigned_address" ]] && skip=true && break
    done
    [[ "$skip" == "true" ]] && continue
    if grep -qxF "${address}:${LLM_GATEWAY_PORT}" <<< "$listeners"; then
      _check_pass "port ${LLM_GATEWAY_PORT} is bound on ${address}"
    else
      _check_fail "port ${LLM_GATEWAY_PORT} is not bound on ${address}"
      missing_bindings=1
    fi
  done

  for unassigned_address in "${unassigned[@]}"; do
    if [[ "$GATEWAY_ALLOW_MISSING_ADDRESSES" == "true" ]]; then
      _check_warn "declared address ${unassigned_address} is not assigned to a local interface — skipped (GATEWAY_ALLOW_MISSING_ADDRESSES=true)"
    else
      _check_fail "declared address ${unassigned_address} is not assigned to a local interface"
      missing_bindings=1
    fi
  done

  if grep -qE "^0\.0\.0\.0:${LLM_GATEWAY_PORT}$|^\[::\]:${LLM_GATEWAY_PORT}$" <<< "$listeners"; then
    _check_fail "a wildcard listener exists on port ${LLM_GATEWAY_PORT}"
  elif (( missing_bindings == 0 )); then
    _check_pass "no wildcard listener on port ${LLM_GATEWAY_PORT}"
  fi

  if [[ "$GATEWAY_ALLOW_NO_SOURCE_FILTER" == "true" ]]; then
    _check_warn "source filter not installed (GATEWAY_ALLOW_NO_SOURCE_FILTER=true)"
    _check_warn "llm-gateway-firewall.service not required"
    return 0
  fi

  chain_rules="$(sudo iptables -S "$FIREWALL_CHAIN" 2>/dev/null || true)"
  if [[ -z "$chain_rules" ]]; then
    _check_fail "iptables chain ${FIREWALL_CHAIN} is missing"
  else
    ok=true
    for cidr in "${ALLOW_FROM[@]}"; do
      if ! grep -qF -- "-s ${cidr} " <<< "$chain_rules" \
        || ! grep -qF -- "--dport ${LLM_GATEWAY_PORT}" <<< "$chain_rules"; then
        ok=false
      fi
    done
    if grep -qF -- "-p tcp --dport ${LLM_GATEWAY_PORT} -j DROP" <<< "$chain_rules"; then
      :
    else
      ok=false
    fi
    if [[ "$ok" == "true" ]]; then
      _check_pass "chain ${FIREWALL_CHAIN} allows every source CIDR and drops the rest"
    else
      _check_fail "chain ${FIREWALL_CHAIN} does not match the rendered allow-list"
    fi
  fi

  jump_count="$(sudo iptables -S DOCKER-USER 2>/dev/null | grep -cF -- "-j ${FIREWALL_CHAIN}" || true)"
  if [[ "$jump_count" == "1" ]]; then
    _check_pass "exactly one DOCKER-USER jump to ${FIREWALL_CHAIN}"
  else
    _check_fail "expected exactly one DOCKER-USER jump to ${FIREWALL_CHAIN}, found ${jump_count}"
  fi

  if systemctl is-enabled --quiet "$FIREWALL_UNIT" 2>/dev/null; then
    _check_pass "${FIREWALL_UNIT} is enabled"
  else
    _check_fail "${FIREWALL_UNIT} is not enabled"
  fi
  if systemctl is-active --quiet "$FIREWALL_UNIT" 2>/dev/null; then
    _check_pass "${FIREWALL_UNIT} is active"
  else
    _check_fail "${FIREWALL_UNIT} is not active"
  fi
}

run_check() {
  step "Checking the LLM gateway (read-only)"
  LLM_GATEWAY_PORT_OVERRIDE="$LLM_GATEWAY_PORT"

  if ! _check_config_and_env; then
    error "The gateway is not installed or gateway.yml is invalid — see the FAIL lines above."
  fi
  _check_runtime
  _check_exposure

  echo ""
  if (( CHECK_FAILURES > 0 )); then
    error "${CHECK_FAILURES} check(s) failed."
  fi
  success "All checks passed."
}

# =============================================================================
# MAIN
# =============================================================================

_require_python

if [[ "$CHECK" == "true" ]]; then
  run_check
  exit 0
fi

step "Pre-flight checks"

_require_gateway_yml
_resolve_port
_load_plan

if [[ "$RENDER_ONLY" != "true" ]]; then
  _require_tools
fi

_validate_addresses
if [[ "$RENDER_ONLY" != "true" ]]; then
  _check_port_free
fi

# Snapshot the installed files before this run changes anything, so converge
# decisions and --interactive diffs compare against what was really running.
BEFORE_CONFIG="$(_hash "$CONFIG_FILE")"
BEFORE_PORTS="$(_hash "$PORTS_FILE")"
BEFORE_COMPOSE="$(_hash "$COMPOSE_FILE")"
BEFORE_ENV="$(_hash "$ENV_FILE")"
CONTAINER_EXISTED=false
if _container_exists; then
  CONTAINER_EXISTED=true
fi
WAS_RUNNING=false
if _container_running; then
  WAS_RUNNING=true
fi

_snapshot_for_diff
_ensure_env

if [[ "$RENDER_ONLY" != "true" ]]; then
  _backend_reachability
fi

_render_compose
_render_gateway

if [[ "$RENDER_ONLY" == "true" ]]; then
  success "Render-only run complete — no container was touched."
  info "Files: ${CONFIG_FILE}, ${PORTS_FILE}, ${COMPOSE_FILE}, ${FIREWALL_SCRIPT}"
  exit 0
fi

_validate_compose

AFTER_CONFIG="$(_hash "$CONFIG_FILE")"
AFTER_PORTS="$(_hash "$PORTS_FILE")"
AFTER_COMPOSE="$(_hash "$COMPOSE_FILE")"
AFTER_ENV="$(_hash "$ENV_FILE")"

ACTION="none"
if [[ "$FORCE" == "true" ]]; then
  ACTION="recreate"
elif [[ "$CONTAINER_EXISTED" != "true" ]]; then
  ACTION="up"
elif [[ "$BEFORE_PORTS" != "$AFTER_PORTS" || "$BEFORE_COMPOSE" != "$AFTER_COMPOSE" || "$BEFORE_ENV" != "$AFTER_ENV" ]]; then
  ACTION="recreate"
elif [[ "$WAS_RUNNING" != "true" ]]; then
  ACTION="up"
elif [[ "$BEFORE_CONFIG" != "$AFTER_CONFIG" ]]; then
  ACTION="restart"
fi

if [[ "$INTERACTIVE" == "true" && "$FORCE" != "true" && "$ACTION" == "recreate" ]]; then
  echo ""
  info "Differences against the installed files:"
  _show_diff
  echo ""
  read -rp "    Re-create llm-gateway now? Converge is the default. [y/N] " _answer
  if [[ "${_answer,,}" == "y" ]]; then
    ACTION="recreate"
  else
    warn "Declined the re-create — compose/.env changes cannot be applied without it."
    warn "Run when ready:"
    warn "  cd ${LLM_GATEWAY_DIR} && sudo docker compose -f docker-compose.yml -f compose.ports.yml up -d --force-recreate ${CONTAINER}"
    if [[ "$WAS_RUNNING" == "true" && "$BEFORE_CONFIG" != "$AFTER_CONFIG" ]]; then
      ACTION="restart"
    else
      ACTION="none"
    fi
  fi
fi
if [[ -n "$DIFF_DIR" ]]; then
  rm -rf "$DIFF_DIR"
  DIFF_DIR=""
fi

_apply_firewall

step "Converging the gateway container"
case "$ACTION" in
  up)
    if [[ "$CONTAINER_EXISTED" != "true" ]]; then
      STACK_CREATED_THIS_RUN=1
    fi
    _dc up -d
    ;;
  recreate)
    if [[ "$CONTAINER_EXISTED" != "true" ]]; then
      STACK_CREATED_THIS_RUN=1
    fi
    _dc up -d --force-recreate "$CONTAINER"
    ;;
  restart)
    _dc restart "$CONTAINER"
    ;;
  none)
    info "Converged, no change — the running container stays untouched."
    ;;
esac

step "Waiting for LiteLLM to answer"
if ! _wait_liveliness; then
  error "The gateway did not become live within ${WAIT_TIMEOUT}s — see the status and logs above."
fi
STACK_CREATED_THIS_RUN=0

_smoke_models
_warm_shared_models

echo ""
success "LLM gateway is up."
echo ""
echo -e "${BOLD}Endpoints${RESET}"
for address in "${ADDRESSES[@]}"; do
  echo "  OpenAI:    http://${address}:${LLM_GATEWAY_PORT}/v1"
  echo "  Anthropic: http://${address}:${LLM_GATEWAY_PORT}"
done
echo ""
echo -e "${BOLD}Files${RESET}"
echo "  routing:  ${GATEWAY_YML}"
echo "  secrets:  ${ENV_FILE} (mode 600, root)"
echo "  config:   ${CONFIG_FILE}"
echo ""
echo -e "${BOLD}Next steps${RESET}"
echo "  - Wire agents:  ./tasks/sync-models.py --agents-only"
echo "  - Verify:       $0 --check"
echo "  - Break-glass:  http://<box>:9292/v1 with that box's llama-swap key"
echo "  - Full guide:   README_LLM_GATEWAY.md"
