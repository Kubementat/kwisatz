# Plan: `uvx kwisatz` / `uv tool install kwisatz` — installed mode

Branch: `feature/uvx-distribution` (worktree `../worktrees/kwisatz-uvx-distribution`), merged to `develop`.
Semver: **MINOR** (additive; checkout mode keeps today's behaviour byte-for-byte).

## Goal

```bash
uvx --from git+https://github.com/Kubementat/kwisatz@vX.Y.Z kwisatz init   # works without PyPI
uvx kwisatz init && uvx kwisatz apply traefik                             # once published to PyPI
uv tool install kwisatz && kwisatz status
uv tool upgrade kwisatz                                                   # new tasks + new default pins
```

## Today

- `src/kwisatz/repo.py:resolve_repo` requires a checkout (`deploy.py` + `tasks/`); the wheel excludes
  `tasks/`, `lib/`, `templates/`. Config, `.kwisatz/` (lock, state, backups) and `logs/` live in the checkout.
- Tasks find `lib/helpers.sh`, `versions.yml` and siblings **relative to their own file** — so a bundled
  copy of the tree with the same layout runs unchanged.
- User-owned files (gitignored): `machine-config.yml`, `models.yml`, `gateway.yml`.
  Shipped defaults: `*.example`, `models.yml.default`, `versions.yml`.
- `kw_pin` (`lib/helpers.sh:~395`) reads `${KW_VERSIONS_FILE:-<repo>/versions.yml}`.

## Three locations

| What | Checkout mode (unchanged) | Installed mode |
|---|---|---|
| **payload** (read-only: `tasks/ lib/ templates/ deploy.py versions.yml *.example models.yml.default`) | repo root | `kwisatz/payload/` inside the installed package (`importlib.resources`) |
| **config** (user-owned: `machine-config.yml models.yml gateway.yml versions.yml`) | repo root | `$KWISATZ_HOME` or `${XDG_CONFIG_HOME:-~/.config}/kwisatz/` |
| **state** (`lock`, run state, config backups, `logs/`) | `<repo>/.kwisatz/`, `<repo>/logs/` | `${XDG_STATE_HOME:-~/.local/state}/kwisatz/` |

Mode selection (in `resolve_repo` or a new small resolver next to it):
`--repo` → `$KWISATZ_REPO` → nearest ancestor checkout → saved `config.json` repo → **installed payload**.
Only the last one is new; it replaces today's "no checkout found" error (exit 4) when the payload is present.
Never persist a payload path into state/logs as something to reuse — the uvx cache dir is ephemeral.

## Phases

### 1. Bundle the payload into the wheel
- hatch `[tool.hatch.build.targets.wheel.force-include]`: map each payload path explicitly to
  `kwisatz/payload/<path>`. Explicit list — never a glob over the repo root — so `machine-config.yml`,
  `models.yml`, `gateway.yml`, `.kwisatz/`, `logs/` can never land in a public artifact. Also keep them out of the sdist.
- Executable bits: tasks are invoked as `bash <file>` / `python <file>` (`orchestrator.task_command`), so modes don't matter; verify.
- Exclude `__pycache__`, `tests/`, `utilities/` (except whatever `versions check` needs — see phase 4), `skills/`.
- **Verify:** unit test builds the wheel (`uv build --wheel` into tmp), opens the zip, asserts payload
  files present and the user-owned files absent.

### 2. Payload / config / state split
- `Repo` grows (or a sibling dataclass) `payload: Path`, `config_dir: Path`, `state: Path`, `mode: "checkout"|"installed"`.
  In checkout mode all three equal today's values; `work`/`logs` keep their meaning.
- `resolve_config`: `-c/--config` → `$KWISATZ_CONFIG` → `<config_dir>/machine-config.yml`.
- `load_config` hint and `cmd_init` read examples from `payload`, write into `config_dir`
  (mode 0600, dir 0700, never overwrite without `--force`, backup as today).
  `init` stays scoped to `machine-config.yml`; tasks that need `models.yml`/`gateway.yml` already self-seed
  from the default/example (`setup-llm-gateway.sh:_require_gateway_yml`, `merge-model-entry.py`) — make them
  seed into the config dir (phase 3).
- `deploy_argv` uses `payload/deploy.py`; `exec.py` stops adding `<repo>/src` to `PYTHONPATH` in installed mode
  (the package is already importable from the running interpreter).
- **Machine-wide lock:** keep the checkout lock unchanged and additionally take a lock at
  `${XDG_STATE_HOME:-~/.local/state}/kwisatz/lock` in both modes, so a checkout run and a uvx run
  cannot deploy concurrently. One extra `Lock` acquired around the existing one — no new lock type.
- Pass to every task env (orchestrator task env, both engines): `KWISATZ_CONFIG_DIR=<config_dir>`.
- **Verify:** all existing unit tests pass unmodified; new tests for installed-mode resolution using a fake
  payload dir + `XDG_CONFIG_HOME`/`XDG_STATE_HOME` in tmp.

### 3. Tasks read user files from the config dir
- Add `kw_config_file <name>` to `lib/helpers.sh`: prints `${KWISATZ_CONFIG_DIR}/<name>` when
  `KWISATZ_CONFIG_DIR` is set, else `<repo root>/<name>` (today's path). Python equivalent where Python tasks
  need it (`render-llm-gateway-config.py`, `merge-model-entry.py`, `sync-models.py`): same rule, inline (a few lines).
- Callers: `setup-llm-gateway.sh` (`GATEWAY_YML` default), `models.yml` users in `lib/tensorfold-helper.sh`,
  `lib/strix-halo-helper.sh`, `tasks/merge-model-entry.py`, `tasks/sync-models.py`, the tensorfold/gufo setups,
  and anything else `grep -rn 'models.yml\|gateway.yml' tasks lib` finds. Explicit override vars (`GATEWAY_YML`, …) still win.
- Update each touched script's `--help`.
- **Verify:** shellcheck; unit test for `kw_config_file` (pattern of `tests/unit/test_versions.py` which already shells into helpers).

### 4. `versions.yml`: bundled defaults + sparse user overrides
- User file `<config_dir>/versions.yml` holds **only** overridden entries (same schema, partial fields allowed,
  e.g. just `version:`). It is never a full copy; `init` does not create it.
- `kw_pin` merges per key/field: user file (`${KW_VERSIONS_OVERRIDE:-$KWISATZ_CONFIG_DIR/versions.yml}`, if it
  exists) over the default file (`${KW_VERSIONS_FILE:-<payload>/versions.yml}`). `KW_VERSIONS_FILE` keeps its meaning.
  In checkout mode without `KWISATZ_CONFIG_DIR` there is no override file → exactly today.
- Precedence (highest first): task override env var (`FORGEJO_IMAGE`, `env:` in config, `apply --env`) →
  user `versions.yml` → bundled `versions.yml`.
- An override for a key the default file does not have is an error naming the file (typo guard).
- CLI `kwisatz versions`:
  - `list [--json]` — effective pin per component + source (`default` | `user`), plus a `stale` flag when the
    user pin is older than the bundled default (compare with `packaging.version` when both parse, else just "differs").
  - `set <component> <version> [--field version|image|digest]`, `unset <component>` — atomic write, 0600,
    backup into the state dir (reuse the `config.py` ruamel round-trip / backup helpers).
  - `check [--json]` — newer upstream than the effective pin; reuse the logic of `utilities/check-versions.sh`
    (call it from the payload if it is bundled, or port the lookup; pick the smaller change and say which).
- `doctor` warns on stale overrides and unknown keys.
- Add `versions` to the command table so `commands --json` lists it; follow the existing `--json` envelope and exit codes.
- **Verify:** unit tests for precedence, partial-field merge, unknown key, `set`/`unset` round-trip, stale detection.

### 5. CLI surface
- `doctor` / `info`: report `mode`, `payload`, `config_dir`, `state`, version (in `--json` too — additive keys only).
- `kwisatz install`: keep working in checkout mode; print a deprecation note pointing to `uv tool install kwisatz`
  (removal only in a future MAJOR). In installed mode it says it is already installed and exits 0.
- One version source: `pyproject.toml` `dynamic = ["version"]` read from `src/kwisatz/__init__.py`
  (hatch `[tool.hatch.version] path = ...`), so the wheel and `kwisatz --version` cannot disagree. `VERSION`
  stays the release file as documented in AGENTS.md.
- `./kwisatz` bash wrapper: unchanged.
- Migration: `kwisatz init --import <file>` copies an existing `machine-config.yml` into the config dir
  (validates it first; never overwrites without `--force`).

### 6. Docs
- README quickstart (installed mode first, checkout mode for contributors), `skills/kwisatz-assistant/SKILL.md`,
  `specification/features/kwisatz-cli/` (resolution order, locations, `versions` command, new env vars),
  `specification/project/conventions.md` (`kw_config_file`, override file), `CONTEXT.md` (payload, installed mode,
  config dir, version override), `AUTOMATIONS.md`, AGENTS.md release checklist: optional
  `uv build && uv publish` step after tagging (manual, user-run).

### 7. Tests
- Unit: `uv run pytest` green; `ruff check`, `shellcheck` on touched `.sh`, `yamllint` on touched `.yml`.
- Smoke (no VM needed): `uv build --wheel`, then in a tmp HOME:
  `uv tool run --from dist/kwisatz-*.whl kwisatz init`, `… status --json`, `… versions list --json`,
  `… doctor --json` — all outside any checkout.
- VM test (documented in `tests/README.md`, run by the user): fresh Ubuntu → install uv →
  `uvx --from <wheel> kwisatz init && kwisatz apply setup-docker`.

## Out of scope
- Publishing to PyPI (name availability unchecked; user decision and user action).
- Overriding templates or tasks from the config dir.
- Removing `kwisatz install` or the `./kwisatz` wrapper.

## Risks
- `sudo uvx kwisatz` puts config under `/root`: `doctor` warns when euid is 0.
- Tasks that compute `REPO_ROOT` and write into it (seeding defaults) must write into the config dir instead — the
  payload may be read-only.
- Renovate keeps bumping the repo's `versions.yml`; installed users receive bumps per release only (intended).
