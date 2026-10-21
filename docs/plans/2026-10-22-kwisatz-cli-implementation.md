# kwisatz CLI — implementation plan (v1 = M1 + M2)

Spec: `docs/features/kwisatz-cli-specification.md` (R-xxx ids below refer to it).
Branch: `feat/kwisatz-cli`, rebased onto `develop` (4397d5c).

## Current state (before this plan)

M1 code exists (`src/kwisatz/`, 8 commands, `deploy.py` reduced to a pyinfra adapter,
4 conformance tests). Rebased 2026-10-22; the PRD commit was skipped as already applied.

Measured defects from the review of that code:

| # | Defect | Requirement broken |
|---|---|---|
| D1 | *(not a defect — the observed double stdout was my own probe stub printing its format string twice; verified `exec._drain` echoes each line exactly once)* | — |
| D2 | `kwisatz doctor` always crashes: `checks.checks()` called without `config` | R-OPS-003 |
| D3 | `ConfigError` escaping a handler → Python traceback, exit 1 | R-OUT-006, §9 |
| D4 | A raised `CliError` is recorded but never printed in human mode → silent `exit 3` | R-OUT-006 |
| D5 | Unknown command: argparse rejects with no `did you mean` | R-CMD-002 |
| D6 | 8 ruff findings; ruff also tries to parse the `./kwisatz` shell shim (24 bogus syntax errors) | R-TEST-005 |
| D7 | `tests/unit/conftest.py` joined the stub env-key regex with spaces, so the env contract was never asserted (fixed) | R-ARCH-102 |
| D8 | Only 4 tests exist; no unit layer, no CLI-integration layer | R-TEST-001, R-TEST-003 |

Missing commands (M2): `config`, `services`, `logs`, `state`, `models`, `run`,
plus `--keep-going`, `--events`, `--quiet` (single result line), `--no-sudo-warmup`,
config-change warning, and the whole documentation deliverable set (R-DOC-002…006).

Deliberate deviation from R-ARCH-002/003: the package lives in `src/kwisatz/`, because
R-ARCH-003 requires the executable `./kwisatz` *at the repo root* and a root-level
`kwisatz/` package would collide with it. Recorded in `architecture.md`.

## Work packages

1. **Correctness** — D1–D5, D7; central `ConfigError → exit 3`; error printing in
   `_finish`; did-you-mean pre-scan.
2. **M2 command surface** —
   `config` (`show/validate/enable/disable/set/unset/args/path/init`, ruamel round-trip,
   atomic 0600 write, 5-copy backups, diff output, all-at-once validate: R-CFG-001…007,
   R-ARCH-200…202), `services` (R-OPS-001/002, `/srv/*/docker-compose.yml` + systemd +
   container health via the same signals `lib/helpers.sh:wait_for_healthy` uses),
   `logs` (R-OPS-005), `state` (R-STA-100/101), `models` (R-MOD-001/002),
   `run` (R-CMD-004, R-EXIT-001).
3. **Apply completeness** — `--keep-going` (exit 8), `--events` NDJSON, quiet one-liner,
   sudo warm-up for multi-target runs, config-changed-since-last-apply warning,
   doctor: port collisions, `/srv` free space, unhealthy stack → exit 5.
4. **Tests** — unit layer over `plan.py` / `config.py` / `jsonio.py` / `exec.py` /
   `state.py` / lock, and a CLI-integration layer running real subprocesses against a
   tmp checkout (ordering, single target, unconfigured target, `--dry-run` writes
   nothing, `--json` is one document, every §9 exit code, lock contention).
5. **Docs** — README "Using the kwisatz CLI", `architecture.md` entrypoint table +
   deviation note, `specification/features/kwisatz-cli/`, `skills/kwisatz-assistant/SKILL.md`,
   `AUTOMATIONS.md` header, and a `docs/research/` note for the review findings.

## Decisions taken here (they were §16 open questions)

- State/logs stay repo-local (`<repo>/.kwisatz`, `<repo>/logs`) — consistent with the
  already-gitignored `logs/`.
- `run-setup.sh` stays as it is (R-ARCH-103); the CLI is additive, pyinfra remains the
  full-apply path for CI.
- `install` does not silently `curl | sh` the uv installer: it prints the exact pinned
  command and offers `--with-uv` (which prompts unless `--yes`), because R-SAFE-003
  forbids the CLI mutating the host outside a task script.
