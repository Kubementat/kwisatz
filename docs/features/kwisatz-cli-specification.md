# kwisatz CLI — Product Requirements Document (v1)

| | |
|---|---|
| **Status** | Draft for review |
| **Component** | `kwisatz` CLI (new) — Python entrypoint over the existing orchestrator |
| **Audience** | Repo maintainers, implementers, operators of a kwisatz-managed machine, AI coding agents |
| **Related** | `README.md`, `AUTOMATIONS.md`, `specification/project/architecture.md`, `specification/project/conventions.md`, `CONTEXT.md`, `deploy.py`, `run-setup.sh`, `skills/kwisatz-assistant/SKILL.md` |
| **Terminology** | *task* / *target* / *script* — per `CONTEXT.md` § Automation |

---

## 1. Problem statement

kwisatz today is a pile of well-behaved bash scripts plus a thin pyinfra orchestrator. The
machinery is sound; the *interface* is a directory listing.

To install Traefik today an operator must:

1. know `tasks/setup-traefik.sh` exists (`ls tasks/`, or `AUTOMATIONS.md`, or grep the README);
2. know that the right way to run it is not `./tasks/setup-traefik.sh` during a managed setup,
   but to set `enabled: true` for it in `machine-config.yml` so it runs in config order;
3. hand-edit `machine-config.yml` — YAML with comments that carry real operational warnings;
4. run `./run-setup.sh apply`, which runs **every** enabled script, not just Traefik;
5. or bypass the orchestrator entirely and run the script by hand, losing the env contract, the
   config ordering, and the record of what is configured.

For an AI agent the friction is worse, because every step is guesswork: the agent cannot
discover the catalog of targets, cannot run exactly one target through the sanctioned code path,
cannot tell what is installed and healthy, and cannot read the outcome as data. It ends up
`cat`-ing `README.md` and `AUTOMATIONS.md` (hundreds of KB) and invoking `bash tasks/*.sh`
ad hoc — the exact behaviour this CLI exists to replace.

**One sentence:** turn kwisatz from "a repo you execute" into "a tool you *use*" — one command
binary, a discoverable catalog, single-target execution that goes through the same code path as a
full apply, and machine-readable output.

### 1.1 Current vs. target workflow

| Need | Today | With `kwisatz` |
|---|---|---|
| Install the tool on a new machine | clone repo, install uv, `./run-setup.sh status` | `kwisatz install` → `kwisatz init` |
| Full provisioning run | `./run-setup.sh apply` | `kwisatz apply` |
| Install **one** service | edit config → `run-setup.sh apply`, or hand-run the script | `kwisatz apply traefik` |
| Update one service | hand-run `./tasks/setup-traefik.sh` | `kwisatz apply traefik` (converges, with config env applied) |
| What will this run do? | `./run-setup.sh status` (enabled scripts only) | `kwisatz status` (order, env keys, preconditions) |
| What is available? | `ls tasks/` + `AUTOMATIONS.md` | `kwisatz list [--all]` |
| How does this target work? | `bash tasks/setup-traefik.sh --help` | `kwisatz info traefik` |
| Enable/disable a service | `$EDITOR machine-config.yml` | `kwisatz config enable traefik` |
| Set one option | `$EDITOR machine-config.yml` | `kwisatz config set traefik TRAEFIK_PORT=8443` |
| Is it running? | `docker ps`, `systemctl`, port probes | `kwisatz services` |
| Read the logs | `docker compose -f /srv/x/docker-compose.yml logs` | `kwisatz logs traefik` |
| Report results to an agent | read stdout, parse bash | `kwisatz <cmd> --json` |
| Ad-hoc script run | `INTERACTIVE=true ./tasks/setup-forgejo.sh` | `kwisatz apply forgejo --interactive` |

---

## 2. Goals, success metrics, non-goals

### 2.1 Goals

- **G1 — Convenience.** The three everyday operations (install the tool, provision the whole
  machine, apply one service) each need one command and no manual config editing.
- **G2 — Agent usability.** Every command is non-interactive by default, has a stable exit code,
  and exposes the same result as JSON on stdout. An agent can discover the whole CLI surface
  without reading a document.
- **G3 — Parity.** There is exactly one execution contract. `kwisatz apply` (full),
  `kwisatz apply <target>` and `run-setup.sh apply` must produce the identical command line and
  identical environment for the same config.
- **G4 — Safety.** Re-runnable, no destructive surprises, one writer at a time, secrets never
  printed.
- **G5 — No regression.** `run-setup.sh`, `deploy.py`, `tasks/*.sh`, `tests/run-vm-tests.sh` and
  the existing docs keep working. The CLI is additive.

### 2.2 Success metrics

| Metric | Baseline (today) | v1 target |
|---|---|---|
| Commands to install Traefik on a configured box | ≥ 3 (edit + apply + inspect) | 1 (`kwisatz apply traefik`) |
| Commands to enable a service | ≥ 2 (edit YAML, verify) | 1 (`kwisatz config enable <t>`) + 1 verify (`kwisatz status`) |
| Agent turns to complete "install and report the state of traefik" | 8–15 tool calls, several doc reads | ≤ 4 tool calls, 0 doc reads |
| `kwisatz list --json` | n/a | complete, valid catalog of all `tasks/*` with `enabled`, `description`, env keys |
| Config round-trip | manual | `kwisatz config enable x` changes one flag and **zero** comment bytes |

### 2.3 Non-goals (v1)

- **N1** — Remote/multi-host execution, SSH, inventory. kwisatz remains "the box you are on".
- **N2** — Replacing task scripts, `lib/`, `templates/`, or the bash idempotency model. The CLI is
  a front end, not a new engine.
- **N3** — A full dependency/`requires:` engine for all 58 scripts. v1 ships an advisory ordering
  table (§6.5), not a resolver.
- **N4** — Secrets management, an encrypted config store, or moving secrets out of
  `/srv/<service>/.env`.
- **N5** — Packaging on PyPI, Debian packages, or a service manager.
- **N6** — macOS/Windows support. Target is Ubuntu 22.04/24.04 (per `architecture.md`); other
  Linux distros get "runs, warns, best effort".
- **N7** — Declarative drift reconciliation (`ensure present/absent`, diff-plan against reality).
  Converge-by-default stays inside the task scripts.
- **N8** — A daemon, a web UI, a TUI.

---

## 3. Users and personas

| Persona | Needs | Primary commands |
|---|---|---|
| **Operator (human)** | one command, clear output, undo/preview paths | `install`, `init`, `apply`, `status`, `config`, `services`, `logs` |
| **AI coding agent** | non-interactive, discoverable, `--json`, deterministic exit codes, no hanging prompts | `commands --json`, `list --json`, `info --json`, `apply --json`, `services --json` |
| **CI / script author** | pipeable, `--quiet`, `--dry-run`, exit codes that mean something | `apply --dry-run --quiet`, `config validate` |
| **Developer of this repo** | works from a checkout without installing, runs one script fast | `./kwisatz apply <target>`, `--repo`, `--verbose` |

---

## 4. Concept model

```text
target  = a name the user can point at.  A config key, a task script basename, or a service
          alias that resolves to exactly one script.
plan    = ordered list of (target, resolved command, effective env) that apply would run.
state   = per-target record of the last apply (timestamp, repo git SHA, duration, exit code).
service = a running thing on the host (compose stack, systemd unit, port) that kwisatz can report.
```

Rules:

- `target` resolves to `tasks/<name>.sh`, else `tasks/<name>.py` — the same precedence
  `deploy.py:task_command()` uses.
- A target **may** be absent from `machine-config.yml`; it is still runnable (§6.2.3).
- Names are matched without the `setup-`/`configure-` prefix (`CONTEXT.md` — task scripts follow
  `setup-<component>.sh`), so `traefik`, `setup-traefik`, `configure-firewall` and
  `firewall` all resolve.

---

## 5. Functional requirements — command surface

Canonical form: `kwisatz <command> [args] [flags]`. Commands are lowercase, single word, verbs for
mutations and nouns for reads. Aliases are allowed but must be documented in the same table and
must not grow new behaviour.

### 5.1 Command map

| Command | Purpose | Mutates? | Milestone |
|---|---|---|---|
| `kwisatz install` | bootstrap the CLI + prerequisites on this machine | yes | M1 |
| `kwisatz init` | first-run: create `machine-config.yml`, run doctor | yes | M1 |
| `kwisatz apply [TARGET...]` | run one/many/all targets | yes | M1 |
| `kwisatz status` | read-only plan preview | no | M1 |
| `kwisatz list` | discover targets | no | M1 |
| `kwisatz info TARGET` | everything about one target | no | M1 |
| `kwisatz doctor` | host prerequisites + stack health | no | M1 |
| `kwisatz config …` | inspect/edit `machine-config.yml` | yes | M2 |
| `kwisatz services` | what is running right now | no | M2 |
| `kwisatz logs [TARGET]` | logs of the target's stack/journal | no | M2 |
| `kwisatz run TARGET -- <args>` | pass-through escape hatch | yes | M2 |
| `kwisatz state [TARGET]` | last-apply history | no | M2 |
| `kwisatz models …` | model-catalog wrapper (`tasks/sync-models.py`) | yes | M2 |
| `kwisatz commands` | machine-readable CLI self-description | no | M1 |
| `kwisatz completions <shell>` | bash/zsh/fish completion script | no | M3 |
| `kwisatz upgrade` | update the repo checkout and its venv | yes | M3 |
| `kwisatz uninstall` | documented removal, no silent teardown | yes | M3 |

### 5.2 Global options (all commands)

```text
-c, --config <file>   read machine-config.yml from <file> (default: $KWISATZ_CONFIG, repo default)
-C, --repo <dir>      operate on the kwisatz checkout rooted at <dir>
-n, --dry-run         do not mutate; print the plan the run would have executed
-y, --yes             assume yes where a command would otherwise prompt
        --interactive allow the underlying task script to prompt (implies a TTY is required)
        --json        machine-readable single JSON document on stdout
    --quiet / -q      suppress progress output; still print errors and the result line
    --verbose / -v    raise verbosity (repeatable)
        --no-color    no ANSI (also honoured via NO_COLOR / non-TTY stdout)
        --env K=V     set K for the task run (repeatable); wins over config `env:`
        --timeout <s> wall-clock budget for the whole command, default 3600
        --lock-timeout <s> how long to wait for another kwisatz run, default 0 (fail fast)
-h, --help            help      --version  version + repo SHA
```

- `--dry-run` and `--yes` are mutually exclusive with `--interactive`.
- `--json` + `--interactive` is a **usage error** (exit 2): an agent asking for JSON and prompts at
  once is a bug we want loud.
- `--dry-run` never needs sudo, never writes state, never touches `/srv`.

### 5.3 Requirements

- **R-CMD-001 (MUST, M1)** — Every command is reachable via `kwisatz <cmd> --help`, and the help
  text is generated from one source (the command table + argument spec) so flag drift between help
  and implementation is impossible.
- **R-CMD-002 (MUST, M1)** — Unknown command or unknown flag → usage text on **stderr**, exit
  `2`, and a `did you mean <x>?` suggestion computed against the command/target name (Levenshtein)
  when one candidate is within one edit.
- **R-CMD-003 (SHOULD, M1)** — `kwisatz` with no arguments prints the command map (§5.1) and the
  repo/config it resolved, exit `2`.
- **R-CMD-004 (MUST, M2)** — `kwisatz run <target> -- <args…>` resolves `<target>` and executes
  the script with `<args…>` appended verbatim, so flag-bearing escape hatches
  (`--force`, `--check`, `--interactive`, `--uninstall`) stay reachable. Everything after `--` is
  not parsed by the CLI.

---

## 6. Functional requirements — apply

### 6.1 `kwisatz apply` (no target)

Full-machine run, identical semantics to `./run-setup.sh apply`.

- **R-APP-001 (MUST)** — Load `<repo>/machine-config.yml` (or `--config`), take the `.scripts`
  mapping, filter `enabled: true`, execute in config order — by running `deploy.py` (R-ARCH-101),
  not by executing the scripts one by one. The CLI computes the plan first (that is what
  `status`/`--dry-run` show, and what the warnings and the ordering advisory are built on), then
  hands the resolved names to the deploy in that order.
- **R-APP-002 (MUST)** — Stop at the first failure with the exit code defined in §9; later scripts
  do not run. Print, on the failing line, the exact command that would retry **only** that target:
  `kwisatz apply <target>`.
- **R-APP-003 (MUST)** — Emit the same `-->` warning lines `deploy.py` emits today for
  non-canonical `enabled:` spellings and for `env:`/`args:` shape problems in disabled scripts.
  The warning text is the contract; it is reused verbatim from the shared module (§11.3).
- **R-APP-004 (SHOULD)** — Print a header per script: `[3/12] setup-traefik — Install and
  configure Traefik reverse proxy`, taken from the config `description:`.

### 6.2 `kwisatz apply <target>` — the headline feature

#### 6.2.1 Resolution

1. Exact config key (`setup-traefik`).
2. Config key with `setup-` / `configure-` added or stripped (`traefik`).
3. Unique file match in `tasks/` (`tasks/traefik.sh` — does not exist, but must resolve if it did).
4. Otherwise: error `2` (ambiguous) or `3` (unknown), listing the candidates.

- **R-TGT-001 (MUST)** — A name that matches more than one candidate (e.g. a `setup-docker.sh` and
  a `setup-docker.py`) is an error listing both, never a silent pick.
- **R-TGT-002 (SHOULD)** — Ambiguity between `x.sh` and `x.py` resolves to the `.sh` **and warns**,
  matching `deploy.py:task_command()` exactly.

#### 6.2.2 Execution

- **R-APP-010 (MUST)** — Single-target apply runs exactly the command the full apply would have
  run for that script: same `bash`/`sys.executable` choice, same `INTERACTIVE` handling, same
  `env:`, same `args:`, same `/dev/null` stdin. Both paths are the same deploy, the subset picked
  with `--data select=`, so this is structural and not a promise kept by discipline — and §11.3's
  conformance test still enforces it, which is the single most important correctness property of
  the CLI.
- **R-APP-011 (MUST)** — Config `env:` is applied. "Run just one script" must not silently drop the
  options the operator configured for it — that would make the CLI's single-target path produce a
  different install than `kwisatz apply`.
- **R-APP-012 (MUST)** — CLI `--env K=V` overrides config `env:`; a target applied through the CLI
  always gets `INTERACTIVE=false` unless the operator passed `--interactive` or the config sets
  `INTERACTIVE: "true"`.
- **R-APP-013 (MUST)** — `--interactive` execs the script with the CLI's own stdin/stdout/stderr
  attached (no `/dev/null`) and `INTERACTIVE=true`; if no TTY is attached it fails fast, exit `4`,
  message `--interactive requires a terminal`.
- **R-APP-014 (SHOULD)** — Stream the script's output live rather than buffering. Long installs
  (llama.cpp builds) are minutes long; buffering looks like a hang.

#### 6.2.3 Target not in `machine-config.yml`

Ad-hoc execution is the whole point of the feature request ("right now I execute `./tasks/*.sh`
manually a lot").

- **R-APP-020 (MUST)** — If the target resolves to a file in `tasks/` but has no config entry, run
  it with the ambient environment plus `INTERACTIVE=false`, and print a warning:
  `--> note: 'setup-unsloth' is not in machine-config.yml — running with script defaults`.
- **R-APP-021 (SHOULD)** — Suggest the fix in the same message:
  `kwisatz config enable setup-unsloth` so the next `kwisatz apply` includes it.
- **R-APP-022 (MUST)** — A target matching neither a config key nor a file is error `3` with the
  list of the closest 5 target names.

#### 6.2.4 Multiple targets

- **R-APP-030 (MUST)** — `kwisatz apply a b c` runs each resolved target once, in config order for
  the configured ones, then the unconfigured ones in the order given.
- **R-APP-031 (SHOULD)** — Stop at first failure by default; `--keep-going` (v1: MAY) runs all and
  exits `8` if any failed.

### 6.3 `kwisatz status`

Read-only plan preview, strictly a superset of `./run-setup.sh status`.

- **R-STA-001 (MUST)** — Print the ordered enabled plan: index, target name, `description:`, the
  resolved command with env values masked (§8.4), the config `args:`.
- **R-STA-002 (SHOULD)** — Append the runtime annotation from §6.7: `docker · running`, `systemd ·
  stopped`, `not installed`. The machine is only half-described as "fourteen YAML keys".
- **R-STA-003 (SHOULD)** — List disabled entries in a collapsed block (`37 disabled; kwisatz list
  --all`) instead of hiding them, since "what is *not* installed" is the other half of the operator
  question.
- **R-STA-004 (MUST)** — Never execute a task script, never require sudo, never require the venv.

### 6.4 `kwisatz list` / `kwisatz info`

- **R-DSC-001 (MUST)** — `kwisatz list` prints the union of config keys and `tasks/*` files: name,
  kind (`sh`/`py`), enabled state, description, source (config default `machine-config.yml`,
  `AUTOMATIONS.md` where a matching section exists).
- **R-DSC-002 (SHOULD)** — `--all` includes disabled entries; the default view is "what will run".
- **R-DSC-003 (MUST)** — `kwisatz info <target>` prints: resolved script path, exists-in-config,
  enabled, `args:`, env **keys** (values masked), the script's `--help` output, the runtime state,
  the last apply record (§6.9), and the documented prerequisites (§6.5).
- **R-DSC-004 (SHOULD)** — `kwisatz list --group <topic>` filters by the `AUTOMATIONS.md` section
  headings (System & Infrastructure, Inference, Agents, Backup, …) so a human or agent can reason
  about "what do I need for local LLM inference" without the 80 KB file.

### 6.5 Ordering and prerequisite advisory

Real footguns exist (sshd before firewall, `setup-basics` first, docker before traefik, GPU tasks
require `setup-nvidia-container` + `setup-memory-safety`). The CLI must not invent a dependency
graph, but it must not stay silent either.

- **R-ORD-001 (MUST, M1)** — Ship a single built-in table `kwisatz/data/prerequisites.yml` mapping
  a handful of targets to (a) required-in-config-order predecessors, (b) host facts that must hold.
  Seeded from the comments already present in `machine-config.yml.example`.
- **R-ORD-002 (MUST)** — On `apply` (single or full), violations of that table print
  `--> WARNING:` and a copy-pasteable command; they do **not** abort.
- **R-ORD-003 (MUST)** — `kwisatz doctor --json` reports the same table as checks, so an agent can
  ask "is this box ready for vllm?"
- **R-ORD-004 (SHOULD, M3)** — A config entry may declare `requires: [setup-docker]`. v1 does not
  migrate existing scripts.

### 6.6 `kwisatz config`

The single highest-value convenience after `apply <target>`: hand-editing YAML with warning-bearing
comments is the most error-prone thing in the current workflow.

- **R-CFG-001 (MUST)** — Subcommands: `show [TARGET]`, `validate`, `enable TARGET`,
  `disable TARGET`, `set TARGET KEY=VALUE`, `unset TARGET KEY`, `args TARGET -- <flags>`,
  `init [--from-example=base|inference]`, `path`.
- **R-CFG-002 (MUST)** — Edits are comment-preserving and order-preserving (round-trip YAML,
  `ruamel.yaml`; §11.4). Acceptance: applying `enable` to a file with 20 comments changes exactly
  one line and leaves the rest byte-identical.
- **R-CFG-003 (MUST)** — Writes go to a temp file, then an atomic rename, mode `0600` (the file is
  plain text next to API keys — `deploy.py`'s own caveat).
- **R-CFG-004 (MUST)** — `config set` writes string scalars with the exact quoting that
  `deploy.py` reads back correctly (`'true'`, `'8080'`), and refuses a value that would flip a
  boolean into the non-canonical spelling that warns.
- **R-CFG-005 (MUST)** — Every mutation prints the resulting diff (`-` / `+` lines, no secrets) and
  the next command to run: `kwisatz apply <target>` or `kwisatz apply`.
- **R-CFG-006 (SHOULD)** — `config enable --with-deps` (v2, MAY) also enables the targets in the
  ordering table.
- **R-CFG-007 (MUST)** — `config validate` runs the exact `deploy.py` shape checks (mapping shape,
  `enabled` spellings, `env`/`args` types) plus "key has no file in `tasks/`" and reports all
  errors at once, not the first one.

### 6.7 `kwisatz services` / `kwisatz doctor` / `kwisatz logs`

- **R-OPS-001 (MUST)** — `kwisatz services` reports, for every installed stack: name, manager
  (`docker` | `systemd` | `process`), state (`running` | `unhealthy` | `restarting` | `stopped` |
  `unknown`), listening ports, last start time, `/srv/<service>` presence. Discovery is by
  convention: `/srv/*/docker-compose.yml`, systemd units whose name matches a task, plus the
  containers kwisatz started.
- **R-OPS-002 (SHOULD)** — Unhealthy is derived from the same health signals `lib/helpers.sh
  wait_for_healthy` uses (container `health: starting|unhealthy|restarting`), so CLI and task
  script never disagree about "is it up".
- **R-OPS-003 (MUST)** — `kwisatz doctor` checks at minimum: OS/Ubuntu version, sudo
  availability (`sudo -n true`), `uv`, python, docker daemon, GPU presence for GPU-only targets,
  port collisions for configured `*_PORT` values, disk space under `/srv`, and the §6.5 table.
  Exit `0` = all good, `4` = missing prerequisite, `5` = a running stack is unhealthy.
- **R-OPS-004 (SHOULD)** — `kwisatz doctor --fix` (MAY, M3) applies only the actions that are
  themselves kwisatz tasks (`uv`, `setup-docker`), never a bespoke fix.
- **R-OPS-005 (MUST)** — `kwisatz logs [TARGET] [--since 10m] [--tail 200] [-f]`: compose logs for
  a docker stack at `/srv/<service>/docker-compose.yml`, `journalctl -u` for a systemd target,
  the last stored apply log otherwise. `-f` is bounded by `--timeout`.

### 6.8 `kwisatz models`

- **R-MOD-001 (MUST)** — Thin, honest wrapper over `tasks/sync-models.py`: `models sync`,
  `models status`, `models show`. It forwards `--dry-run`/`--json` and maps that tool's exit codes
  (`0` ok / `1` pre-flight / `2` mutation) onto §9.
- **R-MOD-002 (SHOULD)** — `kwisatz status` appends the model catalog summary (N models, M served,
  llama-swap reachable) because that is the other half of "what does this machine do".

### 6.9 `kwisatz state`

- **R-STA-100 (SHOULD)** — Persist one record per target: `target`, `timestamp`, `repo git SHA`,
  `duration_s`, `exit_code`, `command`, `config path`, `state file hashes of /srv/<svc>/.env`.
  Written **after** the run, never before (a crashed run must not look like a success).
- **R-STA-101 (SHOULD)** — `kwisatz state [TARGET]` renders it; `--json` returns the array.
  Rationale: today there is no answer to "did we ever install this, and with what version?".

### 6.10 `kwisatz install`, `init`, `upgrade`, `uninstall`

- **R-INS-001 (MUST)** — `kwisatz install` makes `kwisatz` available on `PATH` for the invoking
  user and does nothing else to the machine: install `uv` if missing (pinned official installer),
  create the project venv (`uv sync`), place `~/.local/bin/kwisatz`, write
  `${XDG_CONFIG_HOME:-~/.config}/kwisatz/config.json` pointing at the resolved repo.
- **R-INS-002 (MUST)** — `kwisatz install` must be idempotent and re-runnable after a partial
  failure, and must not require the repo to be already configured.
- **R-INS-003 (MUST)** — Repo resolution order: `--repo` → `$KWISATZ_REPO` → nearest ancestor of
  `$PWD` containing `deploy.py` **and** `tasks/` → the path in `config.json`. Failing all four:
  error `4` with the exact `kwisatz install --repo <path>` / `git clone` command to fix it.
- **R-INS-004 (MUST)** — `kwisatz init` = interactive-light bootstrap: ensure `machine-config.yml`
  exists (copy `machine-config.yml.example`, or `--from-example inference` →
  `machine-config-inference.yml.example`), copy `models.yml.default` → `models.yml` **only if the
  user asks**, run `kwisatz doctor`, print the 3 next commands. Never enables more services than the
  example enables.
- **R-INS-005 (SHOULD)** — `kwisatz upgrade` = `git -C <repo> pull --ff-only` + `uv sync`, refusing
  when the checkout is dirty, and always stating the from→to git SHA.
- **R-INS-006 (SHOULD)** — `kwisatz uninstall` removes the launcher and CLI state only, prints what
  it will *not* remove (services, `/srv` data, systemd units), and requires `--yes`.

### 6.11 `kwisatz commands`

- **R-CMD-100 (MUST)** — Emits the CLI's own command/flag/exit-code table as JSON. This is what
  lets an agent discover the tool without reading `README.md`: no hidden verbs, no undocumented
  flags. `--json` is the only meaningful flag.

---

## 7. Output and UX requirements

- **R-OUT-001 (MUST)** — Structured levels: `error` (red), `warning` (yellow), `note/info` (cyan),
  `action` (bold, `→ running setup-docker`), `ok` (green), with a fixed prefix so
  `grep`-ability survives. Colour only when stdout is a TTY, or forced by `--color`/`NO_COLOR`.
- **R-OUT-002 (MUST)** — Progress goes to **stderr**; the result line(s) go to **stdout**.
  `kwisatz apply traefik | tee x` gets the result, not the spinner.
- **R-OUT-003 (MUST)** — `--quiet` prints exactly one line on success (the target name and outcome)
  and normal error text on failure. `--json` implies `--quiet` for stderr chatter.
- **R-OUT-004 (SHOULD)** — Task scripts keep their colourful bash output; the CLI must not
  re-format or indent their stdout (their exit-code semantics and messages are the documented
  contract per `conventions.md` § Output and Logging).
  One documented consequence of R-ARCH-101: the script's output arrives through pyinfra's `-vvv`
  report, which pyinfra writes to **stderr**, so `kwisatz apply x > f` captures the plan and the
  summary while the script's own output lands in `f` only if stderr is redirected too — the same
  behaviour `run-setup.sh apply` has always had. What the CLI guarantees instead is that the full
  output is on disk in the per-target `log_path`, and that `kwisatz logs <target>` reads it.
  `--interactive` (and `kwisatz run`) is the path where the script's stdout is stdout.
- **R-OUT-005 (SHOULD)** — A 3-second minimum cadence "still working" heartbeat for steps without
  output (builds, model downloads), including elapsed time and the PID, so a supervising agent can
  distinguish slow from hung.
- **R-OUT-006 (MUST)** — Every error message: (1) what failed, (2) the exact file/key that caused
  it, (3) at least one executable next command. No bare tracebacks, no `exit 1` in silence.
- **R-OUT-007 (SHOULD)** — End-of-apply summary table: target · outcome (`applied` / `skipped` /
  `failed` / `needs-attention`) · duration · next-step hint. The "converge or re-create" branch
  from `conventions.md` must land in `needs-attention` with the printed command.

---

## 8. Machine-readable contract (agents)

This section is normative for any agent integration.

### 8.1 Transport

- **R-JSON-001 (MUST)** — `--json` produces **exactly one** JSON document on stdout, printed at
  exit. Progress goes to stderr. Nothing else may reach stdout (no spinner, no `-->` warnings).
  The one exception is `kwisatz run`, whose stdout is the script's stdout (§9 note).
- **R-JSON-002 (MUST)** — `schema_version` (integer, currently `1`) is present in every document.
  Additive changes only within a major version; removals require a version bump and a note in
  `docs/releases/`.
- **R-JSON-003 (SHOULD)** — `--events` (MAY, M2) emits NDJSON progress lines `{"type":"step",…}` to
  stdout for long-running commands, terminated by the final document.

### 8.2 Envelope

```json
{
  "schema_version": 1,
  "command": "apply",
  "ok": false,
  "exit_code": 1,
  "started_at": "2026-10-21T13:04:11Z",
  "duration_ms": 918734,
  "repo": {"path": "/srv/kwisatz", "git_sha": "1bf8523", "branch": "develop"},
  "config": {"path": "/srv/kwisatz/machine-config.yml", "version": 1},
  "result": {
    "plan": 12, "ran": 3, "ok": 2, "skipped": 9,
    "items": [
      {"target": "setup-basics", "index": 1, "status": "applied",
       "exit_code": 0, "duration_ms": 41021, "command": "bash tasks/setup-basics.sh </dev/null",
       "env": {"NVM_VERSION": "0.40.4"},
       "stdout_tail": ["..."], "log_path": "logs/kwisatz-2026-10-21T130411-setup-basics.log"}
    ]
  },
  "warnings": ["setup-unsloth: `enabled: yes` is not a YAML boolean; the script is skipped"],
  "errors": [{"target": "setup-traefik", "exit_code": 1,
              "message": "traefik stack did not come up", "hint": "kwisatz logs traefik"}]
}
```

### 8.3 Field rules

- **R-JSON-010 (MUST)** — `status` per item ∈ `applied | skipped | failed | blocked |
  needs-attention | not-run`. `blocked` = a §6.5 prerequisite was missing; `needs-attention` =
  converged-but-diverged (the `conventions.md` cases).
- **R-JSON-011 (MUST)** — `stdout_tail` is capped (default 40 lines / 16 KiB) and full output lives
  in `log_path`; the document must stay under 256 KiB so an agent's context window is not
  destroyed.
- **R-JSON-012 (MUST)** — Env values are masked in every JSON field (`"TRAEFIK_SECRET": "***"`)
  except when `--reveal` is passed explicitly, which additionally prints a warning.

### 8.4 Masking

- **R-JSON-013 (MUST)** — The plan echo masks configured `env:` values exactly as pyinfra does
  today (`export KEY=*MASKED*`), so "treat `machine-config.yml` as secret-free" stays true in
  practice. `args:` are never masked (they are not secrets) — the divergence is documented, not
  accidental.

### 8.5 Agent-facing behaviour

- **R-AGE-001 (MUST)** — With `--json` the CLI never prompts and never waits for input; anything
  that would prompt exits `6` with `{"hint": "rerun with --interactive"}`.
- **R-AGE-002 (MUST)** — Long-running commands must not outlive `--timeout` (default 3600 s); on
  timeout the process group is killed, exit `5`, `message: "timed out after <n>s"`.
- **R-AGE-003 (SHOULD)** — `kwisatz info <t> --json` includes `help_excerpt` (the script's `--help`)
  so the agent needs exactly one round trip per unknown target.
- **R-AGE-004 (SHOULD)** — Add a `docs/features/kwisatz-cli-for-agents.md` cheat-sheet (or the
  `commands --json` dump) to `skills/kwisatz-assistant/SKILL.md` so the in-repo assistant tells
  agents to use the CLI instead of `bash tasks/*.sh`.

---

## 9. Exit codes

Stable, documented, asserted in tests. Agents branch on these, not on message text.

| Code | Name | Meaning |
|---|---|---|
| 0 | `OK` | success, including no-op / already-converged |
| 1 | `TASK_FAILED` | a task script exited non-zero |
| 2 | `USAGE` | bad flag, bad command, ambiguous target, mutually exclusive flags |
| 3 | `CONFIG` | config missing/unparsable/malformed entry, unknown target key |
| 4 | `PREREQUISITE` | uv/sudo/docker/OS/TTY requirement not met |
| 5 | `HEALTH` | run completed but health verification failed, or timed out |
| 6 | `INTERACTIVE_REQUIRED` | the step needs a human/`--interactive` |
| 7 | `NEEDS_ATTENTION` | converged-impossible; operator action required (diverged keys) |
| 8 | `PARTIAL` | `--keep-going` run finished with ≥ 1 failure |
| 9 | `LOCKED` | another kwisatz run holds the lock (`--lock-timeout` expired) |

- **R-EXIT-001 (MUST)** — `run` forwards the *script's* exit code, but maps the documented task
  codes (`0`/`1`/`2`) onto this table so callers do not learn a per-script alphabet. A task's `2`
  (its own "pre-flight/mutation failed") surfaces as `1` with `script_exit_code: 2`.
- **R-EXIT-002 (MUST)** — `kwisatz --version` and `… --help` exit `0`.
- **R-EXIT-003 (MUST)** — Exit codes are in the `commands --json` output and in the README.
- **Reserved in v1** — nothing returns `6` or `7` today: a missing terminal is
  `PREREQUISITE` (4), and a converge that cannot converge reports `TASK_FAILED` (1). They stay in
  this table and in `commands --json` because the numbering is a compatibility promise, and their
  description says *reserved* so an agent can see that branching on them is dead code. Shipping
  them means the CLI raising a prompt of its own (`6`) and A4's re-create-command branch (`7`) —
  both recorded as deferred in `docs/research/2026-10-22-kwisatz-cli-review.md` §6.

---

## 10. Safety, concurrency, idempotency

- **R-SAFE-001 (MUST)** — One writer per repo: a lock file `<repo>/.kwisatz/lock` (PID + start
  time, stale after the owner dies). A second concurrent run exits `9` unless
  `--lock-timeout <s>` is given. This is the requirement that stops two agents from applying the
  same stack twice at once.
- **R-SAFE-002 (MUST)** — Nothing may run before the plan is validated; `--dry-run` validates the
  whole plan and mutates nothing.
- **R-SAFE-003 (MUST)** — The CLI mutates the host **only** by executing task scripts. It never
  runs `apt`, `docker`, `systemctl`, or writes `/srv` itself, so `tasks/` stays the single
  implementation surface (`conventions.md` — idempotency lives in the scripts).
- **R-SAFE-004 (MUST)** — No `--force-*` flag that does something the underlying script does not
  do. `kwisatz apply x --force` is a documented forwarding of the script's own `--force`
  (28 of the 58 task scripts implement it), never an invented tear-down.
- **R-SAFE-005 (SHOULD)** — Before a full apply, warn when `machine-config.yml` changed since the
  last apply record and show the diff of keys.
- **R-SAFE-006 (SHOULD)** — `sudo` warm-up: for a run of > 1 target, call `sudo -v` once and keep
  the ticket alive, so a 20-minute apply does not die on an expired credential in script 14.
  `--no-sudo-warmup` disables.
- **R-SAFE-007 (MUST)** — Logs and state files under `logs/` and `.kwisatz/` (both gitignored) get
  mode `0600` / dir `0700`.

---

## 11. Architecture and implementation notes

### 11.1 Language and packaging

- **R-ARCH-001 (MUST)** — Python ≥ 3.10 (matches `requires-python`), `argparse` (or Typer if the
  maintainer prefers — but the repo already hand-rolls argparse in `sync_models/cli.py`, so
  consistency argues for argparse), typed, `from __future__ import annotations`.
- **R-ARCH-002 (MUST)** — New package `kwisatz/` in the repo root, with a console-script entry
  point in `pyproject.toml`:

  ```toml
  [project]
  name = "kwisatz"
  dependencies = ["pyinfra>=3.10,<4", "pyyaml", "ruamel.yaml>=0.18"]

  [project.scripts]
  kwisatz = "kwisatz.cli:main"

  [tool.hatch.build.targets.wheel]
  packages = ["kwisatz"]
  ```

  Packaging must exclude `tasks/`, `templates/`, `lib/` from the wheel — the CLI *operates on a
  checkout*, it does not ship one.
- **R-ARCH-003 (MUST)** — `./kwisatz` executable shim at the repo root so `./kwisatz apply traefik`
  works from a checkout with zero install (`uv run` under the hood when a venv is present).
- **R-ARCH-004 (SHOULD)** — `uvx kwisatz` / `uv tool install --from <repo> kwisatz` must work;
  document both in the README's Quick Start.

### 11.2 Module layout

```text
kwisatz/
  __init__.py        __version__
  cli.py           argument parsing, command dispatch, exit codes
  repo.py          repo/config/lock resolution (§6.10 R-INS-003)
  config.py        read + round-trip write of machine-config.yml (ruamel)
  plan.py          target resolution, ordering, plan construction
  exec.py          subprocess runner: env contract, stdin, timeout, log capture
  checks.py        doctor checks, prerequisites table, health probes
  output.py        levels/colour/heartbeat/tables
  jsonio.py        envelope, masking, schema_version
  state.py         apply history
  data/
    prerequisites.yml   ordering + host-fact table (§6.5)
    services.yml        service→manager/port hints (§6.7), generated where possible
tests/unit/        pytest (uv run pytest)
```

### 11.3 Parity: the shared module (the crux)

- **R-ARCH-100 (MUST)** — The config-reading, `enabled` evaluation, script resolution, env
  construction, and command construction logic move out of `deploy.py` into
  `kwisatz/orchestrator.py`. `deploy.py` becomes a thin pyinfra adapter that calls it, and keeps
  its `--dry`/`-y -vvv`/`--data config=` behaviour byte-for-byte.
- **R-ARCH-101 (MUST, decided 2026-10-22)** — `kwisatz apply` runs its targets **through
  `deploy.py`**: one pyinfra deploy per resolved target
  (`<pyinfra> @local <repo>/deploy.py -y -vvv --data config=<file> --data select=<name>`), so the
  command, the environment, the `/dev/null` stdin and the masking are pyinfra's, exactly as in
  `run-setup.sh apply`. The CLI never `exec`s a task script itself, and it needs pyinfra to run
  (`repo.py:pyinfra_command()` → the current interpreter, the checkout venv, `uv`, or exit `4`).
  Two consequences are intentional: pyinfra is a run-time prerequisite, and `--interactive` is the
  only apply path that stays a direct script run, because a deploy cannot attach a TTY
  (R-APP-013). `kwisatz run` (R-CMD-004) is the other sanctioned direct path.
- **R-ARCH-102 (MUST)** — A conformance test asserts that for a fixture config the CLI path and
  the pyinfra path emit the identical `(command, env, stdin)` triple for every enabled script,
  including `/dev/null` stdin, `INTERACTIVE=false`, `HiddenValue`/masking of `env:` values in the
  echoed plan, the venv `PATH` stripping, and `sys.executable` for `.py` tasks. It is a
  one-engine test now: the evidence is what the *task script* records — its argv, its environment,
  and the ancestor chain that started it — so a change that quietly runs the script itself fails.
- **R-ARCH-103 (MUST)** — `run-setup.sh` is a deprecated shim: it prints one DEPRECATED line,
  translates `apply`/`status` and `--data config=<file>` into the CLI's `apply`/`status`/`--config`,
  and execs `./kwisatz`. Delete it one release after deprecation; until then it keeps old docs, CI
  jobs and muscle memory working. The exit-code change that follows from it is documented: `status`
  on an unparsable config exits `3` (CONFIG, §9) where pyinfra exited `1`.
- **R-ARCH-104 (SHOULD)** — Deprecate, but do not delete, the "run the script by hand" advice:
  every README sentence that tells the user to `INTERACTIVE=true tasks/…` gets a `kwisatz
  apply <t> --interactive` companion.

### 11.4 Config round-trip

- **R-ARCH-200 (MUST)** — `ruamel.yaml` with `preserve_quotes=True`, `indent=2`, sequence
  style kept, and comments intact. Test: golden-file fixture with 15+ comments; after `enable`,
  `disable`, `set`, the diff is exactly the intended lines.
- **R-ARCH-201 (MUST)** — `version:` key and the file's leading comment block are never reordered.
- **R-ARCH-202 (SHOULD)** — `.kwisatz/config-backups/machine-config.yml.<utc-ts>` keeps the last
  5 copies (the file is gitignored, so it has no other history).

### 11.5 Compatibility matrix

| Surface | Requirement |
|---|---|
| `run-setup.sh apply/status` | deprecated shim for one release, then deleted; it exits with the CLI's codes (§9), so `status` on a broken config exits `3`, not `1` |
| `deploy.py` CLI flags | unchanged (`--dry`, `-y -vvv`, `--data config=`); `--data select=` and `--data env={…}` added, both additive |
| `machine-config.yml` format | v1 format, additive optional keys only (`requires:`, `group:`) |
| `tasks/*.sh` scripts | unchanged; no new flag requirement |
| `tests/run-vm-tests.sh` | unchanged entrypoint and options, plus `--mode cli|script`; **default `cli`**, so the suite drives `kwisatz apply <target>` |
| `machine-config.test.yml` | unchanged |
| Existing docs | updated, not rewritten |

---

## 12. Testing and acceptance criteria

### 12.1 Test layers

1. **Unit (pytest, fast, no root).** Target resolution, ambiguity, `enabled` spellings, plan
   ordering, masking, envelope schema, exit-code mapping, lock file, round-trip config edits.
   **R-TEST-001 (MUST)** — 100 % of `plan.py`, `config.py`, `jsonio.py`, `exec.py` public functions.
2. **Conformance (R-ARCH-102).** Fixture config; assert CLI-vs-pyinfra triple equality, and that
   the task script's own ancestor chain proves the run came out of `deploy.py`.
   **R-TEST-002 (MUST).**
3. **CLI integration (`pytest` + a tmp repo fixture).** Real subprocess runs of a fake
   `tasks/stub-*.sh` that records its argv/env/stdin into a file, so the contract is asserted, not
   assumed.
   **R-TEST-003 (MUST)** — covers: full apply ordering, single-target apply, unconfigured target,
   `--dry-run` writes nothing, `--json` is one parseable document, exit codes for §9, lock
   contention.
4. **VM suite.** `tests/run-vm-tests.sh --mode cli` — the default — runs every phase (precheck
   via `kwisatz status`, integration, idempotency) through `./kwisatz apply <target>`, so the
   command operators and agents actually use is what the release tests exercise. `--mode script`
   keeps the pre-CLI path as the documented fallback. **R-TEST-004 (MUST).**
5. **Lint.** `ruff check` on `kwisatz/` and `deploy.py`; `yamllint` on the generated
   config fixtures. Per `AGENTS.md` § Linting. **R-TEST-005 (MUST).**

### 12.2 Acceptance criteria (v1 = M1 + M2)

| # | Given | When | Then |
|---|---|---|---|
| A1 | fresh Ubuntu 24.04, repo cloned | `./kwisatz install && kwisatz init` | `machine-config.yml` exists, `kwisatz` on PATH, doctor exit 0/4 stated |
| A2 | config with 3 enabled scripts | `kwisatz apply` | 3 scripts in config order, exit 0, summary table, state records written |
| A3 | `setup-docker` disabled in config | `kwisatz apply docker` | docker installed, config **unchanged**, one warning about "not enabled" |
| A4 | traefik stack running | `kwisatz apply traefik` | converges, exit 0; if keys diverged: exit `7` + exact re-create command — **not shipped in v1** (7 is reserved, see §9); a diverged stack fails as `1` |
| A5 | typo | `kwisatz apply traefiks` | exit 3, closest candidates listed |
| A6 | two kwisatz shells | concurrent `apply` | second exits `9`, or waits for `--lock-timeout` |
| A7 | agent shell, non-TTY | `kwisatz services --json` | one document, valid `schema_version`, no prompt, exit 0 |
| A8 | config with 20 comments | `kwisatz config enable traefik` | exactly the `enabled:` line changes, comments byte-identical |
| A9 | same fixture config | CLI plan vs `run-setup.sh status` | same commands, same order, same masked env |
| A10 | `tasks/setup-unsloth.sh` not in config | `kwisatz apply unsloth` | runs with defaults + warning + `config enable` hint |
| A11 | `vllm` requires GPU absent | `kwisatz apply vllm` | warning (R-ORD-002) or exit `4` when the check is hard; documented per check |
| A12 | task script prints secrets in its own output | `--json` apply | `stdout_tail` may contain them; **documented** in README as the operator's caveat, and `--redact-stdout` (MAY) filters `KEY=` patterns |

---

## 13. Documentation deliverables

- **R-DOC-001 (MUST)** — This file (`docs/features/kwisatz-cli-specification.md`).
- **R-DOC-002 (MUST)** — `README.md`: new "Using the `kwisatz` CLI" section before
  "Running the Orchestrator", plus a "single service" example in Quick Start; keep the existing
  pyinfra section as "under the hood".
- **R-DOC-003 (MUST)** — `specification/project/architecture.md`: add the CLI to the system
  structure diagram and the entrypoint table (the diagram currently claims `run-setup.sh` is
  *the* entrypoint).
- **R-DOC-004 (SHOULD)** — `specification/features/kwisatz-cli/` (behaviors + exit codes) so the
  spec lives where the repo's other per-feature specs live.
- **R-DOC-005 (MUST)** — `skills/kwisatz-assistant/SKILL.md`: replace the
  "run `./tasks/<name>.sh` directly" guidance with the CLI equivalents, and add the `--json`
  command recipes for agents.
- **R-DOC-006 (SHOULD)** — `AUTOMATIONS.md` header: add "or `kwisatz apply <name>`; `kwisatz info
  <name>` for flags".
- **R-DOC-007 (MUST)** — `docs/releases/<vX.Y.Z>.md` entry; new CLI = MINOR per `AGENTS.md`.

---

## 14. Milestones

### M1 — "one command" (the release everyone feels)

`install`, `init`, `apply` (full + single + multi), `status`, `list`, `info`, `doctor`,
`commands`, global flags, `--json`, exit codes, lock, shared orchestrator module, conformance
test, unit tests.
**Done when:** A1–A5, A9, and R-ARCH-102 pass, and no README text is wrong.

### M2 — "the machine answers questions"

`config` subcommands (round-trip), `services`, `logs`, `state`, `models`, `run`, `--keep-going`,
`--events`, the VM suite's `--mode cli` (its default), docs refresh (R-DOC-002/004/005/006).
**Done when:** A6–A8, A10–A11 pass and `kwisatz services --json` is trusted by agents.

### M3 — polish

`completions`, `upgrade`, `uninstall`, `doctor --fix`, `requires:` keys, `config enable
--with-deps`, `--redact-stdout`, group selection.
**Done when:** every remaining MAY is either shipped or recorded here as explicitly dropped.

---

## 15. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Two execution paths drift (CLI direct-exec vs pyinfra) | installs silently differ from a full apply | §11.3 shared module + conformance test as release gate |
| `ruamel.yaml` rewrites a config in a way that loses a warning comment | operator loses an ordering warning, potential lockout | golden-file round-trip test; `config validate` runs after every write |
| Agent runs `apply <target>` with `env:` unset and builds the wrong thing | wasted 30-min builds, half-configured service | `info`/`status` show env keys before running; R-APP-011 keeps config env in the single-target path |
| Scope creep: CLI starts implementing fixes | `tasks/` is no longer the implementation surface | R-SAFE-003 is a hard rule, review-gate |
| pyinfra's stdout format changes on a bump | plan echo/masking diverges | conformance test pins the triple, not the text |
| `--json` output used by external scripts | breaking change | `schema_version`, additive-only rule, changelog entry |

---

## 16. Open questions

1. **Single-target via pyinfra or direct exec?** *Resolved 2026-10-22: pyinfra.* `apply` runs each
   target as a deploy of the checkout (`deploy.py --data select=<name>`), because staying on the
   pyinfra framework outweighs the ~1 s startup per target and the < 200 ms single-target start.
   Direct exec survives only for `--interactive` and `kwisatz run`.
2. **`run-setup.sh`** — *Resolved 2026-10-22: shim, then delete.* The CLI is the documented
   entrypoint (§11.3 R-ARCH-103); the wrapper lives one release longer for old docs and CI jobs.
3. Should `kwisatz list --group` parse `AUTOMATIONS.md` (single source of truth, prose-shaped) or
   should the grouping move into a data file the docs generate?
4. Is `.kwisatz/` (repo-local) or `${XDG_STATE_HOME}/kwisatz/` (per-user, survives repo moves) the
   home for state and logs? `logs/` is already repo-local and gitignored — consistency argues for
   the repo.
5. Do we want `kwisatz apply --all-disabled` / `--tag` group selection in M1, or is
   `config enable` the right answer?
6. `machine-config.yml` is gitignored on the target box: is a config *diff since last apply*
   (R-SAFE-005) worth the extra state, or does `state.json` record a config hash and that's enough?

---

## 17. Appendix A — reference transcript

```console
$ kwisatz
kwisatz 1.1.0-dev · repo /home/dev/kwisatz (develop, 1bf8523)
config  /home/dev/kwisatz/machine-config.yml · 12 of 60 known targets enabled

  kwisatz apply [TARGET…]      install/update everything enabled, or one target
  kwisatz status               show the plan without running it
  kwisatz list                 every known target
  kwisatz info traefik         how one target works, incl. its env keys
  kwisatz config enable traefik  flip one flag, comments preserved
  kwisatz services             what is running
  kwisatz doctor               is this box ready
  kwisatz commands --json      the whole CLI, as data

Next: kwisatz status   then   kwisatz apply

$ kwisatz apply traefik
→ resolving traefik … setup-traefik (machine-config.yml, enabled: false → running anyway)
--> note: 'setup-traefik' is disabled in machine-config.yml; enabling it would keep
          it in a full `kwisatz apply`:  kwisatz config enable setup-traefik
→ running setup-traefik
[ … script's own colourful output … ]
✓ setup-traefik · 41 s · stack healthy (2/2 containers)

Summary
  setup-traefik   applied   41 s
→ next: kwisatz services   ·   kwisatz logs traefik

$ kwisatz services --json | jq '.result.items[] | {name, state, ports}'
{"name":"traefik","state":"running","ports":[80,443,8080]}
{"name":"llama-swap","state":"unhealthy","ports":[9292]}
```

## Appendix B — command → requirement traceability

| Command | Requirements |
|---|---|
| `install` | R-INS-001..003, R-ARCH-004 |
| `init` | R-INS-004 |
| `apply` | R-APP-001..004, R-APP-010..014, R-APP-020..022, R-APP-030..031, R-TGT-001..002, R-ORD-001..002, R-SAFE-001..007, R-ARCH-101..102 |
| `status` | R-STA-001..004 |
| `list` / `info` | R-DSC-001..004 |
| `config` | R-CFG-001..007, R-ARCH-200..202 |
| `services` / `doctor` / `logs` | R-OPS-001..005 |
| `models` | R-MOD-001..002 |
| `state` | R-STA-100..101 |
| `commands` | R-CMD-100 |
| all | R-CMD-001..004, R-OUT-001..007, R-JSON-001..013, R-AGE-001..004, R-EXIT-001..003 |
