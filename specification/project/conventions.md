# Conventions

## Code Style

- All Bash scripts must start with `#!/usr/bin/env bash` and `set -eu`.
- Scripts must pass **ShellCheck** (`shellcheck <script>`) with no errors or warnings before being committed.
- Follow general Bash best practices:
  - Always quote variables: `"$VAR"`, not `$VAR`.
  - Use `[[ ]]` for conditionals instead of `[ ]`.
  - Prefer `$(command)` over backticks for command substitution.

## Naming Conventions

- No strict naming conventions enforced at this time.
- Task scripts follow the pattern `setup-<component>.sh` or `configure-<component>.sh` in `tasks/`
  (hyphen-separated, e.g. `setup-forgejo.sh`, `configure-firewall.sh`). Do not use underscores in
  script file names; underscores are reserved for bash function names (`setup_logging`).
- Environment variables use `UPPER_SNAKE_CASE`.

## Architectural Patterns

- **Idempotency** — Every task script must be safe to run repeatedly. Use guard checks (`command -v`, `dpkg -l`, file existence) to skip already-completed work.
- **Non-interactive by default** — Scripts must not prompt the user for input during normal execution. Interactive behaviour is only allowed when the script is explicitly invoked with a `--interactive` flag.
- **Re-run policy: converge by default** — When the target stack already
  exists, a task script must re-render config from `templates/<component>/`
  (never inline heredocs), reuse existing secrets instead of regenerating
  them, run `docker compose up -d` so Docker reconciles only what changed,
  and prove the stack healthy (see *Stack health verification*). It must not
  run `docker compose down`, and never `docker compose down -v`, in a normal
  non-interactive run. `--interactive` may additionally offer
  tear-down/re-create (converge is the default answer; `y` is the only path
  that may run `down`); volume wipes only where a wipe prompt already exists
  (concourse). `--force` and `<NAME>_FORCE=true` keep their meaning (explicit
  re-create) and win over `INTERACTIVE`.

  Cases that cannot converge onto a running stack — print what diverged plus
  the exact converge or interactive re-create command, then exit 0:
  - **traefik** mode/dashboard/ACME settings, `DNS_PROVIDER`, `USE_SOCKET_PROXY`,
    ports — static compose args; the ACME account is already issued:
    `docker compose -f ${COMPOSE_FILE} up -d --force-recreate traefik`,
    else re-run with `--interactive`.
  - **nextcloud** admin user/password — applied only at first install:
    reuse the stored `.env`; change the password with
    `docker exec --user www-data <container> php occ user:resetpassword <user>`.
  - **matrix** admin password — applied only at first install: the stored
    `.env` value stays in effect (warned, not exited: the rest of the stack
    still converges); change it with
    `docker exec -it matrix-mas mas-cli manage set-password <user> '<new>'`.
    `MATRIX_SERVER_NAME` is the one exception to "exit 0": it is the
    server's identity, so a different value is a hard error (exit 1) and
    nothing is modified.
  - **concourse / planka** credentials — tied to the persisted postgres
    volume: reuse the stored `.env`; wipe only via the interactive prompt.
  - **vllm / vllm-omni / colqwen** model args — baked into the container
    command at create time: `cd ${PROJECT_DIR} && docker compose up -d --force-recreate`.
  - **excalidraw** container args — bare `docker run`, nothing for compose to
    reconcile: `docker rm -f ${CONTAINER_NAME}` then the exact `docker run`
    line.
- **Never `exit 0` silently on an existing stack** — either converge, or print
  the diverging keys and the exact converge/re-create command.
- **Help and Usage instructions** - All shell scripts have a `--help` parameter to display usage and configuration information
- **Env var configuration** — All tunable values must be exposed as environment variables with sensible defaults defined at the top of each script.
- **Single-process sourcing** — Task scripts are sourced (not executed as subprocesses) so that env vars flow between scripts.

## Output and Logging

- Scripts should produce **colourful, expressive output** so users can see the most important information at a glance.
- Use colour-coded messages to distinguish status levels (e.g., green for success, yellow for warnings/skipped steps, red for errors, blue/cyan for informational progress).
- Clearly indicate what is being installed, what was skipped (already present), and what completed successfully.

## Libraries and Utilities

- **Firewall:** Always use `ufw`. Never use `iptables` directly.

## Version pins

- Every upstream version a task installs — docker image tag/digest, GitHub release or tag,
  PyPI version, git commit — is pinned in `versions.yml` at the repo root, one entry per
  component (`datasource`, `package`, `version`, optional `digest`/`versioning`; values
  quoted). No version literal lives in `tasks/*.sh`; `tests/unit/test_versions.py` fails on one.
- Scripts read the pin as the *default* of their override variable, as a plain assignment
  after `lib/helpers.sh` is sourced, so a missing key aborts under `set -e`:
  `OPENWEBUI_IMAGE="${OPENWEBUI_IMAGE:-$(kw_image openwebui)}"` (`kw_version`, `kw_pin <key>
  <field>` for split tags, digests and commits). `--help` prints the value from the file.
- A floating default (`latest`, `stable`, a bare major) is a pin too: pin the exact release;
  scripts may still accept `latest` as an explicit override.
- A pin whose next major breaks persisted data carries `# HELD <reason>` in `versions.yml`
  **and** an `allowedVersions` rule in `renovate.json`; the guard test keeps both in sync.
- Re-runs must pick a bumped pin up: never freeze an image tag into a file the script does
  not re-render (setup-netbird refreshes its `.env` image lines on every run).
- Renovate (`renovate.json`, `tasks/setup-renovate.sh`) proposes the bumps;
  `utilities/check-versions.sh` lists what is outdated.
- **User override file.** `kw_pin` also reads `${KW_VERSIONS_OVERRIDE:-$KWISATZ_CONFIG_DIR/versions.yml}` when it
  exists: a *sparse* file (only the changed entries/fields) merged per key and per field over the default file
  (`KW_VERSIONS_FILE`, else the bundled `versions.yml`). Overriding `version` without `digest` drops the default's
  digest. A key the default lacks is an error naming the file. Precedence: task override variable → user
  `versions.yml` → bundled `versions.yml`. Without `KWISATZ_CONFIG_DIR` (checkout mode) there is no override file.

## User-owned files: `kw_config_file`

A task never writes into its own repo root — installed mode ships it read-only. User-owned files
(`models.yml`, `gateway.yml`) are addressed with `kw_config_file <name>` (`lib/helpers.sh`): it prints
`$KWISATZ_CONFIG_DIR/<name>` when kwisatz runs installed, else `<repo root>/<name>`. Shipped defaults
(`*.example`, `models.yml.default`) stay read from the repo root. Python helpers apply the same rule
inline (`KWISATZ_CONFIG_DIR` or the repo root). An explicit override variable (`GATEWAY_YML`, `MODELS_YML`) wins.

## Secrets and templating

- Secrets (passwords, keys, tokens, URLs containing credentials) are **never**
  substituted into a generated file: keep `${VAR}` literal in
  `templates/<component>/*` and resolve it at runtime from
  `/srv/<service>/.env` (mode 600) via `docker compose --env-file` or
  `env_file:` in the service section. Non-secret layout values (ports, paths,
  host names, network names) may be `envsubst`ed at render time.
- Every secret is **read back** from the service `.env` before generating a new
  value, so re-runs never rotate credentials a persisted volume depends on
  (see `setup-monitoring.sh` / `setup-concourse.sh`).
- `envsubst` reads its **environment**: render as the invoking user into a
  `mktemp` file and install with `sudo install -m 600` (see `setup-traefik.sh`),
  never `sudo envsubst`.
- Shared helpers: `lib/helpers.sh` (`env_file_get`, `env_file_write`).
  `AGENTS.md` carries the short-form version of this rule; this section is
  canonical.

## Stack health verification

A task script that starts a docker stack must prove the stack is up before
reporting success: `wait_for_healthy` (or an HTTP readiness poll where one
already exists) after every `docker compose up -d`, with a bounded timeout
and a non-zero exit on failure.

- Use `wait_for_healthy <timeout_s> <container-id...>` from `lib/helpers.sh`
  with the container list from `docker compose ps -q`, passing the same
  `--env-file`/`-f` (and `sudo`, where used) as the `up -d` call. The helper
  returns 1 (it never exits) when a container is exited/dead/restarting or
  unhealthy — or when the bounded timeout is reached — naming the offending
  containers and pointing at the logs. Containers without a healthcheck count
  as ready once running.
- Call it as
  `wait_for_healthy … || error "<service> stack did not come up — see the status output above"`
  so a crash-looping stack can never be reported as success.
- Existing HTTP readiness polls (planka, openwebui, concourse, …) are kept:
  they prove the app answers, the helper proves the containers are alive.
- The timeout is exposed as an env var with a sensible default (`WAIT_TIMEOUT`,
  180 s; inference stacks use a script-specific, longer default) and
  documented in the script's `--help`.
- Never swallow `docker compose up -d` with `|| true`, and never print a
  success summary before the gate.

## Anti-Patterns

- **No interactive prompts** unless `--interactive` is explicitly passed.
- **No unquoted variables** — always quote to prevent word splitting and globbing.
- **No ShellCheck violations** — all scripts must be clean before merge.
