# kwisatz

Automation scripts for installing and configuring a server or developer machine for LLM workflows and software development.

## Getting help

For any request about using, understanding, explaining, configuring, or setting up this repo — including `run-setup.sh`, `machine-config.yml`, or which services exist — read and follow `skills/kwisatz-assistant/SKILL.md`. Do not answer from your own knowledge.

## Core Facts

- systemd-based unix deployments and docker-based deployments; setup scripts generate `docker-compose.yml` for each service
- `ufw` is the firewall on the target ubuntu server; `traefik` is the reverse proxy — integration examples: [setup-forgejo.sh](tasks/setup-forgejo.sh) and [setup-openwebui.sh](tasks/setup-openwebui.sh)
- service data directory: `/srv/<service-name>` (e.g. `/srv/forgejo`)
- terminology: `CONTEXT.md`; specifications: `specification/project` (project-wide) and `specification/features` (per feature)
- write implementation plans to `./docs/plans`, research to `./docs/research`, tickets to `./.tickets`
- prefer the `codegraph_explore` tool for searching the codebase
- keep `./AUTOMATIONS.md` up to date

## Implementation Instructions

### Development Workflow

- features/bugfixes are developed in feature branches using `git worktree`
- finished branches are merged to `develop`; `develop` -> `main` is merged manually by the user when cutting a release (tag mechanics below)

### Releases (tag-based)

A release is an **annotated tag `vX.Y.Z` on the tip of `main`**, pushed to both remotes
(`forgejo`, `github`). Two things record it and they must move together: the tag, and the
`VERSION` file at the repo root (`X.Y.Z`, no `v`, trailing newline — the same value the tag
carries). The tag is what the release *means*; `VERSION` is the human-readable copy that
survives a tarball, so the release commit writes both. Nothing at runtime reads it
(`run-setup.sh` has no `--version`), and `VERSION` inside `tasks/*.sh` still pins *upstream*
component versions, not this repo — do not confuse the two. If the two ever disagree, the
tag wins and the `VERSION` line is the bug.

Semver for this repo: **MAJOR** = breaking `machine-config.yml` keys, removed/renamed
`tasks/` scripts, or changed `run-setup.sh` CLI; **MINOR** = new `tasks/` script or new config
option (backwards compatible); **PATCH** = fixes to existing scripts.

Semantics of the tag are the contract, not the number: `main` always points at what is
deployable, the tag names it.

Before releasing, `git fetch --all` and confirm `develop` contains what both remotes call
`main`:

```bash
git merge-base --is-ancestor forgejo/main develop && git merge-base --is-ancestor github/main develop
```

If that fails, `main` has commits `develop` does not — merge or rebase first instead of
pushing. A stale local `main` ref is the usual reason a release push is rejected; never use
`--force` to get around it.

Release checklist:

1. Green tree: lint everything touched (`shellcheck`, `yamllint`, `jq`, `hadolint`, `ruff`)
   and run the VM-based automation tests from `./tests/README.md` for the tasks you changed.
2. Release notes into `docs/releases/vX.Y.Z.md` (there is no `CHANGELOG.md`; these files *are*
   the changelog): `git log --no-merges --pretty='- %s (%ad)' --date=short <prev-tag>..develop > docs/releases/vX.Y.Z.md`,
   then hand-edit: lead with user-visible changes and config-key changes, drop noise.
   Write `X.Y.Z` to `VERSION` in the same commit, so the tagged tree carries both.
3. Move `main` to the release commit — `git branch -f main develop` (avoids churning the
   checked-out worktree) — then push: `git push forgejo main && git push github main`.
4. Tag and push it: `git tag -a vX.Y.Z -m "release vX.Y.Z"`, then
   `git push forgejo vX.Y.Z && git push github vX.Y.Z`. Annotated only, and never move a tag
   that is already on a remote — cut a new tag instead.

kwisatz has released **v1.0.0**; `docs/releases/` starts there, and for the history before it
`git log` on `main` is the only record.

### Important skills

- always load the `karpathy-guidelines` skill when planning or implementing changes

### Linting

Lint every created or modified file: `.sh` -> `shellcheck`, `.yml` -> `yamllint`, `.json`/`.js` -> `jq`, `Dockerfile` -> `docker run --rm -i hadolint/hadolint < Dockerfile`, `.py` -> `ruff check` (fallback `python3 -m py_compile`).

### Testing

- automation tests run via the VM-based approach in ./tests/README.md

### Common logic

- before writing or changing a script in `tasks/`, inspect `lib/` first and reuse what is already there

### bash Script Specifications

The detailed version of every rule below lives in `specification/project/conventions.md` — read it when touching that area.

#### Script Execution User

Non-root users run the scripts; the scripts use `sudo` for privileged operations.

#### Idempotency

Scripts must be re-runnable without destroying existing component data or configuration.

#### Configuration

Main options are environment variables with sensible defaults.

#### Help / Usage parameter

Keep the `--help` output of a modified script current with its implementation, parameters, and environment variables.

#### Re-run policy (converge by default)

Re-running a task script against an existing stack must converge it (re-render templates, reuse secrets, `docker compose up -d`, verify health) — see *Re-run policy: converge by default* in `specification/project/conventions.md`.

#### Configuration Paths

- services run as daemon/server or in docker containers: `/srv/<service-name>`
- host-side tools for the user: the tool's default directory under `$HOME`

#### Stack health verification

A script that starts a docker stack must prove it is up before reporting success: `wait_for_healthy` (from `lib/helpers.sh`) or an existing HTTP readiness poll after every `docker compose up -d`, bounded timeout, non-zero exit on failure — see *Stack health verification* in `specification/project/conventions.md`.

#### Templating

Put template files in the `templates/<component-name>` directory. Do NOT put inline templates into bash scripts unless explicitly required.

#### Secrets and templating

Secrets are never substituted into generated files: keep `${VAR}` literal in `templates/<component>/*` and resolve it at runtime from `/srv/<service>/.env` (mode 600) via `docker compose --env-file` or `env_file:`. Read every secret back from that `.env` before generating a new value, so re-runs never rotate credentials a persisted volume depends on. Non-secret layout values (ports, paths, host names, network names) may be `envsubst`ed. Render as the invoking user into a `mktemp` file and install with `sudo install -m 600`, never `sudo envsubst`. Full rule with examples: *Secrets and templating* in `specification/project/conventions.md`; shared helpers `env_file_get` / `env_file_write` in `lib/helpers.sh`.
