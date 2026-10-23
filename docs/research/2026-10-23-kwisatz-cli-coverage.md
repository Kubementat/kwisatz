# Research — can this suite say what it covers?

Date: 2026-10-23 · Branch: `feat/kwisatz-cli-followups`
Ticket: follow-up 5 of the CLI review (`coverage of the CLI is invisible, so R-TEST-001 is unverifiable`)
Inputs: `pytest` runs with and without `coverage`, `docs/features/kwisatz-cli-specification.md` §12.1.

Verdict up front: **subprocess coverage works and is now in the repo, but it is not a gate.**
The spec claim R-TEST-001 is amended to state what the suite can actually be shown to satisfy,
and `bash tests/coverage.sh` is the command that shows it.

---

## 1. The symptom, measured

R-TEST-001 demands "100 % of `plan.py`, `config.py`, `jsonio.py`, `exec.py` public functions".
Measured, the answer was "unknown", because the tooling could not see the code that runs:

| command | `cli.py` | all of `src/kwisatz` |
|---|---|---|
| `pytest --cov` (parent process only) | 0 % | ~45 % |
| `bash tests/coverage.sh` (this ticket) | **77 %** | **84 %** |

`cli.py` at 0 % is not a hole in the suite — it is a blind spot in the measurement. Every CLI test
spawns a real subprocess (`run_cli()` → `python -m kwisatz`), because the point of those tests is
the real exit code and the real stdout/stderr split (R-TEST-003). The parent process therefore
executes only `conftest.py` and the imports, and reports the CLI's own module as untouched.

That number is worse than no number: it looks like a gap in the tests, and the actual gap — which
lines of which module nothing has ever executed — is invisible in the other direction.

## 2. What it took to make the children measure

Three moving parts, deliberately none of them a project dependency:

- `tests/coverage.sh` layers `coverage` over the project venv with `uv run --with coverage`, so
  `pyproject.toml` and `uv.lock` stay as they are and the lint gate never needs PyPI.
- `tests/coverage/sitecustomize.py` calls `coverage.process_startup()`, and it is only reachable
  while `COVERAGE_PROCESS_START` names `tests/coverage/py.coveragerc`. `parallel = true` because
  there are ~120 part files, one per child process, and `coverage combine` merges them.
- `tests/unit/conftest.py:run_cli()` forwards `COVERAGE_PROCESS_START`, `COVERAGE_FILE` and
  `KWISATZ_COVERAGE_SITE` into the child. That forwarding is the whole trick; without it the CLI's
  environment stays deliberately minimal and nothing measures.

One thing the ticket did not ask for and the suite demanded anyway: the trigger directory rides on
`PYTHONPATH`, and `PYTHONPATH` is exactly the variable the task scripts must *not* inherit
(`strip_venv_from_environ` removes `<repo>/src` for that reason, and `test_conformance.py` asserts
a task environment with no `PYTHONPATH` in it). The first coverage run turned that assertion red:
the pyinfra deploy passed `…/tests/coverage` through to a task script. So `strip_venv_from_environ`
now drops `KWISATZ_COVERAGE_SITE` alongside the checkout's own `src/`, and the conformance test is
the proof rather than the casualty.

That is the honest outcome of "add coverage plumbing": the plumbing was wrong until a test that
already existed caught it.

## 3. What the numbers actually say

Measured with this branch's 158 tests. `coverage` can report per *function* as well as per line,
which is the only shape that answers R-TEST-001: a function counts when its body ran, not when its
`def` line was imported. (The first version of this section used the `def` line and reported "zero
never executed" everywhere — an import is not a test, so that number was worthless. It is kept in
git history as a warning.)

The four modules R-TEST-001 names, plus `cli.py` for scale:

| module | statements | missing | lines | public functions | never executed by the suite |
|---|---|---|---|---|---|
| `plan.py` | 144 | 19 | 87 % | 14 | **2** — `catalog`, `exit_for_script` |
| `config.py` | 161 | 13 | 92 % | 16 | 0 |
| `jsonio.py` | 30 | 0 | 100 % | 3 | 0 |
| `exec.py` | 156 | 17 | 89 % | 4 | 0 |
| `cli.py` | 904 | 207 | 77 % | 26 | 3 — `cmd_list`, `config_of`, `CommandSpec.walk` |

The rest of the package, for comparison: `orchestrator.py` 90 %, `services.py` 92 %, `repo.py`
87 %, `checks.py` 86 %, `state.py` 92 %, `output.py` 94 %, `logs.py` 74 %, `errors.py` 100 %. The
package total is 84 %.

**So R-TEST-001 as written is false, and it is now knowable rather than folklore.** Two of
`plan.py`'s fourteen public functions are never called by any test:

- `catalog()` is called only by `cmd_list` (cli.py:696), and no test runs `kwisatz list` — the
  command appears in the suite exactly once, as a name inside the command-table assertion.
  One subprocess test fixes both functions and the command.
- `exit_for_script()` has no caller anywhere in `src/`, `tests/` or the shell side. §9 gives the
  mapping its real home (`_run_exit_code`, `run`'s `R-EXIT-001` path), so this is a second,
  unused copy of a rule.

The same question — *who calls this?* — was asked of every other never-executed public function in
the package, and it split into two different answers. **Reachable but untested:**
`logs.stream()` (needs `kwisatz logs -f`), `Out.step()`, `cli.config_of()` (the
"nothing to run" error path), `Service.is_down()`, `logs.apply_logs()` (`logs` has no list view
without a target). **No caller anywhere** — dead code, not a test gap: `orchestrator.note()`
(superseded by `Out.note`), `Task.env_masked` and `PlanItem.command` (both inlined by the callers
instead), `Service.is_down`, `Out.step`, `plan.exit_for_script`, `CommandSpec.walk` (the parser is
built by `_add_command`'s recursion, so this generator is never driven).

That is the value of the measurement: it is not the 77 % that matters, it is the list of names with
no reason to exist and the one command nobody tests. Neither was visible before.


## 4. Why there is no percentage gate

The temptation after measuring a number is to gate it, and it is the wrong lever here:

- the CLI's value is its observable contract — exit code, one document on stdout, what landed on
  disk — and that is asserted by subprocess tests, which a line count cannot substitute for;
- a threshold on `cli.py` (902 statements, 213 of them error paths and other-box branches) buys
  nothing a test would not have bought, and costs a green run every time someone deletes a line;
- the suite's real risk is not unexecuted lines but a contract nobody asserted, which is what
  tickets 1–4 of this review were about.

So R-TEST-001 is amended rather than enforced numerically: the requirement is that **every public
function of `plan.py`, `config.py`, `jsonio.py` and `exec.py` is executed by the suite**, measured
by `bash tests/coverage.sh`, and the line percentages are reported, not required. It is worth
saying plainly that the amended requirement is **currently missed by two functions** (§3) — one
command with no test, one function with no caller. Neither is a measurement problem, and neither is
fixed by a threshold.

## 5. Not adopted, and why

- **`coverage` as a dev dependency** (`uv add --dev coverage`): it would make `uv sync` and
  therefore `tests/lint.sh` depend on a package that no normal test needs, and the pre-commit hook
  would pay for it on every commit. `uv run --with coverage` costs one cached download and nothing
  in the lockfile.
- **A `coverage` step inside `tests/lint.sh`**: same reason — that script runs on every commit and
  must work offline in ~1 s. The coverage run is ~40 s and wants PyPI.
- **`[paths]` rewriting in the coverage config**: it printed every line twice (`src/…` matched both
  an absolute and a relative form). `source = kwisatz` is enough, because every part file sees the
  same absolute import path.
- **Coverage of the VM suite**: out of scope; those runs are 15–30 minutes and do not spawn the
  unit fixtures.

## 6. What to look at next time the question is asked

```console
bash tests/coverage.sh                      # the whole unit suite, per module
bash tests/coverage.sh --fail-under 80      # same, failing below the bar
uv run --with coverage --no-sync python -m coverage report -m   # the missing lines, per file
```

`coverage combine` prints "Combined 76 files, skipped 43" on a full run. The skipped files are
*duplicate data* — the same process's measurement arriving twice, which coverage reports and
discards rather than double-counting — so they are not lost coverage. If the number ever grows
past the part files that were combined, the thing to look at is `combine --debug=combine`.
