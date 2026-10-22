# Plan — `kwisatz apply` drives `deploy.py` (one engine), and the VM suite drives the CLI

Branch: `feat/kwisatz-cli` · Date: 2026-10-22
Spec: `docs/features/kwisatz-cli-specification.md` §16.1 (resolved), §11.3 (R-ARCH-101/102/103),
§12.1.4 · Behaviors: `specification/features/kwisatz-cli/behaviors.md`

## The decision

Two things the CLI could do for a long time and one that it should not keep doing.

| Option | Verdict |
|---|---|
| `apply` runs the script directly (`exec.py`), pyinfra only for the batch path | the old M1 design — two engines, kept honest only by discipline. **Rejected.** |
| `apply` starts a pyinfra deploy of the checkout, selecting targets with `--data select=` | **Adopted.** One engine, pyinfra stays the framework, and single-target apply cannot drift from a full one. |
| `apply` runs `deploy.py` once per whole run | considered; rejected for the observable-per-target loss (see below) |

Two details that follow from the choice, agreed while implementing:

1. **One deploy per target, not one per apply.** `kwisatz apply` starts
   `deploy.py -y -vvv --data config=<file> --data select=<name>` per resolved target, so every
   target keeps its own exit code, log, duration and `--json` item. A full `apply` of twelve
   enabled scripts pays ~1 s of deploy startup for each; the alternative (one deploy with all
   names) hides which of the twelve failed.
2. **Direct script runs survive only where pyinfra cannot go.** `--interactive` (no TTY inside a
   deploy) and `kwisatz run <target> -- <args>` (the script's own flags) are the two sanctioned
   manual paths, which is the "run it by hand as the fallback" the workflow already had.

## Success criteria (how this was verified)

| Criterion | Evidence |
|---|---|
| The task script is run by a deploy, not by the CLI | `tests/unit/test_deploy_engine.py::test_apply_hands_each_target_to_deploy_py` — the stub records its ancestor chain: the connector's `sh -c` above it, and `-m pyinfra … deploy.py … --data select=<name>` above that |
| The deploy honours `select` (names, order, disabled entries, unknown name) | `test_deploy_select_*` — 5 cases against a real `pyinfra @local deploy.py` |
| `--env` still wins over the config, now that the deploy owns the env | `test_deploy_env_data_wins_over_the_config` + `test_cli.py::test_an_env_flag_wins_over_the_config` |
| Interpreter choice is deterministic | `test_the_deploy_prefers_the_interpreter_it_is_running_in`, the venv fallback, and exit `4` when nothing can run pyinfra |
| `run-setup.sh` no longer exists as a second entry point | it prints DEPRECATED, translates `apply|status` and `--data config=`, execs `./kwisatz`; exit codes are the CLI's |
| The VM suite exercises the shipped command | `run-vm-tests.sh --mode cli` is the default; precheck is `./kwisatz status`; report prints the mode and the precheck's real command |
| Nothing else broke | `uv run pytest` (114), `ruff`, `shellcheck`, `tests/lint.sh`; VM run: see below |

## Changes

| Area | What moved |
|---|---|
| `deploy.py` | `--data select=` (run exactly the named targets, in order, disabled or not) and `--data env={…}`; still no contract of its own |
| `kwisatz/orchestrator.py` | `select_tasks()`; `overrides=` threaded through `build_task`/`build_plan`/`iter_enabled` |
| `kwisatz/repo.py` | `pyinfra_command()` (interpreter → venv → uv → exit 4) and `deploy_argv()` — the single place the deploy command line is built |
| `kwisatz/exec.py` | `run_deploy()` + `deploy_env()`; `run_task()` and the streaming/logging/timeout machinery unchanged underneath (both call `_execute`) |
| `kwisatz/cli.py` | `_deploy_argv()` and the apply loop; the interactive branch stays direct |
| `run-setup.sh` | deprecated shim |
| `tests/remote/run-tests.sh` | `--mode cli|script` (default `cli`); precheck per mode; the env/args/entry-point resolution now belongs only to `script` mode |
| `tests/run-vm-tests.sh` | `--mode`, passes it to the runner, reports the mode and the precheck command, drops the copied `.venv`/`.kwisatz` from the VM (scp has no exclude, and a host venv would be the CLI's fast path) |
| `tests/lint.sh` | guard 4 parses the example configs through `./kwisatz apply --dry-run` |
| docs | spec (§11.3, §6.1, §12.1, §16.1/2, compatibility matrix, R-OUT-004), `architecture.md` (the "two paths" section becomes "one engine"), `test-strategy.md`, `behaviors.md`, `README.md`, `AGENTS.md`, the assistant skill, `tests/README.md` |

## Known consequences to live with

- pyinfra is a run-time prerequisite of `apply` (`uv` or the checkout's venv), and one more
  process per target (~1 s).
- pyinfra writes its report — including the task's own stdout — to **stderr**. `apply x > f`
  therefore captures the plan, not the script. The full output is in
  `logs/kwisatz-<ts>-<target>.log`; `kwisatz logs <target>` reads it. This is what
  `run-setup.sh apply` always did, and `--interactive`/`kwisatz run` is the path that gives you
  the script's stdout.
- `run-setup.sh`'s exit codes become the CLI's: `status` on an unparsable config exits `3`, not `1`.
- A pre-existing bug found on the way: `state.record()` indexed `duration_ms` on an item that
  never ran, so `apply` of three scripts where the first failed ended in a traceback instead of
  the error contract. Fixed (`i.get(k)`); the failing case is covered by
  `test_cli.py::test_a_failing_script_stops_the_run_and_yields_exit_1`.

## Not done here

- Deleting `run-setup.sh` (next release, per R-ARCH-103).
- One `--keep-going` deploy for the whole config (would be nice; the loop covers it).
- Making `run-vm-tests.sh` copy the repo without `tests/reports/` and `logs/` — the scp is
  unchanged apart from dropping `.venv`, and the copy is already the slow part of the suite.
