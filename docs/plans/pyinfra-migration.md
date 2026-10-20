# Plan: replace `run-setup.sh` with pyinfra

Date: 2026-10-01 (implemented, except verification steps 4–6)
Branch: `feat/pyinfra-migration`
Docs: https://docs.pyinfra.com/en/3.x/ (tested against pyinfra v3.10.0)

## Goal

Replace the hand-written orchestrator `run-setup.sh` (755 lines of bash: arg
parsing, yq plumbing, logging, summary) with a pyinfra deploy. Least effort:
**only the orchestrator moves**. The 51 task scripts in `tasks/` stay bash and
are run unchanged; `machine-config.yml` keeps its format.

Out of scope: rewriting task scripts as native pyinfra operations
(`apt.packages`, `files.template`, …). That is ~50 scripts with 674 `sudo`
calls and a VM test suite built around them. It can happen later, one task at
a time, inside the same `deploy.py`.

## Research findings

Verified with a prototype against fake task scripts (pyinfra 3.10.0 via `uvx`):

| Question | Result |
|---|---|
| Run a task script with config env + args | `server.shell(commands=[...], _env={...})` — env values and args with spaces/`$` are quoted correctly |
| Config order preserved | yes — operations run in the order `deploy.py` declares them, i.e. YAML document order |
| `status` equivalent | `--dry` prints the list of enabled operations without executing |
| Live output of long tasks | only with `-vvv` (streamed line by line, prefixed `[@local]`); without it output appears only on failure |
| Stray `read` in a task | `</dev/null` on the command makes it fail fast, same as today |
| Failure handling | default: first failed task stops the run, exit 1. With `_ignore_errors=True` the run continues, but **pyinfra exits 0** |
| `--config <file>` | `--data config=<file>`, read via `host.data.get("config")` |
| YAML parsing | pyinfra does **not** ship PyYAML — needs to be declared as a dependency |
| `server.script` | uploads a single file — unusable, tasks need `lib/` and `templates/` next to them. Use `server.shell` with the repo path |

Not verifiable in this session: `sudo` password prompts from inside task
scripts under pyinfra (no tty here, and this machine needs a password). sudo
prompts on `/dev/tty`, so it should work, but the prompt may interleave with
pyinfra output. Fallback: run `sudo -v` first. The test VM has passwordless
sudo, so the VM suite will not catch this — check once by hand.

## Changes

1. **`deploy.py`** (new, ~25 lines) — read the config, emit one `server.shell`
   per enabled script:

   ```python
   doc = yaml.load(config.read_text(), Loader=yaml.BaseLoader)
   for name, s in doc["scripts"].items():
       if (s or {}).get("enabled") != "true":
           continue
       cmd = shlex.join(["bash", f"{ROOT}/tasks/{name}.sh", *(s.get("args") or [])])
       server.shell(
           name=name,
           commands=[cmd + " </dev/null"],
           _env={"INTERACTIVE": "false", **(s.get("env") or {})},
       )
   ```

   `yaml.BaseLoader`, not `safe_load` + `str()`: it keeps every scalar a string
   exactly as written. `str()` would turn an unquoted `FOO: true` into `True`
   and `1.10` into `1.1`, which the bash tasks would not recognise.
   Config env placed after `INTERACTIVE` so a per-script entry still wins.
   A missing/unparsable config or a `.scripts` that is not a mapping raises
   `pyinfra.api.exceptions.DeployError`, which pyinfra prints as one line
   (any other exception type gets a full traceback).

2. **`pyproject.toml`** (new, ~6 lines) — `dependencies = ["pyinfra>=3.10,<4", "pyyaml"]`,
   so the command is `uv run pyinfra …` with no extra flags. `.venv/` is
   already gitignored.

3. **Replace `run-setup.sh` with a minimal shim** (decision: keep the file so
   existing `./run-setup.sh apply|status` commands keep working; not deleted).
   It maps the subcommand to the pyinfra flags, passes any further arguments
   through, and prints usage otherwise:

   | Command | Runs |
   |---|---|
   | `./run-setup.sh status [args]` | `uv run pyinfra @local deploy.py --dry [args]` |
   | `./run-setup.sh apply [args]` | `uv run pyinfra @local deploy.py -y -vvv [args]` |
   | ~~`-c other.yml`~~ | `--data config=other.yml` |

   The old `-c/--config`, `--interactive`, `--non-interactive` options, the
   yq/jq auto-install and the `logs/` tee are gone.

4. **Test harness** — `tests/remote/run-tests.sh`: swap the precheck for the
   new form (`./run-setup.sh status --data config=…`); `tests/run-vm-tests.sh`:
   install `uv` (to `/usr/local/bin`) in the VM bootstrap step. The integration/idempotency phases call task scripts directly and do
   not change.

5. **Docs** — update the orchestrator description in `README.md`,
   `skills/kwisatz-assistant/SKILL.md`, `tests/README.md`,
   `specification/project/architecture.md` + `description.md`,
   `machine-config-inference.yml.example`, and the comment in
   `tasks/setup-unsloth.sh`. Add `uv` as the one bootstrap prerequisite
   (`curl -LsSf https://astral.sh/uv/install.sh | sh`). Fix `AGENTS.md`
   references to the orchestrator.

## Behaviour changes

| Today | After | Why |
|---|---|---|
| A failed task is logged, the rest still run, exit 1 at the end | Run stops at the first failed task, exit 1 | pyinfra default. Keeping "continue" means exit 0 on failure, or extra code. Stopping is also safer for the documented orderings (sshd → firewall, docker → traefik, nvidia → GPU tasks) |
| `status` lists enabled *and* disabled scripts with env/args | `--dry` lists enabled scripts only | read the YAML for the rest |
| Output teed to `logs/run-setup-*.log` | no log file | append `2>&1 \| tee logs/apply.log` when wanted |
| `--interactive` passes a tty to tasks | gone | pyinfra pipes stdin/stdout. For prompts run the task directly: `INTERACTIVE=true tasks/setup-x.sh` |
| `apply` auto-installs yq/jq via `setup-basics` | gone | the orchestrator no longer needs them; `setup-basics` still installs them for the tasks |
| Fresh machine needs only bash | needs `uv` first | one curl line |
| `apply` prints task output only | `apply` also echoes each command line, including the configured `env:` values | `-vvv` is the only pyinfra level that streams output, and it includes the input. Secrets in `env:` end up in the terminal/scrollback |
| Unknown subcommand exits 1 | usage + exit 2 | shim |

## Verification

1. `ruff check deploy.py`; `shellcheck` on the two test scripts; `yamllint` on
   the touched example config.
2. `uv run pyinfra @local deploy.py --data config=tests/machine-config.test.yml --dry`
   lists exactly the enabled scripts, in config order.
3. Missing config and a config with `scripts: []` both give a one-line error,
   not a traceback.
4. `tests/run-vm-tests.sh` passes (precheck + both phases).
5. On the VM: full `apply` via pyinfra with the test config exits 0; a second
   run exits 0.
6. By hand on a password-sudo machine: `apply` with one cheap task enabled,
   confirm the sudo prompt works.

## Later, not now

- Remote hosts (`pyinfra my-host deploy.py`): add one `files.rsync` operation
  that copies the repo before the task loop.
- Porting individual tasks to native operations.
