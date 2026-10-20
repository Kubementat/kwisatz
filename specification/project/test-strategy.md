# Test Strategy

## Test Types

### Currently Implemented
- **Static analysis (ShellCheck)** — All scripts must pass `shellcheck` with no errors or warnings. This is the primary quality gate for now.
- **Repo guards (`tests/lint.sh`)** — Template hardening (no privileged containers, no
  floating/untagged image refs) plus the orchestrator contract: both shipped example
  configs must parse with `deploy.py`, and every example config key must name an existing
  `tasks/<name>.sh` or `tasks/<name>.py`. Run it with `tests/lint.sh`.
- **Integration tests (VM-based)** — A fresh Ubuntu VM is created with virt-runner, the
  repo copied to it, and every enabled script of `tests/machine-config.test.yml` run once
  (`integration`) in config order; see `tests/README.md` for the suite and `run-vm-tests.sh`.
- **Idempotency tests** — The same VM run executes every enabled script a second time
  (`idempotency`), which is the re-run policy check in `conventions.md`: converge, reuse
  secrets, never tear down silently.

### Planned (Future)
- **Unit tests** for the Python entrypoint (`tasks/sync-models.py` / `sync_models/`) — currently covered only by the spec's own acceptance table.

## What Gets Tested

- **Every script** must pass ShellCheck before being committed.
- Integration and idempotency tests will initially focus on the core provisioning flow (entrypoints and their sourced task scripts).
- Pragmatic coverage — not every edge case needs a test, but the main happy path for each entrypoint must be verified.

## Coverage Expectations

- Pragmatic, not exhaustive. The goal is confidence that provisioning works correctly on a clean Ubuntu machine and that re-running scripts is safe.
- No numeric coverage target.

## Frameworks and Tools

| Tool | Purpose | Status |
|------|---------|--------|
| **ShellCheck** | Static analysis / linting for Bash | Active |
| **`tests/lint.sh`** | Template + orchestrator-contract guards | Active |
| **virt-runner** | Fresh-VM harness for the integration/idempotency suite | Active |
| **ruff** | Static analysis / linting for python | Planned |

## Quality Check Definition

A change is considered ready to merge when:
1. All scripts pass `shellcheck` (for shell scripts) or `ruff` (for python) with no errors or warnings.
2. `tests/lint.sh` passes.
3. The VM integration suite passes: `tests/run-vm-tests.sh` → `SUITE: PASS`, for the scripts the change touches (or the default set, if the change is in the orchestrator or a shared `lib/`).
4. Idempotency holds — the suite's second phase must pass, i.e. the second run converges rather than errors or tears anything down.
