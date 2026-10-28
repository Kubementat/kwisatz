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
