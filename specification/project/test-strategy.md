# Test Strategy

## Test Types

### Currently Implemented
- **Static analysis (ShellCheck)** — All scripts must pass `shellcheck` with no errors or warnings. This is the primary quality gate for now.
- **Repo guards (`tests/lint.sh`)** — Template hardening (no privileged containers, no
  floating/untagged image refs) plus the orchestrator contract: both shipped example configs
  must parse through the CLI (`./kwisatz apply --dry-run --config …`), and every example config
  key must name an existing `tasks/<name>.sh` or `tasks/<name>.py`. Run it with `tests/lint.sh`.
- **Unit + CLI tests (`tests/unit`, pytest)** — `uv run pytest`: target resolution, the
  `enabled:` spellings, plan ordering, masking, the `--json` envelope, exit codes, the lock,
  comment-preserving config edits, and the command surface run as real subprocesses against a
  throwaway checkout whose scripts *record* the argv/env/stdin they were given.
- **Conformance (`tests/unit/test_conformance.py`, `test_deploy_engine.py`)** — the release
  gate for the single execution engine: `kwisatz apply` and `deploy.py` must agree on the
  `(command, env, stdin)` triple, and the task script's own ancestor chain has to prove that a
  deploy ran it.
- **Integration tests (VM-based)** — A fresh Ubuntu VM is created with virt-runner, the repo
  copied to it, and every enabled script of `tests/machine-config.test.yml` run once
  (`integration`) in config order. In the default `--mode cli` each run is
  `./kwisatz apply <target>`, i.e. a pyinfra deploy of the copied checkout, so the command
  operators and agents use is what is under test; `--mode script` keeps the pre-CLI path of
  running `tasks/<name>.sh` directly. See `tests/README.md` and `run-vm-tests.sh`.
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
| **ruff** | Static analysis / linting for python | Active (`uv run ruff check src tests deploy.py`) |
| **pytest (`tests/unit/`)** | Unit, CLI-integration and conformance layers | Active (`uv run pytest`) |
| **`./kwisatz`** | What the VM suite drives in its default mode | Active |

## Quality Check Definition

A change is considered ready to merge when:
1. All scripts pass `shellcheck` (for shell scripts) or `ruff` (for python) with no errors or warnings.
2. `tests/lint.sh` passes.
3. The VM integration suite passes: `tests/run-vm-tests.sh` → `SUITE: PASS`, for the scripts the change touches (or the default set, if the change is in the orchestrator, the CLI, or a shared `lib/`). Its default `--mode cli` is the one that counts; `--mode script` is the fallback used when a failure has to be attributed to the script rather than to the dispatch.
4. Idempotency holds — the suite's second phase must pass, i.e. the second run converges rather than errors or tears anything down.
