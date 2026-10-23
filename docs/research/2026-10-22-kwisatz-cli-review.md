# Research — the kwisatz CLI against the box as it is

Date: 2026-10-22 · Branch: `feat/kwisatz-cli`
Inputs: `docs/features/kwisatz-cli-specification.md` (the requirement layer), the existing
orchestrator (`deploy.py`, `run-setup.sh`, `src/kwisatz/orchestrator.py`), and the running
state of a provisioned host (`/srv`, docker, systemd, GPU, 58 task scripts).

This is not a design document. It records what the code *claims* versus what the machine
*does*, and the recommendations that came out of that gap. Everything marked **adopted** is
implemented in this branch; **deferred** is written down so it cannot quietly become folklore.

---

## 1. The claim that turned out to be false, and what replaced it

The spec says (R-ARCH-101, §2): *"`deploy.py` emits one pyinfra `server.shell` operation per
enabled script, in config order."* That is what the code does — but §11 claims the apply echo
appears on stdout, which `deploy.py` contradicts (`-vvv` routes the operation report to
stderr). That mattered because a test asserted against stdout and then "passed" for the wrong
reason.

More generally: **the spec asserts observable behaviour that the implementation owns.** Any
"documented" fact that only the tests can verify is a fact that drifts. So the recommendation
adopted here is *evidence-shaped tests*: the fixtures record what they were given

```bash
{ printf '%s\n' "$@" >> "$KWISATZ_RECORD_ARGV";
  while IFS= read -r line -u 3; do printf '%s\n' "$line" >> "$KWISATZ_RECORD_STDIN"; done 3< /dev/stdin; }
```

and the tests assert over those records, not over printed strings. `INTERACTIVE=false`, the
project-venv strip, `/dev/null` stdin, `--env` precedence and the
CLI-vs-pyinfra `(command, env, stdin)` triple are therefore *enforced*, not *described*.

## 2. Two commands cannot both be the execution contract

`apply` (direct `subprocess`) and `deploy.py` (pyinfra) differ in everything a script could
notice: `run.sh` versus `env VAR=… bash tasks/x.sh`, `SUDO_ASKPASS` propagation, venv activation.
The spec's answer was a table plus "keep them aligned by discipline" (R-ARCH-102). Discipline
does not survive a refactor; a test does.

**Adopted:** `deploy.py` imports the module that defines the contract
(`build_command` / `build_env` / `enabled_in_order`) instead of restating it, and
`test_conformance.py` fails the build when the two paths disagree. While wiring that, one real
divergence surfaced: `.py` task scripts received the *system* interpreter via `SUDO_ASKPASS`
under sudo, so a `.py` task under a root-run apply would have used a different Python than the
same task run directly. Fixed by pinning `sys.executable`.

## 3. `src/kwisatz/` instead of a root-level package (deviation)

R-ARCH-002/003 asks for a package named `kwisatz/` **and** an executable `./kwisatz` at the
repo root. On a case-insensitive filesystem — and, more relevantly, on any filesystem — those
two are the same name. The checkout keeps the executable at the root (zero-install is the
point) and the package under `src/`, which is also what lets `./kwisatz` run with
`PYTHONPATH=src` before anything is installed. Everything else about the requirement holds.

## 4. What the machine says about discovery, health, and ordering

Measured on a provisioned host, not assumed:

| finding | consequence for the CLI |
|---|---|
| Traefik's compose stack lives outside `/srv`, at `/opt/traefik` | discovery keys off `com.docker.compose.project*` labels first, `/srv/*` second — and read §5b/1 before trusting it: the label path was silently dead on a modern engine until the `docker info` probe was fixed, which is exactly the class of thing a `/srv`-only unit test cannot notice |
| 11 compose stacks, 5 `devenv_*` worktree stacks that are not kwisatz services | stacks are attributed by path and by project name, so `kwisatz services` does not present a developer's pet stack as an installed service |
| a systemd unit that does not exist reports `active=false`, indistinguishable from "stopped" | `LoadState` is checked; a missing unit is reported as *missing*, never as stopped |
| `lib/helpers.sh:wait_for_healthy` counts `health=none` as healthy and restart policy does not count as progress | the CLI's health verdict reuses that rule rather than inventing "running == healthy", or the CLI and the scripts would disagree forever |
| `setup-docker` must precede 14 services; `setup-nvidia-container` precedes 7 GPU tasks; a script that needs docker only *checks* for it | ordering is data in `src/kwisatz/data/prerequisites.yml`, not code, so a new GPU task is one line and `kwisatz status` shows it |

## 5. Recommendations adopted in this branch

1. **Evidence-shaped tests** over the recorded env/argv/stdin (see §1) — the single highest-value change, because it converts every contract statement in the spec into a gate.
2. **One contract module** that both entry points consume (§2), with the parity test as a release gate.
3. **Secrets never cross the CLI boundary.** `machine-config.yml` is plain text on a box that will hold API keys, so `env:` values are masked in output and in `--json` (opt out with `--reveal`, which is itself announced), and the echo of a command shows `KEY=*MASKED*` exactly as `deploy.py` already did.
4. **Convergence over faith.** Before running anything, read the box: port collisions against `ss`, disk against `/srv`, and — when nothing was installed but nothing succeeded — run `wait_for_healthy` before declaring failure, which is the difference between "the stack is broken" and "the run timed out 3 seconds early".
5. **The exit code is the API** (§8 of the spec) — 10 codes, `run` forwarding the script's code as `script_exit_code`, and 9 (lock) actually implemented, because a second `kwisatz apply` from an agent is a real scenario now that agents drive this.
6. **No silent host mutation.** `install` does not download uv behind your back: `--with-uv <version>` is pinned and gated on `--yes`. `models sync --dry-run` prints the command instead of fabricating a dry-run that `tasks/sync-models.py` does not have.
7. **Config edits that respect the file.** `ruamel.yaml` round-trip, atomic 0600 write, 5 kept backups, validate-after-write with rollback, and a test that enables one flag in a commented file and asserts *one line* changed.

## 5b. What the VM run actually found

`tests/run-vm-tests.sh` passed 9/9 for `setup-basics`, `setup-docker`, `configure-firewall`,
`setup-traefik` (twice each) on Ubuntu 26.04 — and that is the least interesting thing in this
section, because **the suite never runs the CLI**: its precheck is `run-setup.sh status` and its
test phase is `sudo -u <user> env … tasks/<name>.sh`. So I kept the VM (`--keep-vm`) and drove
the CLI on it. Six of the findings below would not have shown up in any amount of unit testing.

| # | defect | how the VM caught it | fixed |
|---|---|---|---|
| 1 | `docker_running()` probed `docker info --format '{{.Server.Version}}'`. Engine 29.9 removed that field from the format struct, so the probe exits 1 and the function answered *False on a working daemon* — which silently deleted every docker stack from `kwisatz services` (`/opt/traefik/docker-compose.yml` was running, labeled, healthy, and invisible). | traefik was missing from `services` right after a green traefik install | `{{.ServerVersion}}` first, `docker version --format {{.Server.Version}}` as fallback; regression test that a modern engine is still "running" |
| 2 | The drain loop in `run_task` ended on pipe EOF and then read `proc.poll()`, which can still be `None` a few milliseconds before the child is reaped. The old `_returncode` mapped that to **1** — a fabricated failure for a script that exited 0. | 2 of 6 `kwisatz apply setup-traefik` runs failed with "exited 1" while the script's own log showed the success banner; manual `bash tasks/setup-traefik.sh` was 3/3 clean | wait for the child after EOF; never invent a status. Regression test closes stdout, sleeps, `exit 0` |
| 3 | The checkout shim exports `PYTHONPATH=<repo>/src`, and the CLI passed it through to the task scripts. pyinfra does not, so the "identical env" rule was already broken — a task's `python3` could import kwisatz's own modules. | a recording script under `kwisatz run` recorded `PYTHONPATH=`, where pyinfra recorded nothing | stripped in `strip_venv_from_environ`; `PYTHONPATH` added to the conformance fixture's recorded keys so it is a gate now |
| 4 | A lock file that already exists but parses as nothing (empty file from `flock`, a truncated write after a crash, an operator `touch`) escaped `try_acquire` as `FileExistsError` → traceback, exit 1 instead of 9. | `flock -x 9 9>.kwisatz/lock` in the background, then `kwisatz apply` | exists-but-nameless owner is "held" for 1 s (so a run mid-creation is not clobbered), then reclaimed; a held lock answers exit 9 with the path named |
| 5 | `doctor` wrote all of its verdicts to stderr (`ok()` is progress), so `kwisatz doctor | grep docker` found nothing and `-q doctor` printed nothing; `--json` had no `items` key even though README, the skill and `behaviors.md` all told agents `jq '.result.items[]|select(.ok|not)'`. | stdout of `./kwisatz doctor 2>/dev/null` was empty | a `verdict()` channel that is stdout unless `--json`; `result.items` added, carrying prerequisites, port conflicts and unhealthy stacks |
| 6 | The OS check demanded 22.04/24.04, so an Ubuntu 26.04 box — **the release `tests/run-vm-tests.sh` boots by default** — failed `doctor` with exit 4 while every script installed cleanly. | `doctor rc=4` on a box with zero real problems | untested-but-Ubuntu release is advisory (⚠, not required); non-Ubuntu stays a real stop, because the scripts are apt-based |
| 7 | **The lint gate had a hole**: `[tool.ruff] exclude = [..., "kwisatz"]` (added to keep the extensionless bash shim from being parsed as Python) also matched `src/kwisatz`, so `ruff check src` reported "No Python files found" and every earlier "All checks passed!" had been checking the tests only. Nine real findings — including one `F821` — appeared the moment the pattern was anchored to `/kwisatz`. | `ruff check src` printing a warning I had learned to ignore | exclude is `/kwisatz`; verified with a deliberate `import os` probe file |

Two things the run did *not* find, so that the negative result is on record: the
`(command, env, stdin)` conformance gate held on a real machine, and nothing in the M1/M2
surface produced a traceback on a clean box.

## 6. Deferred, with reasons

| item | why |
|---|---|
| `requires:` keys in `machine-config.yml` (R-ORDER-003) | the generated `depends_on` can *create* cycles in a 58-entry config; the data table gives the same guarantee without letting config errors hang a run |
| service/group selection (`--group`, `kwisatz.services` as a selector) | needs a `services:` section and a policy for what "group" means; nothing in the current config has a natural grouping |
| `doctor --fix`, `--redact-stdout`, `upgrade`, `uninstall`, completions | each is either a mutation surface or a generated artifact; all four want a design pass, not a stub |
| VM-based integration tests (`tests/run-vm-tests.sh --cli`) | the unit/conformance layer is green; the VM matrix is the next gate, and its runner already exists |
| `state show` as a distinct verb | `kwisatz state --json` covers the machine case; a pretty human view is worth having, not worth a second code path today |
| exit `6` and `7` | both are published in `commands --json` and documented as **reserved**. `7` is A4's branch: telling an operator that a running stack's keys diverged, and printing the exact command that re-creates it, wants a real diff against the live compose/project state — a guess here would be the most expensive lie this CLI can tell. `6` wants the CLI to raise a prompt of its own, which today belongs to the script. Both cost more than the one sentence that makes them honest: they are asserted as reserved in `test_jsonio.py`, so whoever ships them has to update the table. |

## 7. Open questions for the next round

- Should `kwisatz services` be allowed to *select* apply targets (making discovery authoritative over the config)? Today discovery answers "what is running" and nothing else.
- Is `.kwisatz/state.jsonl` the right long-term store, or does it want to become the same append-only JSONL shape `docs/superpowers/research/2026-07-03-pipeline-design.md` settled on?
- `--config` currently overrides pyinfra's `--data config=`; if a user passes both, which wins? (Today: the CLI flag, silently. That is a decision, not a fact, and should be stated somewhere.)
