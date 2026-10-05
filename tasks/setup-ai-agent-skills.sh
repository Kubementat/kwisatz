#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# setup-ai-agent-skills.sh — Install AI agent skills stack
# =============================================================================
#
# Description:
#   Installs the AI agent skills stack for a target user from the
#   ai_agent_skills repository:
#
#     1. ensures a local clone of the repo (clones if missing, fast-forward
#        pull if present; falls back to a plain fetch when local changes
#        block the fast-forward)
#     2. installs the selected skills into the target user's
#        ~/.pi/agent/skills/ via <repo>/install-skill.sh
#     3. installs agent profiles into ~/.pi/agent/agents/ via
#        <repo>/install-agent.sh (all agents or named ones; note the repo's
#        install-agent.sh skips *.chain.md files)
#     4. installs the herdr-cli helper scripts (runagent, agent_profile.py,
#        run-*-herdr.sh, pipeline-herdr.sh, herdr-common.sh) into the target
#        user's ~/.local/bin — overwritten only when content changed
#     5. verifies with `runagent --list` (run as the target user)
#
#   Re-runs are idempotent: the clone is updated in place, skill/agent
#   installs are symlink-based and converge, and helper scripts are only
#   rewritten when their content changed.
#
# Prerequisites (documented, not checked):
#   - setup-basics.sh        (herdr)
#   - setup-pi.sh            (pi)
#   - setup-agent-sandbox.sh (asb)
#
#   When installing for a user different from the invoking user, run as root
#   (the script uses `sudo -u <user>` then).
#
# Environment Variables (optional):
#   AI_SKILLS_REPO_URL     git remote of the ai_agent_skills repo
#                          (default: ssh://git@192.168.178.57:2223/denkfabrik/ai_agent_skills)
#   AI_SKILLS_USER         target user whose home the stack is installed for
#                          (default: current user)
#   AI_SKILLS_DIR          clone location
#                          (default: /home/<AI_SKILLS_USER>/skills/ai_agent_skills,
#                          /root/skills/ai_agent_skills for root)
#   AI_SKILLS_TO_INSTALL   space- and/or comma-separated skill names
#                          (default: "herdr-cli pi-cli ponytail karpathy-guidelines")
#   AI_AGENTS_TO_INSTALL   space-separated agent names or "all" (default: all)
#
# Usage:
#   ./setup-ai-agent-skills.sh
#   ./setup-ai-agent-skills.sh --help
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
# USAGE / HELP
# =============================================================================

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Installs the AI agent skills stack for a target user from the ai_agent_skills
repository: the repo clone, selected pi skills (~/.pi/agent/skills/), agent
profiles (~/.pi/agent/agents/) and the herdr-cli helper scripts
(~/.local/bin). Verified with \`runagent --list\`. Idempotent — re-runs
update the clone and only touch files that changed.

${BOLD}Options:${RESET}
  -h, --help    Show this help and exit

${BOLD}Environment variables${RESET} (all optional):
  AI_SKILLS_REPO_URL     git remote (default: ssh://git@192.168.178.57:2223/denkfabrik/ai_agent_skills)
  AI_SKILLS_USER         target user (default: current user)
  AI_SKILLS_DIR          clone location (default: /home/<user>/skills/ai_agent_skills,
                         /root/skills/ai_agent_skills for root)
  AI_SKILLS_TO_INSTALL   space- and/or comma-separated skill names
                         (default: "herdr-cli pi-cli ponytail karpathy-guidelines")
  AI_AGENTS_TO_INSTALL   space-separated agent names or "all" (default: all)

${BOLD}Prerequisites${RESET} (not checked): setup-basics (herdr), setup-pi (pi),
setup-agent-sandbox (asb). To install for another user, run as root.
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1 (see --help)"
      ;;
  esac
done

# Configuration
AI_SKILLS_REPO_URL="${AI_SKILLS_REPO_URL:-ssh://git@192.168.178.57:2223/denkfabrik/ai_agent_skills}"
AI_SKILLS_USER="${AI_SKILLS_USER:-$(id -un)}"
AI_SKILLS_TO_INSTALL="${AI_SKILLS_TO_INSTALL:-herdr-cli pi-cli ponytail karpathy-guidelines}"
AI_AGENTS_TO_INSTALL="${AI_AGENTS_TO_INSTALL:-all}"

# Run a command as the target user (identity: same user; via sudo when root)
run_as_user() {
  if [[ "$(id -u)" -eq 0 && "${AI_SKILLS_USER}" != "root" ]]; then
    sudo -u "${AI_SKILLS_USER}" -H "$@"
  else
    "$@"
  fi
}

# Validate target user and resolve its home directory
if ! id "${AI_SKILLS_USER}" &>/dev/null; then
  error "Target user '${AI_SKILLS_USER}' does not exist"
fi
if [[ "$(id -u)" -ne 0 && "${AI_SKILLS_USER}" != "$(id -un)" ]]; then
  error "Installing for user '${AI_SKILLS_USER}' while running as '$(id -un)' requires root"
fi
USER_HOME="$(getent passwd "${AI_SKILLS_USER}" | cut -d: -f6)"

# Clone location (default per target user)
if [[ -z "${AI_SKILLS_DIR:-}" ]]; then
  if [[ "${AI_SKILLS_USER}" == "root" ]]; then
    AI_SKILLS_DIR="/root/skills/ai_agent_skills"
  else
    AI_SKILLS_DIR="${USER_HOME}/skills/ai_agent_skills"
  fi
fi

# Parse skill list (space- and/or comma-separated)
SKILLS_TO_INSTALL=()
read -ra SKILLS_TO_INSTALL < <(tr ',' ' ' <<< "${AI_SKILLS_TO_INSTALL}") || true
# Parse agent list ("all" or space-separated names)
AGENTS_TO_INSTALL=()
read -ra AGENTS_TO_INSTALL < <(tr ',' ' ' <<< "${AI_AGENTS_TO_INSTALL}") || true
[[ "${#SKILLS_TO_INSTALL[@]}" -gt 0 ]] || error "AI_SKILLS_TO_INSTALL resolved to an empty skill list"

# herdr-cli helper scripts to install into ~/.local/bin
HERDR_CLI_SCRIPTS_DIR="skills/herdr-cli/scripts"
declare -a HELPER_SCRIPTS=(
  "runagent"
  "agent_profile.py"
  "run-pi-herdr.sh"
  "run-claude-herdr.sh"
  "run-opencode-herdr.sh"
  "pipeline-herdr.sh"
  "herdr-common.sh"
)

# =============================================================================
# Main
# =============================================================================

step "Setting up AI agent skills stack for user '${AI_SKILLS_USER}'"

# 1. Ensure the repo clone (clone / fast-forward pull, fetch fallback)
step "Ensuring ai_agent_skills repo at ${AI_SKILLS_DIR}"
if [[ -d "${AI_SKILLS_DIR}/.git" ]]; then
  info "Existing git repository found, pulling (fast-forward)..."
  if ! run_as_user git -C "${AI_SKILLS_DIR}" pull --ff-only; then
    warn "Fast-forward pull failed (local changes?); falling back to 'git fetch'"
    run_as_user git -C "${AI_SKILLS_DIR}" fetch
  fi
elif [[ -e "${AI_SKILLS_DIR}" ]]; then
  error "${AI_SKILLS_DIR} exists but is not a git repository. Remove it or set AI_SKILLS_DIR to a different location."
else
  run_as_user mkdir -p "$(dirname "${AI_SKILLS_DIR}")"
  info "Cloning ${AI_SKILLS_REPO_URL} ..."
  run_as_user git clone "${AI_SKILLS_REPO_URL}" "${AI_SKILLS_DIR}"
fi

# 2. Install selected skills into the target user's ~/.pi/agent/skills/
step "Installing pi skills: ${SKILLS_TO_INSTALL[*]}"
for skill in "${SKILLS_TO_INSTALL[@]}"; do
  info "Installing skill: ${skill}"
  run_as_user bash "${AI_SKILLS_DIR}/install-skill.sh" --agent pi --global --skill "${skill}" --force
done

# 3. Install agent profiles (all or named) into ~/.pi/agent/agents/
step "Installing agent profiles"
if [[ "${AGENTS_TO_INSTALL[*]}" == "all" ]]; then
  info "Installing all agent profiles (install-agent.sh skips *.chain.md files)"
  run_as_user bash "${AI_SKILLS_DIR}/install-agent.sh" --all --force
else
  info "Installing agent profiles: ${AGENTS_TO_INSTALL[*]}"
  run_as_user bash "${AI_SKILLS_DIR}/install-agent.sh" --force "${AGENTS_TO_INSTALL[@]}"
fi

# 4. Install herdr-cli helper scripts into the target user's ~/.local/bin
step "Installing herdr-cli helper scripts into ${USER_HOME}/.local/bin"
USER_LOCAL_BIN="${USER_HOME}/.local/bin"
run_as_user mkdir -p "${USER_LOCAL_BIN}"
for name in "${HELPER_SCRIPTS[@]}"; do
  src="${AI_SKILLS_DIR}/${HERDR_CLI_SCRIPTS_DIR}/${name}"
  if [[ ! -f "${src}" ]]; then
    error "Helper script not found in repo: ${src}"
  fi
  dest="${USER_LOCAL_BIN}/${name}"
  if [[ -f "${dest}" ]] && cmp -s "${src}" "${dest}"; then
    info "Unchanged: ${name}"
    continue
  fi
  # herdr-common.sh is sourced, not executed; everything else is executable
  if [[ "${name}" == "herdr-common.sh" ]]; then
    mode=644
  else
    mode=755
  fi
  cp "${src}" "${dest}.tmp"
  mv "${dest}.tmp" "${dest}"
  chmod "${mode}" "${dest}"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "${AI_SKILLS_USER}:${AI_SKILLS_USER}" "${dest}"
  fi
  info "Updated: ${name}"
done

# 5. Verify: runagent --list must succeed (as the target user)
step "Verifying with 'runagent --list'"
run_as_user "${USER_LOCAL_BIN}/runagent" --list

success "AI agent skills stack installed for user '${AI_SKILLS_USER}'"
info "Skills: ${SKILLS_TO_INSTALL[*]}"
info "Agents: ${AGENTS_TO_INSTALL[*]}"
info "Helpers: ${USER_LOCAL_BIN} (runagent, agent_profile.py, run-*-herdr.sh, pipeline-herdr.sh, herdr-common.sh)"
