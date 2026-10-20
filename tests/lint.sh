#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tests/lint.sh — repo lint guards
# =============================================================================
#
# Guards 1-3 are template hardening, established by
# .tickets/improvements-2/07-socket-proxy-drop-privileged.md:
#
#   1. No `privileged:` container in templates/ — the Docker socket proxy in
#      the traefik templates must stay unprivileged. The only allowlisted
#      exception is the concourse worker: it runs a containerd runtime
#      *inside* the container, which requires privileged mode (a functional
#      requirement, not an escape surface).
#   2. No floating/untagged image reference in templates/. Every `image:` line
#      is a `${...}` placeholder that the task script substitutes from a pinned
#      default (ticket 07 for SOCKET_PROXY_IMAGE, ticket 17 for the rest), so a
#      literal `:latest`/`:main` or an untagged `image: foo` in a template means
#      the pinning regressed.
#   3. No untagged image pulls. An `image:` value without `${`, a `:` tag or a `@digest`
#      resolves to `:latest`; locally BUILT images (nanobot) are not pulls and are
#      allowlisted.
#
# ...plus guards 4-5 for the orchestrator's own contract, because the VM suite cannot see
# either class of breakage: it feeds its own test config to the precheck, and the remote
# runner reads configs with jq's null-tolerant `// []`/`// {}`.
#
#   4. Both shipped example configs must parse with deploy.py — `status` is the
#      first command a new user runs, so an unparsable example is a broken quick
#      start. Needs `uv` (the orchestrator's own prerequisite).
#   5. Every config key in the examples must name an existing
#      `tasks/<name>.sh` or `tasks/<name>.py`, so a disabled-but-stale key (the
#      `sync-models` case) cannot hide in a shipped example.
#
# The full lint gate (shellcheck / yamllint / config-sync / CI) is planned in
# ticket 20 (lint-gate-and-ci) and will extend this script in place.
# =============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

# ── Guard 1: no privileged containers (except the documented concourse worker)
privileged_hits="$(grep -rn "privileged:" templates/ || true)"
if [[ -n "${privileged_hits}" ]]; then
  unallowed="$(echo "${privileged_hits}" | grep -v '^templates/concourse/' || true)"
  if [[ -n "${unallowed}" ]]; then
    echo "FAIL: privileged container in templates/ (outside the concourse allowlist):"
    echo "${unallowed}"
    fail=1
  else
    echo "ok: privileged: only in the concourse worker (containerd runtime requires it)"
  fi
else
  echo "ok: no privileged containers in templates/"
fi

# ── Guard 2: no floating :latest/:main images anywhere in templates/
latest_hits="$(grep -rnE "image: [^$]\S*:(latest|main)[[:space:]]*$" templates/ || true)"
if [[ -n "${latest_hits}" ]]; then
  echo "FAIL: floating :latest/:main image in templates/ (render the image from a"
  echo "      script-level *_IMAGE default instead — see ticket improvements-2/17):"
  echo "${latest_hits}"
  fail=1
else
  echo "ok: no floating :latest/:main images in templates/"
fi

# ── Guard 3: no untagged image pulls. An `image:` value without `${`, a `:` tag
# or a `@digest` resolves to `:latest`. Locally BUILT images are not pulls, so
# the nanobot stack (image + build: in the same service) is allowlisted.
untagged_hits="$(grep -rnE '^[[:space:]]*image:[[:space:]]+"?[A-Za-z0-9][A-Za-z0-9._/-]*"?[[:space:]]*$' templates/ \
  | grep -v '^templates/nanobot/' || true)"
if [[ -n "${untagged_hits}" ]]; then
  echo "FAIL: untagged image pull in templates/ (implicitly :latest):"
  echo "${untagged_hits}"
  fail=1
else
  echo "ok: no untagged image pulls in templates/ (nanobot builds locally)"
fi

# ── Guard 4: every shipped example config must parse with the orchestrator.
# `run-setup.sh status` is the first command a new user runs, and both example configs
# are the documented starting point — so an example that the orchestrator refuses to read
# is a broken quick start, not a config bug. The VM suite cannot catch this: it feeds the
# harness config (tests/machine-config.test.yml) to the precheck, and the harness itself
# reads configs with jq's `// []`/`// {}`, i.e. it is null-tolerant where deploy.py is not.
for cfg in machine-config.yml.example machine-config-inference.yml.example; do
  if [[ ! -f "${cfg}" ]]; then
    echo "FAIL: ${cfg} missing — the shipped examples are the quick start"
    fail=1
    continue
  fi
  if ! command -v uv &>/dev/null; then
    echo "FAIL: uv not found — guard 4 cannot check that ${cfg} parses"
    echo "      (uv is the orchestrator's only prerequisite: curl -LsSf https://astral.sh/uv/install.sh | sh)"
    fail=1
    continue
  fi
  if out="$(uv run --project . pyinfra @local deploy.py --dry --data config="${PWD}/${cfg}" 2>&1)"; then
    echo "ok: ${cfg} parses (deploy.py --dry)"
  else
    echo "FAIL: ${cfg} does not parse with deploy.py — every apply/status on it aborts:"
    echo "${out}" | grep -E 'pyinfra error|WARNING' | sed 's/^/      /'
    echo "      reproduce: ./run-setup.sh status --data config=${cfg}"
    fail=1
  fi
done

# ── Guard 5: every config key must name a task that exists. deploy.py fails on such a
# key, but only when it is enabled — a key that is *disabled* and points nowhere is a
# silently stale example (the `sync-models` case: the key existed while only
# tasks/sync-models.py did). Both example configs are what users copy, so keep them true.
missing=0
for cfg in machine-config.yml.example machine-config-inference.yml.example; do
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    if [[ ! -f "tasks/${key}.sh" && ! -f "tasks/${key}.py" ]]; then
      echo "      - ${cfg}: ${key}"
      missing=1
    fi
  done < <(yq -r '.scripts | keys[]' "${cfg}" 2>/dev/null || true)
done
if [[ "${missing}" -ne 0 ]]; then
  echo "FAIL: example config keys with no tasks/<name>.sh or tasks/<name>.py (fix the key,"
  echo "      or add the entrypoint — deploy.py will refuse to run them when enabled)"
  fail=1
else
  echo "ok: every example-config key names an existing task entrypoint"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "lint guards: FAIL"
  exit 1
fi
echo "lint guards: PASS"
