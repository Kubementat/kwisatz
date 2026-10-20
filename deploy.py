"""kwisatz orchestrator: run every enabled task script of machine-config.yml, in config order.

Usage: uv run pyinfra @local deploy.py [--dry | -y -vvv] [--data config=<file>]
(`./run-setup.sh apply|status` wraps exactly this.)

Config contract — `.scripts.<name>` is a mapping of `enabled` / `env` / `args`
(`description` is informational). An entry that is not a mapping is a hard error
naming the script; an empty entry (`setup-foo:`) means disabled. The key resolves to
`tasks/<name>.sh`, or `tasks/<name>.py` when there is no `.sh` — see `task_command()`.
A null `args:`/`env:` (the key with nothing under it — how the examples spell "no
arguments", with the flags in the comment below) means *none*, as `.args // []` and
`.env // {}` did under yq+jq. Only an enabled script's `env:`/`args:` are checked hard;
a disabled one is reported and left alone, since it cannot change this run.

`enabled` is a YAML 1.2 boolean: `true` runs the script, `false` or a missing key
skips it. `yes`/`on`/`1` are *not* booleans in YAML 1.2, so they skip — and every
value that is not the canonical lowercase spelling gets a `--> WARNING:` line, so
nothing is ever enabled or skipped silently. `True`/`TRUE`/`FALSE` are accepted
(they were under the old yq+jq orchestrator) but reported.

Environment handed to a task script (verified against pyinfra 3.10.0):
  * `api/arguments.py:generate_env()` builds `_env` from `Config.ENV` (empty by
    default) plus the dict below — pyinfra never merges `os.environ` into it. It
    only prefixes the command with `export K=V ... &&`
    (`connectors/util.py:make_unix_command`), and `LocalConnector` runs that via
    `Popen(shell=True)` with no `env=`, so the script still inherits the ambient
    environment of the shell that started the run. Net effect equals the old
    orchestrator's `export INTERACTIVE=false; <config env>; bash script`.
  * `INTERACTIVE=false` is injected for every script (the old non-interactive
    policy) *before* the config's `env:` entries, so `INTERACTIVE: "true"` per
    script still wins.
  * `stdin` comes from pyinfra's `/dev/null`: a stray prompt gets EOF and fails
    fast instead of hanging the run.
  * Config `env:` values are wrapped in `HiddenValue`, so at `-vvv` — the only
    level that streams task output — the echoed command line reads
    `export KEY=*MASKED*` while the script receives the real value
    (`api/command.py` masks in `__str__`, `connectors/local.py` executes
    `get_raw_value()`; same mechanism as `docker.login`). Script names, `args`
    and task output are NOT redacted: keep credentials in the
    `/srv/<service>/.env` files the tasks manage, not in `machine-config.yml`.
"""

import os
import shlex
import sys
from pathlib import Path

import yaml
from pyinfra import host
from pyinfra.api import HiddenValue
from pyinfra.api.exceptions import DeployError
from pyinfra.operations import server

ROOT = Path(__file__).resolve().parent

# `uv run` activates the project venv; task scripts must see the system python3/pip
# (the @local connector's subprocesses inherit this environment)
os.environ.pop("VIRTUAL_ENV", None)
os.environ["PATH"] = os.pathsep.join(
    p for p in os.environ["PATH"].split(os.pathsep) if p != f"{sys.prefix}/bin"
)

# `enabled` is a YAML 1.2 boolean, i.e. exactly these spellings. `yes`/`on`/`1` are NOT
# booleans in YAML 1.2 (they are a string / a number) and stay disabled — the old yq+jq
# orchestrator behaved the same way (`.scripts[$name].enabled // false | grep -qx true`,
# verified against both yq flavors). Difference from the first pyinfra cut: every value
# that is not the canonical lowercase spelling gets a warning, so nothing is ever
# skipped silently, and `True`/`TRUE` enable as they used to.
TRUE_SPELLINGS = ("true", "True", "TRUE")
FALSE_SPELLINGS = ("false", "False", "FALSE")
# BaseLoader does not resolve scalars, so a null arrives as one of these strings
NULL_SPELLINGS = ("", "~", "null", "Null", "NULL")


def is_null(value) -> bool:
    """True when a BaseLoader scalar means 'no value' (`key:` with nothing under it)."""
    return value is None or value in NULL_SPELLINGS


config = Path(host.data.get("config") or ROOT / "machine-config.yml")


def warn(message: str) -> None:
    """Print a config warning in pyinfra's own `-->` style, on stderr."""
    print(f"--> WARNING: {message}", file=sys.stderr)


def is_enabled(name: str, entry: dict) -> bool:
    """Read `.enabled` of one script entry; warn about anything non-canonical.

    Missing key = disabled and silent ("all scripts are disabled by default").
    `true`/`True`/`TRUE` = enabled; `false`/`False`/`FALSE` = disabled; anything else
    (`yes`, `on`, `1`, an empty value, a list) = disabled *with a warning*.
    """
    if "enabled" not in entry:
        return False

    value = entry["enabled"]
    if is_null(value):
        warn(f"{name}: `enabled:` has no value; the script is skipped")
        return False
    if value in TRUE_SPELLINGS:
        if value != "true":
            warn(f"{name}: `enabled: {value}` enables the script; write `enabled: true`")
        return True
    if value in FALSE_SPELLINGS:
        if value != "false":
            warn(f"{name}: `enabled: {value}` skips the script; write `enabled: false`")
        return False

    # BaseLoader keeps scalars as strings, so this catches yes/on/1/1.0/list/dict
    warn(f"{name}: `enabled: {value}` is not a YAML boolean; the script is skipped")
    return False


def task_command(name: str) -> list:
    """Resolve the config key `name` to the command that runs it.

    `tasks/<name>.sh` is the entry point for every shell task and takes precedence when
    both spellings exist (a `.py` of the same name is that script's helper, not a second
    entry point) — the operator is told which one wins. A `.py` entry point runs under
    *this* deploy's interpreter, `sys.executable`, so its imports resolve against the
    project venv that `uv run` created (`pyyaml` is a project dependency) instead of the
    host's system python: a fresh VM has no `python3-yaml`, and `apply` must work there.
    Neither spelling existing is a hard error naming the script, so `status` catches the
    typo instead of `apply` failing after ten installed services.
    """
    sh = ROOT / "tasks" / f"{name}.sh"
    py = ROOT / "tasks" / f"{name}.py"
    if sh.is_file():
        if py.is_file():
            warn(f"{name}: tasks/{name}.sh and tasks/{name}.py both exist; running the .sh")
        return ["bash", str(sh)]
    if py.is_file():
        return [sys.executable, str(py)]
    raise DeployError(
        f"{config}: script {name}: no tasks/{name}.sh or tasks/{name}.py — the config key "
        f"must match a file in {ROOT / 'tasks'}/"
    )


def check_shape(name: str, entry) -> dict:
    """Validate the *shape* of one `.scripts.<name>` entry; raise DeployError naming it.

    This half is always fatal, because it is about the entry itself: `setup-foo:` with
    nothing under it is a disabled script, and anything that is neither a mapping nor a
    null (`setup-foo: enabled`) is a typo the operator must see. `env:`/`args:` are
    checked by `check_values()`, which a disabled script only reports.
    """
    if is_null(entry):
        # `setup-foo:` with nothing under it — an empty entry, i.e. disabled, exactly
        # like a key with no `.enabled`
        return {}
    if not isinstance(entry, dict):
        raise DeployError(
            f"{config}: script {name}: expected a mapping of enabled/env/args, "
            f"got {type(entry).__name__}: {entry!r}"
        )
    return entry


def check_values(name: str, entry: dict, strict: bool) -> None:
    """Validate `env:`/`args:` of a checked entry.

    `strict` means *this entry will run*, so a wrong type is a hard error. For a disabled
    entry the same problem is only reported: the entry cannot change anything this run
    does, so blocking `status`/`apply` on it — as it did when `check_shape()` validated
    every entry regardless of `enabled` — punishes a config for a script it does not run.

    A null `args:` / `env:` (the key present with nothing under it, which is how the
    example configs spell "no arguments": the real flags sit in the comment below it) is
    **not** an error, it is *none* — matching `.args // []`/`.env // {}` from the old
    yq+jq orchestrator. The shipped `machine-config*.yml.example` files depend on that.
    """
    args = entry.get("args")
    if not is_null(args) and (
        not isinstance(args, list) or any(not isinstance(a, str) for a in args)
    ):
        message = f"`args` must be a list of strings, got {args!r}"
        if strict:
            raise DeployError(f"{config}: script {name}: {message}")
        warn(f"{name}: {message} (disabled, not run)")

    env = entry.get("env")
    if not is_null(env) and (
        not isinstance(env, dict)
        or any(not isinstance(k, str) or not isinstance(v, str) for k, v in env.items())
    ):
        message = f"`env` must be a mapping of strings, got {env!r}"
        if strict:
            raise DeployError(f"{config}: script {name}: {message}")
        warn(f"{name}: {message} (disabled, not run)")


try:
    raw = config.read_text()
except OSError as e:
    # missing file: point at the example / --data override instead of a generic error
    hint = ""
    if config == ROOT / "machine-config.yml" and (ROOT / "machine-config.yml.example").is_file():
        hint = " (copy machine-config.yml.example to machine-config.yml, or pass --data config=<file>)"
    msg = " ".join(f"{type(e).__name__}: {e}".split())
    raise DeployError(f"{config}: cannot read config{hint} ({msg})")
try:
    # BaseLoader keeps every scalar a string, exactly as written (true stays "true")
    doc = yaml.load(raw, Loader=yaml.BaseLoader)
except yaml.YAMLError as e:
    # unparsable YAML: one line naming the file, not a traceback
    msg = " ".join(f"{type(e).__name__}: {e}".split())
    raise DeployError(f"{config}: cannot parse the config ({msg})")

if doc is None:
    problem = "the file is empty"
elif not isinstance(doc, dict):
    problem = f"the top level is {type(doc).__name__}, not a mapping"
elif "scripts" not in doc:
    problem = "there is no `scripts:` mapping"
elif not isinstance(doc["scripts"], dict):
    problem = f"`scripts:` is {type(doc['scripts']).__name__}, not a mapping"
else:
    problem = ""
if problem:
    raise DeployError(f"{config}: expected `.scripts` to map script name to entry; {problem}")
scripts = doc["scripts"].items()

for name, s in scripts:
    entry = check_shape(name, s)
    enabled = is_enabled(name, entry)
    check_values(name, entry, strict=enabled)
    if not enabled:
        continue
    cmd = shlex.join([*task_command(name), *(entry.get("args") or [])])
    # Config env comes after INTERACTIVE so a per-script entry still wins. Values are
    # wrapped in HiddenValue: `apply` runs at -vvv, which echoes the generated command
    # (`export KEY=*MASKED* && bash tasks/x.sh`), while the connector executes the raw
    # value — pyinfra/api/command.py get_raw_value(), same trick as docker.login.
    env = {key: HiddenValue(value) for key, value in (entry.get("env") or {}).items()}
    server.shell(
        name=name,
        commands=[cmd + " </dev/null"],
        _env={"INTERACTIVE": "false", **env},
    )
