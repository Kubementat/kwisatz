# Behaviors — `kwisatz` CLI

> Requirements: `docs/features/kwisatz-cli-specification.md` (the "why" and the MUST/SHOULD
> rules). This file is the *observable* half: what a command prints, returns, and touches,
> so a bug report can be settled without reading `src/`.
>
> Engine note: `kwisatz apply` runs `deploy.py`, one pyinfra deploy per target
> (`--data select=<name>`). What the task script then receives is byte-for-byte what
> `run-setup.sh apply` / `deploy.py` would give it, because it *is* `deploy.py` — enforced by
> `tests/unit/test_conformance.py` and `tests/unit/test_deploy_engine.py`. The direct script
> run survives only for `--interactive` and `kwisatz run` (R-ARCH-101).

## Overview

`kwisatz` is a front end over the orchestrator that already installs the machine. It changes
the interface, never the implementation: the task scripts under `tasks/` remain the only
thing that mutates the box (R-SAFE-003), and `apply` reaches them through `deploy.py`, the same
pyinfra deploy `run-setup.sh` used.

Two things make it useful rather than merely convenient:

1. **One target, one command.** `kwisatz apply traefik` runs exactly what a full apply would
   have run for traefik — same `argv`, same `env`, same `args` — without editing
   `machine-config.yml` and without running the eleven other enabled scripts.
2. **One answer format.** Every command speaks `--json`: a single document on stdout, a
   stable exit code, and `kwisatz commands --json` as the discovery surface, so an agent
   never needs `README.md` or `AUTOMATIONS.md` to do its job.

## Behavior 1 — resolution

A target is anything the operator can point at. Resolution is *prefix-tolerant* because the
scripts follow `setup-<component>.sh` / `configure-<component>.sh`:

| input | resolves to |
|---|---|
| `traefik`, `setup-traefik` | config key `setup-traefik` |
| `unsloth`, `setup-unsloth` (no config key) | `tasks/setup-unsloth.sh`, run with script defaults |
| `stub-ax` | exit `3`, with the closest names from the catalog |
| `zzzzz` | exit `3`, and **no** `closest:` line — five edits from every name is not a typo |
| `docker` when both `setup-docker.sh` and `configure-docker.sh` exist | exit `2`, both names printed |

`.sh` beats a `.py` of the same name (a `.py` next to a `.sh` is its helper, not a second
entry point) and says so.

The `did you mean` list is distance-gated (R-CMD-002): at most two edits from what was typed,
measured against the stored name *or* its prefix-free spelling, for commands and targets alike.
`plan.similar()` owns that gate, so no caller can reimplement it differently.

Resolution is not only `apply`'s: `info`, `run` and `config enable|disable|set|args` already
routed the typed name through `planner.resolve_target`, and `state [TARGET]` and `logs [TARGET]`
now do the same. A typo is therefore exit `3` with `closest:` wherever a name is typed, and the
prefix-free spelling (`traefik` for `setup-traefik`) reads the same history and the same logs.
Two commands answered from the raw string, so they could not tell "not one of ours" from "ran,
produced nothing":

- `kwisatz state <typo>` was exit `0` with `count: 0` — byte-for-byte what a *known* target that
  never ran answers, so "did we ever install this?" could only be answered by guessing. The
  history of a known target, including one with no records yet, still answers `0`, and
  `kwisatz state` with no argument is unchanged (every record).
- `kwisatz logs <typo>` printed `no logs for '<typo>': no stack, no unit, no apply log`, the same
  bytes a valid target that logged nothing prints. The name is resolved before the source is
  chosen, so the typo is the exit `3` + `closest:` every other command gives; a valid target with
  no stack, no unit and no apply log keeps that sentence and exit `3`, and `kwisatz logs` with no
  argument keeps exit `2`.

## Behavior 2 — apply

`kwisatz apply` takes every enabled entry, in config order. `kwisatz apply a b c` takes those
targets, configured ones in config order, the rest in the order given. Per target:

```
[2/14] setup-traefik — Reverse proxy
→ running setup-traefik
   <the script's own stdout, unchanged, streamed>
✓ setup-traefik · 41 s
```

- each target is one pyinfra deploy of the checkout, so the command, the `env`, the `args`
  and the `/dev/null` stdin are `deploy.py`'s. pyinfra reports that deploy on **stderr**
  (`-vvv`), which is what `run-setup.sh apply` always did — and that is why the log copy keeps
  *both* streams of the child: `logs/kwisatz-<UTC-ts>-<target>.log` (mode `0600`, directory
  `0700`) is what `kwisatz logs <target>` reads after an exit `1`, and it would have nothing
  to say if only stdout were copied. What reaches your terminal is not crossed over: stdout on
  stdout, stderr on stderr (R-OUT-002). Use `--interactive` (or `kwisatz run`) when you want
  the script's stdout attached to your terminal.
- a script idle for >3 s gets `… setup-traefik still running 132s · pid 4242` on stderr, so
  slow is distinguishable from hung.
- first failure stops the run and exit is `1`; `--keep-going` runs the rest and exits `8`.
- `--timeout` kills the process group and the run exits `5` (`HEALTH`, R-AGE-002), **not** `1`:
  a stack that hung is not a script that failed, and retrying it as one costs the same twenty
  minutes again. The per-item `status` is `failed` either way, and `state.jsonl` records the
  verdict the run got. `--keep-going` keeps `8`, because that is what that flag promises.
- the budget is the **command's**, shared in config order: two 40 s targets under `--timeout 50`
  get 40 s and 10 s, and the second one never starts when the deadline is already spent. It is
  then `not-run` (not `failed`, so the document's counts stay honest) and the run exits `5` even
  with `--keep-going` — that flag says *it finished*, and a run the deadline stopped did not.
- a target the §6.5 table says needs sudo is stopped **before** the first script runs, with exit
  `4`, when `sudo -n true` fails: the deploy gives its scripts `/dev/null` stdin, so `sudo` there
  answers `getpass`, dies with `termios.error` → `EOFError` inside gevent, and leaves behind exit
  `1` plus a "retry this one target" hint for a box that can never do it. A cached `sudo -v`
  ticket makes the same probe pass. `--interactive` is exempt — answering the prompt is the point
  of that flag — and a target the table does not mention is a warning, not a stop.
- after the run, one line is appended to `.kwisatz/state.jsonl` with the per-target outcomes,
  the repo SHA, and the config's sha + enabled map.
- nothing is written before the scripts have exited, so a crashed run cannot look like a
  success.

## Behavior 3 — the environment of a task

One engine, one contract: `kwisatz.orchestrator` builds it, `deploy.py` applies it. Asserted
against what a *stub script* records rather than what the CLI claims:

| fact | value |
|---|---|
| stdin | `/dev/null` (the CLI's own stdin with `--interactive`) |
| `INTERACTIVE` | `false`, unless the entry's `env:` or `--env` says otherwise |
| config `env:` | applied in full, after `INTERACTIVE`, then `--env` overrides |
| project venv | stripped from `PATH`; `VIRTUAL_ENV` removed |
| `.py` tasks | run under `sys.executable`, so they see the project venv |
| echo of the command | `export INTERACTIVE=false 'SECRET=*MASKED*' && bash tasks/x.sh </dev/null` |

## Behavior 4 — config editing

`kwisatz config enable|disable|set|unset|args|validate|show|path|init` never invokes an
editor and never rewrites the file wholesale:

- the write is a `ruamel.yaml` round-trip: comments, key order, and quoting style survive,
  and enabling one target in a file with 20 comments changes **one line** (A8);
- write = temp file in the same directory, `chmod 0600`, `os.replace`, with the previous file
  copied to `.kwisatz/config-backups/machine-config.yml.<utc-ts>` (5 kept);
- the edit is validated *after* writing with the runner's own checks and **rolled back** if
  it would leave a problem;
- `validate` reports every problem at once; `set` refuses `enabled`/`description`; a value
  that would read back as a bool or null is quoted.

## Behavior 5 — services and health

Discovery is by convention: `/srv/*/docker-compose.yml`, the
`com.docker.compose.project*` labels, and systemd units whose name matches a task. A stack
outside `/srv` (traefik commonly runs from `/opt/traefik`) is found through its labels.

The health verdict is the one `lib/helpers.sh:wait_for_healthy` computes, so the CLI and the
task scripts cannot disagree: `running` + `healthy`/`none` → `running`; `unhealthy` →
`unhealthy`; restarting → `restarting`; exited → `stopped`. A unit that does not exist is
judged by `LoadState`, never reported as stopped.

The verdict is on `state`, so the agent filter is `select(.state != "running")`; a container's
own probe is `containers[].health` (`healthy` / `unhealthy` / `none`), not a field on the item.

## Behavior 6 — machine-readable output

Exactly one document on stdout; progress, warnings and errors on stderr. Where the answer is
a list it is under `result.items` — `status`, `list`, `doctor`, `services`, `state` all spell it
that way, and `state` keeps `result.records` as well for anyone already reading it. `logs`
depends on what it found: `result.lines` for a stored apply log, `result.stdout_tail` for a
compose stack or a unit.

```json
{
  "schema_version": 1,
  "command": "apply",
  "ok": false,
  "exit_code": 1,
  "started_at": "2026-10-22T01:04:11Z",
  "duration_ms": 918734,
  "repo": {"path": "/srv/kwisatz", "git_sha": "1bf8523", "branch": "develop"},
  "config": {"path": "/srv/kwisatz/machine-config.yml"},
  "result": {"plan": 12, "ran": 3, "ok": 2, "failed": 1, "skipped": 9,
             "items": [{"target": "setup-basics", "index": 1, "status": "applied",
                        "exit_code": 0, "duration_ms": 41021, "command": "bash … </dev/null",
                        "env": {"NVM_VERSION": "***"}, "stdout_tail": ["…"],
                        "log_path": "logs/kwisatz-20261022T010411-setup-basics.log"}]},
  "warnings": ["setup-unsloth: `enabled: yes` is not a YAML boolean; the script is skipped"],
  "errors": [{"target": "setup-traefik", "exit_code": 1, "message": "…", "hint": "kwisatz logs traefik"}]
}
```

`status` ∈ `applied | skipped | failed | blocked | needs-attention | not-run`. Env values are
masked (`***`) unless `--reveal` is passed, which is itself announced. `--events` prefixes the
document with NDJSON step lines; `kwisatz run` is the documented exception whose stdout
belongs to the script. `run` writes the same per-target file `apply` does
(`logs/kwisatz-<ts>-<target>.log`) and reports it in `log_path`, so its own failure hint
(`kwisatz logs <target>`) has something to read — an escape hatch that leaves no trace makes
the next command a dead end.

## Behavior 7 — exit codes

| code | when | the next command |
|---|---|---|
| 0 | success, including "already converged" | `kwisatz services` |
| 1 | a task script exited non-zero | `kwisatz apply <t>` (retry one target) |
| 2 | bad flag/command, ambiguous target, `--json --interactive` | `kwisatz --help` |
| 3 | config missing/unparsable, unknown target | `kwisatz init` / `kwisatz list --all` |
| 4 | uv/sudo/docker/OS/TTY missing | `kwisatz doctor --json` |
| 5 | stack unhealthy, or `--timeout` killed the run | `kwisatz logs <t>` |
| 6 | a prompt is needed — **reserved, v1 never emits it** (a missing TTY is `4`) | `kwisatz apply <t> --interactive` |
| 7 | converge impossible (diverged keys) — **reserved, v1 never emits it** (a failed converge is `1`) | the printed command |
| 8 | `--keep-going` finished with ≥1 failure | `kwisatz status` |
| 9 | another run holds `<repo>/.kwisatz/lock` | `--lock-timeout 30` |

`kwisatz run` forwards the script's code, mapping its `2` to `1` and keeping it as
`script_exit_code` (R-EXIT-001). Its arguments are split by `--`: kwisatz's own flags belong
before the target, the script's after it (`kwisatz run traefik -- --force`). A script flag that
arrives without `--` is a usage error rather than something the CLI guesses, and `-n` there
prints the command and runs nothing (R-SAFE-002).

`kwisatz` with no command is the help — the same text `--help` prints, exit `0` — and
`kwisatz --json` on its own prints the command table as one document. A *wrong* command is still
the usage answer: exit `2`, with the closest name from the table (R-CMD-002).

Codes `6` and `7` are published by `commands --json` but are **reserved**: no v1 path returns
them, so branching on them is dead code today. The deferred work behind them is recorded in
`docs/research/2026-10-22-kwisatz-cli-review.md` §6 (raise a prompt = 6; A4's
converge-impossible re-create command = 7).

## Behavior 8 — concurrency

One writer per checkout: `<repo>/.kwisatz/lock` records the PID and the start time, and is
treated as stale when the owner is gone or the path names a different checkout. A file that
exists but names no owner (`flock`'s empty file, a truncated write after a crash, a touched
file) counts as held for one second and is then reclaimed — deleting it immediately would
clobber a run that is mid-creation, which is the one failure this class exists to prevent. A
second run exits `9` unless `--lock-timeout <s>` is given. Read-only commands never take the
lock.

## Behavior 9 — `doctor`'s verdicts

`doctor` is the command whose output *is* its answer, so its check lines go to stdout and stay
there under `-q` (`status`/`list`/`services` do the same; apply's step lines stay on stderr,
because stdout belongs to the task script). With `--json` the same facts are one flat list:

```bash
./kwisatz doctor --json | jq '.result.items[] | select(.ok|not) | {name, kind, hint}'
# kind ∈ prerequisite | port | service — the whole to-fix list in one read
```

A release outside the tested set (26.04, 27.04, …) is `required: false`: a warning, not exit 4.
Refusing a box that this repo's own VM suite boots would make the CLI's advice wrong on the
machine it ships on.

## Design decisions

1. **`src/kwisatz/` instead of a root-level package.** A root `kwisatz/` package and a root
   executable `./kwisatz` (R-ARCH-002/003) cannot coexist; the executable keeps the name the
   user types.
2. **`--json + --interactive` is a usage error**, not a compromise: an agent asking for data
   and prompts at once is a bug we want loud.
3. **`install` does not download uv behind your back.** `--with-uv <version>` runs the pinned
   official installer and only with `--yes`, because R-SAFE-003 forbids the CLI mutating the
   host outside a task script — installing a toolchain is a deliberate exception, not a
   default.
4. **`models sync --dry-run` prints the command instead of pretending.** `tasks/sync-models.py`
   has no dry-run flag; inventing one would be the sort of lie this CLI exists to prevent.
5. **State and logs stay repo-local** (`<repo>/.kwisatz`, `<repo>/logs`), consistent with the
   already-gitignored `logs/`.
6. **Service discovery is inferred, not registered.** No `services.yml` list of stacks; the
   data file carries manager/unit *hints* only, and a stale hint is worse than none.
7. **`apply` goes through `deploy.py`, not around it** (R-ARCH-101, decided 2026-10-22). The
   visible trade: pyinfra is a run-time prerequisite (`uv`, or the checkout's venv — otherwise
   exit `4`), a target costs ~1 s of deploy startup, and the script's output arrives on stderr.
   The gain: single-target and full-run apply cannot diverge, because they are the same deploy.
   `run-setup.sh` is a deprecated shim for one release, then it goes.

## Verification

- `tests/unit/test_plan.py` — resolution, ambiguity, ordering, the distance-gated `did you mean`,
  the prerequisite table.
- `tests/unit/test_config.py` — A8, atomic write, backups, quoting, validate.
- `tests/unit/test_exec.py` — recorded env, timeout kills the process group, log mode, that the
  log keeps the child's **stderr** and not only its stdout, and that pipe EOF arriving before
  the exit is not a failure.
- `tests/unit/test_services.py` — the health verdict, docker/systemd parsing, log dialects, and
  a modern engine that must still read as running.
- `tests/unit/test_checks.py` — what the host facts may and may not stop a run for.
- `tests/unit/test_state_lock.py` — history ordering, one-writer rule, the lock nobody owns.
- `tests/unit/test_conformance.py` — the CLI-vs-pyinfra `(command, env, stdin)` gate.
- `tests/unit/test_deploy_engine.py` — that a deploy ran the script (`--data select=`), that the
  script's own ancestor chain says so, and how the deploy interpreter is chosen.
- `tests/unit/test_cli.py` — acceptance criteria A2…A10 against real subprocesses, the exit
  code a `--timeout` run reports, that the budget is shared across the whole run and leaves the
  rest `not-run`, `logs <t>` after a failed apply, the `--` pass-through and
  `--dry-run` of `run`, that `state`/`logs` resolve their argument so a typo is exit `3` and not
  a zero or a plausible-looking "no logs", and stdout purity under `--json`.
- `tests/unit/test_cli_commands.py` — the four commands whose behaviour is only visible in a
  subprocess: `install` (its dry run writes nothing, a box without `uv` is `4`, `--with-uv` needs
  `--yes`), `models` (the catalog it reads, the catalog it cannot parse, sync's exit mapping),
  `info` (its document, `last_apply`, the ordering advisory), and `doctor`'s item list.

Coverage is opt-in and not a gate: `bash tests/coverage.sh` runs the unit suite with the
subprocesses measured (R-TEST-001 as amended, `docs/research/2026-10-23-kwisatz-cli-coverage.md`).
A plain `pytest --cov` measures only the parent and reports `cli.py` at 0 %, because that is where
the CLI actually runs.
