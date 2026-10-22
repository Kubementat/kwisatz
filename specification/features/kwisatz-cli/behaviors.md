# Behaviors — `kwisatz` CLI

> Requirements: `docs/features/kwisatz-cli-specification.md` (the "why" and the MUST/SHOULD
> rules). This file is the *observable* half: what a command prints, returns, and touches,
> so a bug report can be settled without reading `src/`.
>
> Parity note: everything below describes the direct-execution path. `run-setup.sh apply` /
> `deploy.py` must hand every script the identical `(command, env, stdin)` triple — enforced
> by `tests/unit/test_conformance.py`.

## Overview

`kwisatz` is a front end over the orchestrator that already installs the machine. It changes
the interface, never the implementation: the task scripts under `tasks/` remain the only
thing that mutates the box (R-SAFE-003).

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
| `docker` when both `setup-docker.sh` and `configure-docker.sh` exist | exit `2`, both names printed |

`.sh` beats a `.py` of the same name (a `.py` next to a `.sh` is its helper, not a second
entry point) and says so.

## Behavior 2 — apply

`kwisatz apply` takes every enabled entry, in config order. `kwisatz apply a b c` takes those
targets, configured ones in config order, the rest in the order given. Per target:

```
[2/14] setup-traefik — Reverse proxy
→ running setup-traefik
   <the script's own stdout, unchanged, streamed>
✓ setup-traefik · 41 s
```

- stdout is passed through, not reformatted, and copied to
  `logs/kwisatz-<UTC-ts>-<target>.log` (mode `0600`, directory `0700`).
- a script idle for >3 s gets `… setup-traefik still running 132s · pid 4242` on stderr, so
  slow is distinguishable from hung.
- first failure stops the run and exit is `1`; `--keep-going` runs the rest and exits `8`.
- after the run, one line is appended to `.kwisatz/state.jsonl` with the per-target outcomes,
  the repo SHA, and the config's sha + enabled map.
- nothing is written before the scripts have exited, so a crashed run cannot look like a
  success.

## Behavior 3 — the environment of a task

Identical in both paths, and asserted against what a *stub script* records rather than what
the CLI claims:

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

## Behavior 6 — machine-readable output

Exactly one document on stdout; progress, warnings and errors on stderr.

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
belongs to the script.

## Behavior 7 — exit codes

| code | when | the next command |
|---|---|---|
| 0 | success, including "already converged" | `kwisatz services` |
| 1 | a task script exited non-zero | `kwisatz apply <t>` (retry one target) |
| 2 | bad flag/command, ambiguous target, `--json --interactive` | `kwisatz --help` |
| 3 | config missing/unparsable, unknown target | `kwisatz init` / `kwisatz list --all` |
| 4 | uv/sudo/docker/OS/TTY missing | `kwisatz doctor --json` |
| 5 | stack unhealthy or run timed out | `kwisatz logs <t>` |
| 6 | a prompt is needed | `kwisatz apply <t> --interactive` |
| 7 | converge impossible (diverged keys) | the printed command |
| 8 | `--keep-going` finished with ≥1 failure | `kwisatz status` |
| 9 | another run holds `<repo>/.kwisatz/lock` | `--lock-timeout 30` |

`kwisatz run` forwards the script's code, mapping its `2` to `1` and keeping it as
`script_exit_code` (R-EXIT-001).

## Behavior 8 — concurrency

One writer per checkout: `<repo>/.kwisatz/lock` records the PID and the start time, and is
treated as stale when the owner is gone or the path names a different checkout. A second
run exits `9` unless `--lock-timeout <s>` is given. Read-only commands never take the lock.

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

## Verification

- `tests/unit/test_plan.py` — resolution, ambiguity, ordering, the prerequisite table.
- `tests/unit/test_config.py` — A8, atomic write, backups, quoting, validate.
- `tests/unit/test_exec.py` — recorded env, timeout kills the process group, log mode.
- `tests/unit/test_services.py` — the health verdict, docker/systemd parsing, log dialects.
- `tests/unit/test_state_lock.py` — history ordering, one-writer rule.
- `tests/unit/test_conformance.py` — the CLI-vs-pyinfra `(command, env, stdin)` gate.
- `tests/unit/test_cli.py` — acceptance criteria A2…A10 against real subprocesses.
