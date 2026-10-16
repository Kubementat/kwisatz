#!/usr/bin/env bash
# =============================================================================
# setup-hermes.sh — Install Hermes Agent in a dedicated KVM virtual machine
# =============================================================================
#
# Description:
#   Provisions a KVM guest via virt-runner and installs Hermes Agent natively
#   inside it (official installer, non-root user, systemd user services). The
#   VM is the isolation boundary: Hermes gets a whole machine with passwordless
#   sudo, while the host controls what the VM may reach.
#
#   This script:
#     1. Ensures the virtualization prerequisites (runs setup-virtualization.sh
#        and setup-virt-runner.sh when they are missing)
#     2. Creates the VM if absent, starts it if stopped — never destroys it —
#        and reserves a static address for it
#     3. Applies the network policy: a libvirt network filter that lets the VM
#        reach the internet and an allowlist of LAN/host endpoints only
#     4. Installs Hermes Agent at a pinned commit inside the guest
#     5. Starts the gateway service and, opt-in, the
#        `hermes serve` backend for Hermes Desktop / the dashboard
#
#   Design and background: docs/plans/hermes-vm-refactor.md,
#   docs/research/hermes-agent-vm-install.md. Moving an existing Docker-based
#   install into the VM is a one-off manual procedure:
#   docs/hermes-docker-to-vm-migration.md.
#
# Environment Variables (all optional unless noted):
#   HERMES_VM_NAME           - VM name (default: hermes)
#   HERMES_VM_RAM            - Guest RAM in GiB, used at create only (default: 4)
#   HERMES_VM_VCPU           - vCPU count, used at create only (default: 2)
#   HERMES_VM_DISK           - Disk size in GiB, used at create only (default: 50)
#   HERMES_VM_IP             - Static address on the libvirt 'default' network
#                              (default: address .50 on that network)
#   HERMES_COMMIT            - hermes-agent commit to install (default: pinned)
#   HERMES_HOST_DIRECTORY    - Host directory shared with the VM (default: /srv/hermes)
#   HERMES_ALLOWED_ENDPOINTS - LAN/host endpoints the VM may reach (default: none)
#   HERMES_SERVE             - "true" to run `hermes serve` for Desktop/dashboard
#   HERMES_SERVE_PORT        - Port of `hermes serve` and the host proxy (default: 9119)
#   HERMES_SERVE_ALLOW_FROM  - Source allowed to reach the port (required with HERMES_SERVE)
#   HERMES_TRAEFIK           - "true" to add a Traefik route (needs HERMES_SERVE)
#   HERMES_DOMAIN            - Domain for the Traefik route (required with HERMES_TRAEFIK)
#   HERMES_LLM_BASE_URL      - OpenAI-compatible endpoint URL to wire the Hermes
#                              main model to (llama-swap/vLLM/llama.cpp-server);
#                              also added to the egress allowlist automatically
#   HERMES_LLM_MODEL         - Model id for that endpoint (required with BASE_URL)
#   HERMES_LLM_API_KEY       - Optional API key (written into the guest's
#                              ~/.hermes/.env only if absent, never rotated)
#   WAIT_TIMEOUT             - Max seconds for each bounded wait (default: 180)
#
# Options:
#   -h, --help   - Show help and exit
#
# Usage:
#   ./setup-hermes.sh
#   HERMES_ALLOWED_ENDPOINTS="host:3000 192.168.1.20:8080-8090" ./setup-hermes.sh
#   HERMES_SERVE=true HERMES_SERVE_ALLOW_FROM=192.168.1.0/24 ./setup-hermes.sh
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

# =============================================================================
# Configuration
# =============================================================================

HERMES_VM_NAME="${HERMES_VM_NAME:-hermes}"
HERMES_VM_RAM="${HERMES_VM_RAM:-4}"
HERMES_VM_VCPU="${HERMES_VM_VCPU:-2}"
HERMES_VM_DISK="${HERMES_VM_DISK:-50}"
# Empty = address .50 on the libvirt network (resolved once the network is known).
HERMES_VM_IP="${HERMES_VM_IP:-}"
# Pinned on purpose: the official installer follows the moving `main` branch
# unless a commit is given. Default looked up 2026-10-01: release
# "Hermes Agent v0.21.5", git tag v2026.9.24 (2026-09-24), which is on main.
# Update deliberately: git ls-remote --tags https://github.com/NousResearch/hermes-agent
# (use the peeled `^{}` SHA of the release tag).
HERMES_COMMIT="${HERMES_COMMIT:-f97608f178d1ffeca59860195ab7da295f7c8e5f}"
HERMES_HOST_DIRECTORY="${HERMES_HOST_DIRECTORY:-/srv/hermes}"
HERMES_ALLOWED_ENDPOINTS="${HERMES_ALLOWED_ENDPOINTS:-}"
HERMES_SERVE="${HERMES_SERVE:-false}"
HERMES_SERVE_PORT="${HERMES_SERVE_PORT:-9119}"
HERMES_SERVE_ALLOW_FROM="${HERMES_SERVE_ALLOW_FROM:-}"
HERMES_TRAEFIK="${HERMES_TRAEFIK:-false}"
HERMES_DOMAIN="${HERMES_DOMAIN:-}"
# Local/private-LLM wiring (all optional; the provider switch is deliberate on
# every re-run — these values are the source of truth for the main model).
HERMES_LLM_BASE_URL="${HERMES_LLM_BASE_URL:-}"
HERMES_LLM_MODEL="${HERMES_LLM_MODEL:-}"
HERMES_LLM_API_KEY="${HERMES_LLM_API_KEY:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"

# Shared with setup-traefik.sh (only used when HERMES_TRAEFIK=true)
TRAEFIK_HOME="${TRAEFIK_HOME:-/opt/traefik}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"

# Fixed layout (virt-runner defaults; not configurable on purpose)
TEMPLATES_DIR="${SCRIPT_DIR}/../templates/hermes"
LIBVIRT_NETWORK="default"
GUEST_USER="ubuntu"
GUEST_SSH_KEY="${HOME}/.ssh/virt_runner_key"
GUEST_PROVISION_DIR=".kwisatz-hermes"
HERMES_NWFILTER_NAME="${HERMES_VM_NAME}-egress"
HOST_WORKSPACE_DIR="${HERMES_HOST_DIRECTORY}/workspace"
HOST_BACKUP_DIR="${HERMES_HOST_DIRECTORY}/backups"

# virt-runner manages VMs on the system libvirt instance; virsh must match.
export LIBVIRT_DEFAULT_URI="qemu:///system"
# uv tools (virt-runner) live here; not on PATH in every non-login shell.
export PATH="${HOME}/.local/bin:${PATH}"

# =============================================================================
# USAGE / HELP
# =============================================================================

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs Hermes Agent natively inside a dedicated KVM virtual machine created
with virt-runner. The VM is the sandbox: Hermes runs there with a local
terminal backend and passwordless sudo, while a host-enforced network filter
limits which LAN/host endpoints the VM can reach (the internet stays open).
Missing virtualization prerequisites are installed by running
setup-virtualization.sh and setup-virt-runner.sh.

${BOLD}Options:${RESET}
  -h, --help      Show this help and exit

${BOLD}Environment variables${RESET} (all optional unless noted):
  HERMES_VM_NAME            VM name (default: hermes)
  HERMES_VM_RAM             Guest RAM in GiB (default: 4)   — applied at create only
  HERMES_VM_VCPU            vCPU count (default: 2)         — applied at create only
  HERMES_VM_DISK            Disk size in GiB (default: 50)  — applied at create only
  HERMES_VM_IP              Static address of the VM on the libvirt 'default'
                            network (default: address .50 on that network)
  HERMES_COMMIT             hermes-agent commit to install (default:
                            ${HERMES_COMMIT:0:12}…, release v0.21.5 — pinned;
                            override with a full 40-char SHA that is on main)
  HERMES_HOST_DIRECTORY     Host directory shared with the VM (default: /srv/hermes)
                              <dir>/workspace -> /workspace   in the guest
                              <dir>/backups   -> /mnt/backups in the guest
  HERMES_ALLOWED_ENDPOINTS  Space-separated ADDR:PORT[-PORT] list of TCP endpoints
                            on the host or LAN the VM may connect to (default:
                            none). ADDR is an IPv4 address or 'host' (this
                            machine, as seen from the VM). All other private
                            addresses are blocked; the internet is allowed.
                            Example: "host:3000 host:8080 192.168.1.20:8080-8090"
  HERMES_SERVE              Set to "true" to run 'hermes serve' in the VM and
                            forward the port from this host, so Hermes Desktop
                            ("Remote gateway") or a browser on the LAN can
                            connect (default: false)
  HERMES_SERVE_PORT         Port of 'hermes serve' and the host proxy (default: 9119)
  HERMES_SERVE_ALLOW_FROM   Source address/CIDR allowed to reach the port, e.g.
                            192.168.1.0/24 (required when HERMES_SERVE=true)
  HERMES_TRAEFIK            Set to "true" to add a Traefik route with TLS
                            (requires HERMES_SERVE=true; default: false)
  HERMES_DOMAIN             Domain for the Traefik route (required when
                            HERMES_TRAEFIK=true)
  HERMES_LLM_BASE_URL       URL of an OpenAI-compatible endpoint (this repo's
                            llama-swap/vLLM/llama.cpp servers) to connect the
                            Hermes main model to. The guest is configured on
                            every re-run with provider 'openai-api' and that
                            URL + HERMES_LLM_MODEL — switching away from e.g. a
                            Portal setup is therefore deliberate. If the
                            endpoint runs on this host or another IPv4, the
                            endpoint is added to the egress allowlist
                            automatically (so "host:9292" need not be given).
  HERMES_LLM_MODEL          Model id for the endpoint (required when
                            HERMES_LLM_BASE_URL is set)
  HERMES_LLM_API_KEY        API key for the endpoint (optional). Stored only in
                            the guest's ~/.hermes/.env (mode 600) and only if
                            not already present — re-runs never rotate it.
  TRAEFIK_HOME              Traefik config directory (default: /opt/traefik)
  PROXY_NETWORK             Traefik's Docker network (default: proxy)
  WAIT_TIMEOUT              Max seconds for each bounded wait: VM shutdown, SSH,
                            guest services, proxy (default: 180)

${BOLD}Host services and the allowlist:${RESET} 'host:PORT' entries also get a ufw
rule for the VM. The service itself must listen on 0.0.0.0 or the libvirt
bridge — a service bound to 127.0.0.1 stays unreachable from the VM.

${BOLD}First install:${RESET} the gateway service is started right away and idles until
Hermes is configured: virt-runner ssh ${HERMES_VM_NAME}, then 'hermes setup' and
'hermes gateway restart'.

${BOLD}Re-run policy${RESET} (converge by default): an existing VM is never destroyed or
re-created. Re-running re-applies the DHCP reservation, the network filter and
firewall rules, the pinned Hermes commit and the services, then verifies them.
Not converged on an existing VM: RAM/vCPU/disk size and the two host shares
(fixed at create time), ufw rules of endpoints removed from the allowlist (the
network filter already blocks them; delete with 'sudo ufw status numbered' /
'sudo ufw delete <n>'), and a previously enabled HERMES_SERVE (disable
commands are printed).

${BOLD}Migration${RESET} from the former Docker-based setup: see
docs/hermes-docker-to-vm-migration.md (manual, one-off).
EOF
}

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown argument: $arg (see --help)"
      ;;
  esac
done

# =============================================================================
# Input validation
# =============================================================================

IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
ENDPOINT_RE='^(host|([0-9]{1,3}\.){3}[0-9]{1,3}):[0-9]{1,5}(-[0-9]{1,5})?$'
LLM_URL_RE='^https?://[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?(/[A-Za-z0-9._/?&=%+-]*)?$'

[[ "${HERMES_VM_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || error "HERMES_VM_NAME '${HERMES_VM_NAME}' is not a valid VM name"
for _var in HERMES_VM_RAM HERMES_VM_VCPU HERMES_VM_DISK HERMES_SERVE_PORT WAIT_TIMEOUT; do
  [[ "${!_var}" =~ ^[1-9][0-9]*$ ]] || error "${_var} must be a positive integer (got '${!_var}')"
done
[[ -z "${HERMES_VM_IP}" || "${HERMES_VM_IP}" =~ ${IPV4_RE} ]] || error "HERMES_VM_IP '${HERMES_VM_IP}' is not an IPv4 address"
[[ "${HERMES_COMMIT}" =~ ^[0-9a-f]{40}$ ]] \
  || error "HERMES_COMMIT must be a full 40-character commit SHA (got '${HERMES_COMMIT}')"
[[ "${HERMES_HOST_DIRECTORY}" == /* && "${HERMES_HOST_DIRECTORY}" != *,* && "${HERMES_HOST_DIRECTORY}" != *" "* ]] \
  || error "HERMES_HOST_DIRECTORY must be an absolute path without commas or spaces"
for _ep in ${HERMES_ALLOWED_ENDPOINTS}; do
  [[ "${_ep}" =~ ${ENDPOINT_RE} ]] \
    || error "HERMES_ALLOWED_ENDPOINTS: '${_ep}' is not ADDR:PORT[-PORT] (ADDR = IPv4 address or 'host')"
done
if [[ "${HERMES_SERVE}" == "true" ]]; then
  [[ "${HERMES_SERVE_ALLOW_FROM}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
    || error "HERMES_SERVE_ALLOW_FROM must be set to an IPv4 address or CIDR (e.g. 192.168.1.0/24) when HERMES_SERVE=true"
fi
if [[ "${HERMES_TRAEFIK}" == "true" ]]; then
  [[ "${HERMES_SERVE}" == "true" ]] || error "HERMES_TRAEFIK=true requires HERMES_SERVE=true"
  [[ -n "${HERMES_DOMAIN}" ]] || error "HERMES_DOMAIN must be set when HERMES_TRAEFIK=true"
fi
if [[ -n "${HERMES_LLM_BASE_URL}" ]]; then
  [[ "${HERMES_LLM_BASE_URL}" =~ ${LLM_URL_RE} ]] \
    || error "HERMES_LLM_BASE_URL must be http(s)://host[:port][/path] (got '${HERMES_LLM_BASE_URL}')"
  [[ -n "${HERMES_LLM_MODEL}" ]] \
    || error "HERMES_LLM_MODEL must be set when HERMES_LLM_BASE_URL is set"
fi
[[ -z "${HERMES_LLM_MODEL}" || "${HERMES_LLM_MODEL}" =~ ^[A-Za-z0-9][A-Za-z0-9"\ "*:.+/-]*$ ]] \
  || error "HERMES_LLM_MODEL contains unsupported characters"

# =============================================================================
# Helpers
# =============================================================================

SSH_OPTS=(-i "${GUEST_SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# Run a command in the guest (no stdin, no prompts).
vm_ssh() {
  ssh -n "${SSH_OPTS[@]}" "${GUEST_USER}@${HERMES_VM_IP}" "$@"
}

# Copy one file into the guest's provisioning directory under the given name.
vm_copy() {
  scp -q "${SSH_OPTS[@]}" "$1" "${GUEST_USER}@${HERMES_VM_IP}:${GUEST_PROVISION_DIR}/$2"
}

# JSON document of this VM from `virt-runner list` (empty when absent).
vm_json() {
  virt-runner list --json | jq -c --arg n "${HERMES_VM_NAME}" '.vms[] | select(.name == $n)'
}

# vm_has_filter [--inactive] — is the egress filter attached to the VM's NIC?
# (live definition by default, saved definition with --inactive)
vm_has_filter() {
  local xml
  xml="$(virsh dumpxml "$@" "${HERMES_VM_NAME}")" || return 1
  grep -q "<filterref filter='${HERMES_NWFILTER_NAME}'" <<<"${xml}"
}

# Render a template with the non-secret layout values into a temp file.
render_template() {
  local src="${TEMPLATES_DIR}/$1" tmp
  [[ -f "${src}" ]] || error "Template not found: ${src}"
  tmp="$(mktempfile "$1")"
  # shellcheck disable=SC2016  # envsubst expects the literal variable list
  envsubst '${HERMES_VM_IP} ${HERMES_VM_GATEWAY} ${HERMES_SERVE_PORT} ${HERMES_DOMAIN} ${HERMES_NWFILTER_NAME} ${HERMES_NWFILTER_UUID} ${HERMES_EGRESS_RULES}' \
    < "${src}" > "${tmp}"
  echo "${tmp}"
}

# Bounded wait until `virsh domstate` reports the wanted state.
wait_for_domstate() {
  local want="$1" waited=0
  until [[ "$(virsh domstate "${HERMES_VM_NAME}" 2>/dev/null)" == "${want}" ]]; do
    (( waited >= WAIT_TIMEOUT )) && return 1
    sleep 3; waited=$(( waited + 3 ))
  done
}

# Bounded wait until an SSH round-trip to the guest on HERMES_VM_IP succeeds.
wait_for_ssh() {
  local waited=0
  until vm_ssh true 2>/dev/null; do
    (( waited >= WAIT_TIMEOUT )) && return 1
    sleep 3; waited=$(( waited + 3 ))
  done
}

# hermes_ufw_allow <description> <ufw rule args...> — idempotent (ufw skips
# existing rules itself).
hermes_ufw_allow() {
  local description="$1"; shift
  sudo ufw allow "$@" comment "${description}" >/dev/null \
    || error "ufw rule failed: ufw allow $*"
  _ufw_invalidate_status_cache
  info "ufw: allow $*"
}

# =============================================================================
# Main
# =============================================================================

step "Setting up Hermes Agent in VM '${HERMES_VM_NAME}'"

# -----------------------------------------------------------------------------
# 1. Prerequisites
# -----------------------------------------------------------------------------
step "Checking virtualization prerequisites"

_prereqs_installed=false
if ! command -v virsh &>/dev/null; then
  info "libvirt is not installed — running setup-virtualization.sh"
  bash "${SCRIPT_DIR}/setup-virtualization.sh"
  _prereqs_installed=true
fi
if ! command -v virt-runner &>/dev/null; then
  info "virt-runner is not installed — running setup-virt-runner.sh"
  bash "${SCRIPT_DIR}/setup-virt-runner.sh"
  _prereqs_installed=true
fi

# Freshly added group membership (libvirt, kvm) is not active in this shell.
# 'sudo -u' re-initializes the groups, so continue in a re-executed copy once.
if [[ "${_prereqs_installed}" == true && -z "${HERMES_SETUP_REEXEC:-}" ]] && ! virsh list &>/dev/null; then
  info "Re-executing $0 to pick up the new group membership"
  # The configuration is passed explicitly: sudo resets the environment and
  # sudo-rs (Ubuntu 26.04) has no blanket --preserve-env.
  _reexec_env=("PATH=${PATH}" "HERMES_SETUP_REEXEC=1")
  while IFS= read -r _var; do
    _reexec_env+=("${_var}=${!_var}")
  done < <(compgen -e | grep -E '^(HERMES_|VIRT_|WAIT_TIMEOUT$|TRAEFIK_HOME$|PROXY_NETWORK$)' || true)
  exec sudo -u "$(id -un)" env "${_reexec_env[@]}" bash "$0" "$@"
fi

for _cmd in virsh virt-runner virt-xml jq envsubst ssh scp; do
  command -v "${_cmd}" &>/dev/null \
    || error "Required command '${_cmd}' not found (jq: apt install jq; envsubst: apt install gettext-base; virt-xml: apt install virtinst)"
done

if ! _list_out="$(virt-runner list --json 2>&1)" \
  || [[ "$(jq -r '.status' <<<"${_list_out}" 2>/dev/null)" != "success" ]]; then
  echo "${_list_out}" >&2
  error "virt-runner cannot reach libvirt in this shell. If the prerequisites were just installed, group membership (libvirt, kvm) is not active yet: log out and back in, then re-run $0"
fi
virt-runner create --help | grep -q -- '--mount' \
  || error "The installed virt-runner has no 'create --mount' (host directory shares). Update it: VIRT_RUNNER_BRANCH=<branch with --mount> ${SCRIPT_DIR}/setup-virt-runner.sh, then 'uv tool install --force <virt-runner dir>'"
success "libvirt and virt-runner are usable"

_net_xml="$(virsh net-dumpxml "${LIBVIRT_NETWORK}")" \
  || error "libvirt network '${LIBVIRT_NETWORK}' not found — run setup-virt-runner.sh"
HERMES_VM_GATEWAY="$(sed -n "s/.*<ip address='\([0-9.]*\)'.*/\1/p" <<<"${_net_xml}" | head -n1)"
HERMES_VM_BRIDGE="$(sed -n "s/.*<bridge name='\([^']*\)'.*/\1/p" <<<"${_net_xml}" | head -n1)"
[[ -n "${HERMES_VM_GATEWAY}" && -n "${HERMES_VM_BRIDGE}" ]] \
  || error "Could not read gateway address / bridge name of libvirt network '${LIBVIRT_NETWORK}'"
[[ -n "${HERMES_VM_IP}" ]] || HERMES_VM_IP="${HERMES_VM_GATEWAY%.*}.50"
[[ "${HERMES_VM_IP%.*}" == "${HERMES_VM_GATEWAY%.*}" && "${HERMES_VM_IP}" != "${HERMES_VM_GATEWAY}" ]] \
  || error "HERMES_VM_IP ${HERMES_VM_IP} is not a guest address on network '${LIBVIRT_NETWORK}' (gateway ${HERMES_VM_GATEWAY})"

# The former Docker-based gateway must not run next to the VM-based one.
if command -v docker &>/dev/null \
  && grep -qx 'hermes-gateway' <<<"$(docker ps --format '{{.Names}}' 2>/dev/null)"; then
  warn "The Docker container 'hermes-gateway' is still running. Never run two gateways with the same bot tokens — see docs/hermes-docker-to-vm-migration.md"
fi

# -----------------------------------------------------------------------------
# 2. Host directories shared with the VM
# -----------------------------------------------------------------------------
step "Preparing host directories under ${HERMES_HOST_DIRECTORY}"

# virtiofs passes UIDs straight through; the guest user is uid 1000.
if [[ "$(id -u)" != "1000" ]]; then
  warn "You are uid $(id -u), the guest user '${GUEST_USER}' is uid 1000 — files in the shared directories will have mismatching owners"
fi
for _dir in "${HOST_WORKSPACE_DIR}" "${HOST_BACKUP_DIR}"; do
  if [[ ! -d "${_dir}" ]]; then
    sudo mkdir -p "${_dir}"
    sudo chown "$(id -u):$(id -g)" "${_dir}"
    info "Created ${_dir}"
  elif [[ "$(stat -c '%u' "${_dir}")" != "$(id -u)" ]]; then
    warn "${_dir} is owned by uid $(stat -c '%u' "${_dir}"), not by you — the guest may not be able to write to it (see docs/hermes-docker-to-vm-migration.md)"
  fi
done
# Backup archives contain secrets (.env).
if [[ "$(stat -c '%u' "${HOST_BACKUP_DIR}")" == "$(id -u)" ]]; then
  chmod 700 "${HOST_BACKUP_DIR}"
fi

# -----------------------------------------------------------------------------
# 3. Converge the VM (create if absent, never destroy)
# -----------------------------------------------------------------------------
step "Converging VM '${HERMES_VM_NAME}'"

VM_NEEDS_RESTART=false
if [[ -z "$(vm_json)" ]]; then
  info "Creating VM (${HERMES_VM_RAM} GiB RAM, ${HERMES_VM_VCPU} vCPU, ${HERMES_VM_DISK} GiB disk) — this takes a few minutes"
  virt-runner create "${HERMES_VM_NAME}" \
    --ram "${HERMES_VM_RAM}" --vcpu "${HERMES_VM_VCPU}" --disk "${HERMES_VM_DISK}" \
    --user "${GUEST_USER}" \
    --mount "${HOST_WORKSPACE_DIR}:/workspace" \
    --mount "${HOST_BACKUP_DIR}:/mnt/backups" \
    || error "virt-runner could not create VM '${HERMES_VM_NAME}' — see the output above"
  success "VM created"
else
  info "VM already exists — keeping it (RAM/vCPU/disk and host shares are not changed)"
fi

HERMES_VM_MAC="$(vm_json | jq -r '.mac // empty')"
[[ -n "${HERMES_VM_MAC}" ]] || error "Could not determine the MAC address of VM '${HERMES_VM_NAME}'"

# Static address: DHCP reservation on the libvirt network.
_dhcp_host="<host mac='${HERMES_VM_MAC}' name='${HERMES_VM_NAME}' ip='${HERMES_VM_IP}'/>"
if grep -q "mac='${HERMES_VM_MAC}'.*ip='${HERMES_VM_IP}'" <<<"${_net_xml}"; then
  info "DHCP reservation ${HERMES_VM_MAC} -> ${HERMES_VM_IP} already present"
else
  _dhcp_action="add-last"
  grep -q "mac='${HERMES_VM_MAC}'" <<<"${_net_xml}" && _dhcp_action="modify"
  virsh net-update "${LIBVIRT_NETWORK}" "${_dhcp_action}" ip-dhcp-host "${_dhcp_host}" --live --config >/dev/null \
    || error "Could not reserve ${HERMES_VM_IP} for the VM on network '${LIBVIRT_NETWORK}' (address already reserved for another VM? choose another HERMES_VM_IP)"
  success "DHCP reservation ${HERMES_VM_MAC} -> ${HERMES_VM_IP} set"
  VM_NEEDS_RESTART=true
fi

# -----------------------------------------------------------------------------
# 4. Network policy (egress allowlist)
# -----------------------------------------------------------------------------
step "Applying network policy"

# The guest must always be able to reach its own LLM endpoint: derive the
# endpoint from HERMES_LLM_BASE_URL and add it to the allowlist (deduplicated)
# unless the user already listed it. Hostnames are not resolvable here — the
# script warns and leaves it to HERMES_ALLOWED_ENDPOINTS.
if [[ -n "${HERMES_LLM_BASE_URL}" ]]; then
  _llm_scheme="${HERMES_LLM_BASE_URL%%://*}"
  _llm_hostport="${HERMES_LLM_BASE_URL#*://}"; _llm_hostport="${_llm_hostport%%/*}"
  if [[ "${_llm_hostport}" == *:* ]]; then
    _llm_host="${_llm_hostport%:*}"; _llm_port="${_llm_hostport##*:}"
  else
    _llm_host="${_llm_hostport}"; _llm_port=80
    [[ "${_llm_scheme}" == "https" ]] && _llm_port=443
  fi
  _llm_ep=""
  if [[ "${_llm_host}" == "${HERMES_VM_GATEWAY}" ]]; then
    _llm_ep="host:${_llm_port}"
  elif [[ "${_llm_host}" =~ ${IPV4_RE} ]]; then
    _llm_ep="${_llm_host}:${_llm_port}"
  fi
  if [[ -n "${_llm_ep}" ]]; then
    [[ " ${HERMES_ALLOWED_ENDPOINTS} " == *" ${_llm_ep} "* ]] \
      || { HERMES_ALLOWED_ENDPOINTS+=" ${_llm_ep}"; info "Allowlisted the LLM endpoint ${_llm_ep} automatically"; }
  else
    warn "HERMES_LLM_BASE_URL host '${_llm_host}' is neither the hypervisor (${HERMES_VM_GATEWAY}) nor an IPv4 — not allowlisted. Add '${_llm_host}:<port>' to HERMES_ALLOWED_ENDPOINTS yourself."
  fi
fi

HERMES_EGRESS_RULES=""
_host_ports=()
for _ep in ${HERMES_ALLOWED_ENDPOINTS}; do
  _addr="${_ep%%:*}"
  _ports="${_ep##*:}"
  _port_start="${_ports%%-*}"
  _port_end="${_ports##*-}"
  if [[ "${_addr}" == "host" ]]; then
    _addr="${HERMES_VM_GATEWAY}"
    _host_ports+=("${_ports/-/:}")
  fi
  HERMES_EGRESS_RULES+="  <rule action='accept' direction='out' priority='200'>"$'\n'
  HERMES_EGRESS_RULES+="    <tcp dstipaddr='${_addr}' dstportstart='${_port_start}' dstportend='${_port_end}'/>"$'\n'
  HERMES_EGRESS_RULES+="  </rule>"$'\n'
done
HERMES_EGRESS_RULES="${HERMES_EGRESS_RULES%$'\n'}"

# Redefining an existing filter requires its UUID; a redefine updates the
# rules of the running VM in place.
HERMES_NWFILTER_UUID="$(virsh nwfilter-dumpxml "${HERMES_NWFILTER_NAME}" 2>/dev/null \
  | sed -n 's/.*<uuid>\(.*\)<\/uuid>.*/\1/p' | head -n1 || true)"
[[ -n "${HERMES_NWFILTER_UUID}" ]] || HERMES_NWFILTER_UUID="$(cat /proc/sys/kernel/random/uuid)"

export HERMES_VM_IP HERMES_VM_GATEWAY HERMES_SERVE_PORT HERMES_DOMAIN \
  HERMES_NWFILTER_NAME HERMES_NWFILTER_UUID HERMES_EGRESS_RULES

_filter_file="$(render_template hermes-egress.nwfilter.xml)"
virsh nwfilter-define "${_filter_file}" >/dev/null \
  || error "Could not define network filter '${HERMES_NWFILTER_NAME}'"
success "Network filter '${HERMES_NWFILTER_NAME}' defined (allowlist: ${HERMES_ALLOWED_ENDPOINTS:-none})"

if vm_has_filter --inactive; then
  info "Network filter already attached to the VM"
else
  virt-xml --connect "${LIBVIRT_DEFAULT_URI}" "${HERMES_VM_NAME}" --edit \
    --network "filterref.filter=${HERMES_NWFILTER_NAME}" >/dev/null \
    || error "Could not attach network filter '${HERMES_NWFILTER_NAME}' to the VM"
  success "Network filter attached to the VM"
  VM_NEEDS_RESTART=true
fi
# The filter must be active on the running VM, not only in its saved config.
if [[ "$(virsh domstate "${HERMES_VM_NAME}")" == "running" ]] && ! vm_has_filter; then
  VM_NEEDS_RESTART=true
fi

# Guest -> host traffic passes the host firewall: open the allowlisted host ports.
if (( ${#_host_ports[@]} > 0 )); then
  if ! ufw_available; then
    warn "ufw not installed — no host firewall rules added for 'host:' endpoints"
  else
    _ufw_state=0
    ufw_active || _ufw_state=$?
    (( _ufw_state == 2 )) && error "ufw is installed but its status could not be read — fix sudo access to ufw and re-run"
    (( _ufw_state == 1 )) && warn "ufw is inactive — the rules below take effect once the firewall is enabled"
    for _p in "${_host_ports[@]}"; do
      hermes_ufw_allow "hermes-vm egress" in on "${HERMES_VM_BRIDGE}" from "${HERMES_VM_IP}" to any port "${_p}" proto tcp
    done
  fi
fi

# -----------------------------------------------------------------------------
# 5. Start / restart the VM and wait for SSH on the reserved address
# -----------------------------------------------------------------------------
step "Starting VM and waiting for SSH"

_state="$(virsh domstate "${HERMES_VM_NAME}")"
case "${_state}" in
  running)
    if [[ "${VM_NEEDS_RESTART}" == true ]]; then
      info "Restarting the VM once to apply the address reservation / network filter"
      virsh shutdown "${HERMES_VM_NAME}" >/dev/null
      wait_for_domstate "shut off" \
        || error "VM did not shut down within ${WAIT_TIMEOUT}s — check 'virsh list --all' and re-run"
      virsh start "${HERMES_VM_NAME}" >/dev/null
    fi
    ;;
  "shut off")
    info "VM is shut off — starting it"
    virsh start "${HERMES_VM_NAME}" >/dev/null
    ;;
  *)
    error "VM is in state '${_state}' — bring it to 'running' or 'shut off' (virsh) and re-run"
    ;;
esac

wait_for_ssh \
  || error "No SSH on ${GUEST_USER}@${HERMES_VM_IP} after ${WAIT_TIMEOUT}s — check 'virsh net-dhcp-leases ${LIBVIRT_NETWORK}' and 'virsh console ${HERMES_VM_NAME}'"
vm_has_filter \
  || error "Network filter '${HERMES_NWFILTER_NAME}' is not active on the running VM"
success "VM is running at ${HERMES_VM_IP} with network filter '${HERMES_NWFILTER_NAME}'"

# -----------------------------------------------------------------------------
# 6. Provision the guest
# -----------------------------------------------------------------------------
step "Installing Hermes Agent in the guest (commit ${HERMES_COMMIT:0:12})"

vm_ssh "mkdir -p ${GUEST_PROVISION_DIR}"
vm_copy "${TEMPLATES_DIR}/provision-guest.sh" provision-guest.sh
vm_copy "${TEMPLATES_DIR}/hermes-backup.service" hermes-backup.service
vm_copy "${TEMPLATES_DIR}/hermes-backup.timer" hermes-backup.timer
vm_copy "$(render_template hermes-serve.service)" hermes-serve.service

# All values below are validated above (hex SHA, integers, true/false).
# The API key travels as an environment assignment only: provision-guest.sh
# writes it into the guest's ~/.hermes/.env (mode 600), never into a template,
# and prints nothing. It is briefly visible in the guest's 'ps' during the run.
_llm_env=""
if [[ -n "${HERMES_LLM_BASE_URL}" ]]; then
  _llm_env="HERMES_LLM_BASE_URL=$(printf '%q' "${HERMES_LLM_BASE_URL}") HERMES_LLM_MODEL=$(printf '%q' "${HERMES_LLM_MODEL}") HERMES_LLM_API_KEY=$(printf '%q' "${HERMES_LLM_API_KEY}") "
fi
vm_ssh "HERMES_COMMIT='${HERMES_COMMIT}' HERMES_SERVE='${HERMES_SERVE}' HERMES_SERVE_PORT='${HERMES_SERVE_PORT}' WAIT_TIMEOUT='${WAIT_TIMEOUT}' ${_llm_env}bash ${GUEST_PROVISION_DIR}/provision-guest.sh" 2>&1 \
  || error "Guest provisioning failed — see the output above"
success "Hermes Agent installed in the guest"

# -----------------------------------------------------------------------------
# 7. Inbound access for Hermes Desktop / dashboard (opt-in)
# -----------------------------------------------------------------------------
if [[ "${HERMES_SERVE}" == "true" ]]; then
  step "Exposing 'hermes serve' on port ${HERMES_SERVE_PORT}"

  _proxy_changed=false
  for _unit in hermes-vm-proxy.socket hermes-vm-proxy.service; do
    _rendered="$(render_template "${_unit}")"
    if ! cmp -s "${_rendered}" "/etc/systemd/system/${_unit}"; then
      sudo install -m 0644 "${_rendered}" "/etc/systemd/system/${_unit}"
      _proxy_changed=true
    fi
  done
  if [[ "${_proxy_changed}" == true ]]; then
    sudo systemctl daemon-reload
    sudo systemctl stop hermes-vm-proxy.service hermes-vm-proxy.socket 2>/dev/null || true
  fi
  sudo systemctl enable --now hermes-vm-proxy.socket \
    || error "Could not start hermes-vm-proxy.socket (is port ${HERMES_SERVE_PORT} already in use on this host?)"

  if ufw_available; then
    hermes_ufw_allow "hermes-vm serve" from "${HERMES_SERVE_ALLOW_FROM}" to any port "${HERMES_SERVE_PORT}" proto tcp
  else
    warn "ufw not installed — port ${HERMES_SERVE_PORT} is not restricted to ${HERMES_SERVE_ALLOW_FROM}"
  fi

  if [[ "${HERMES_TRAEFIK}" == "true" ]]; then
    [[ -d "${TRAEFIK_HOME}/dynamic" ]] \
      || error "Traefik dynamic config directory ${TRAEFIK_HOME}/dynamic not found — run setup-traefik.sh first"
    sudo install -m 0644 "$(render_template traefik-hermes.yml)" "${TRAEFIK_HOME}/dynamic/hermes.yml"
    success "Traefik route written: ${TRAEFIK_HOME}/dynamic/hermes.yml"
    # Traefik reaches the host proxy from its Docker network.
    if ufw_available; then
      _proxy_subnets="$(docker network inspect "${PROXY_NETWORK}" \
        --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)" \
        || error "Docker network '${PROXY_NETWORK}' not found — run setup-traefik.sh first"
      for _subnet in ${_proxy_subnets}; do
        hermes_ufw_allow "hermes-vm serve (traefik)" from "${_subnet}" to any port "${HERMES_SERVE_PORT}" proto tcp
      done
    fi
  fi

  # Health gate: the dashboard must answer through the host proxy.
  _waited=0
  until curl -s -o /dev/null --max-time 5 "http://127.0.0.1:${HERMES_SERVE_PORT}/"; do
    (( _waited >= WAIT_TIMEOUT )) \
      && error "hermes serve does not answer through the host proxy on port ${HERMES_SERVE_PORT} after ${WAIT_TIMEOUT}s — check 'systemctl status hermes-vm-proxy.socket'"
    sleep 3; _waited=$(( _waited + 3 ))
  done
  success "hermes serve is reachable on this host, port ${HERMES_SERVE_PORT}"
elif systemctl is-enabled --quiet hermes-vm-proxy.socket 2>/dev/null; then
  warn "HERMES_SERVE is not true, but the host proxy is still enabled — left untouched."
  info "Disable it with: sudo systemctl disable --now hermes-vm-proxy.socket hermes-vm-proxy.service"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
success "Hermes Agent VM is ready"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}VM${RESET}                 ${HERMES_VM_NAME} (${HERMES_VM_IP})"
echo -e "  ${BOLD}Shell${RESET}              virt-runner ssh ${HERMES_VM_NAME}"
echo -e "  ${BOLD}Hermes commit${RESET}      ${HERMES_COMMIT}"
echo -e "  ${BOLD}Workspace${RESET}          ${HOST_WORKSPACE_DIR}  (guest: /workspace)"
echo -e "  ${BOLD}Backups${RESET}            ${HOST_BACKUP_DIR}  (guest: /mnt/backups, daily)"
echo -e "  ${BOLD}Allowed endpoints${RESET}  ${HERMES_ALLOWED_ENDPOINTS:-none (internet only)}"
if [[ -n "${HERMES_LLM_BASE_URL}" ]]; then
  echo -e "  ${BOLD}Local LLM${RESET}           ${HERMES_LLM_BASE_URL}  (model: ${HERMES_LLM_MODEL})"
fi
if [[ "${HERMES_SERVE}" == "true" ]]; then
  echo -e "  ${BOLD}Remote gateway${RESET}     http://<this-host>:${HERMES_SERVE_PORT}  (from ${HERMES_SERVE_ALLOW_FROM})"
  if [[ "${HERMES_TRAEFIK}" == "true" ]]; then
    echo -e "  ${BOLD}Remote gateway${RESET}     https://${HERMES_DOMAIN}  (Traefik)"
  fi
  echo -e "  ${BOLD}Credentials${RESET}        virt-runner ssh ${HERMES_VM_NAME}, then:"
  echo "                     grep HERMES_DASHBOARD_BASIC_AUTH ~/.hermes/.env"
fi
echo ""
echo -e "  ${BOLD}Gateway${RESET}            running (systemd user service in the guest)"
echo "    Logs:     virt-runner ssh ${HERMES_VM_NAME}, then: journalctl --user -u hermes-gateway -f"
echo ""
echo -e "${YELLOW}Configure Hermes${RESET} (first install, or to change providers / platforms):"
echo "  1. virt-runner ssh ${HERMES_VM_NAME}"
echo "  2. hermes setup            (provider keys, model, messaging platforms)"
echo "  3. hermes gateway restart"
echo "  Example config: ${TEMPLATES_DIR}/config.yaml.example"
echo "  Migrating from the Docker setup: docs/hermes-docker-to-vm-migration.md"
echo ""
