"""Shared orchestration logic: the single execution contract of kwisatz.

Everything `deploy.py` did before it lives here: config loading, the `enabled`
evaluation, script resolution, and the env/command construction of a task run. Both
entry points read this module, so the CLI path and the pyinfra path cannot drift
(`docs/features/kwisatz-cli-specification.md` §11.3 / R-ARCH-102).

The rule that keeps parity provable: a `Task` carries *everything* one run means —
argv, env, stdin, masking — and nothing about shells, pyinfra or subprocesses. A
caller turns a Task into a run; this module only describes it.

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

Environment handed to a task script:
  * the ambient environment of the calling shell (both entry points inherit it),
  * `INTERACTIVE=false` injected for every script *before* the config's `env:`
    entries, so `INTERACTIVE: "true"` per script still wins,
  * `stdin` from `/dev/null`: a stray prompt gets EOF and fails fast instead of
    hanging the run.
  * Config `env:` values are masked in every echo of the command (`*MASKED*`) while
    the script receives the real value. Script names, `args:` and task output are NOT
    redacted: keep credentials in the `/srv/<service>/.env` files the tasks manage,
    not in `machine-config.yml`.
"""

from __future__ import annotations

import os
import re
import shlex
import sys
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

# `enabled` is a YAML 1.2 boolean, i.e. exactly these spellings. `yes`/`on`/`1` are NOT
# booleans in YAML 1.2 (they are a string / a number) and stay disabled — the old yq+jq
# orchestrator behaved the same way (`.scripts[$name].enabled // false | grep -qx true`,
# verified against both yq flavors). Every value that is not the canonical lowercase
# spelling gets a warning, so nothing is ever skipped silently.
TRUE_SPELLINGS = ("true", "True", "TRUE")
FALSE_SPELLINGS = ("false", "False", "FALSE")
# BaseLoader does not resolve scalars, so a null arrives as one of these strings
NULL_SPELLINGS = ("", "~", "null", "Null", "NULL")

MASKED = "*MASKED*"
# What shlex.quote() considers safe, i.e. what pyinfra's QuoteString leaves unquoted.
_UNSAFE_RE = re.compile(r"[^\w@%+=:,./-]")

# How a task receives its stdin. `/dev/null` is what pyinfra's local connector gives
# every command; the CLI passes its own stdin only for `--interactive`.
STDIN_NULL = "devnull"
STDIN_INHERIT = "inherit"


class ConfigError(Exception):
    """A machine-config.yml problem: bad file, bad shape, missing script."""


def warning(message: str) -> str:
    """The canonical `-->` warning line; the text is the contract, reused verbatim."""
    return f"--> WARNING: {message}"


def note(message: str) -> str:
    """The canonical `--> note:` line for the things that are not warnings."""
    return f"--> note: {message}"


def warn(message: str) -> None:
    """Print a config warning in pyinfra's own `-->` style, on stderr."""
    print(warning(message), file=sys.stderr)


def is_null(value: Any) -> bool:
    """True when a BaseLoader scalar means 'no value' (`key:` with nothing under it)."""
    return value is None or value in NULL_SPELLINGS


def strip_venv_from_environ(environ: dict[str, str]) -> dict[str, str]:
    """Drop the project venv from a task's environment, in place.

    `uv run` activates the project venv; task scripts must see the system
    python3/pip. pyinfra's @local connector subprocesses inherit this environment,
    so deploy.py applies it to `os.environ` once; the CLI applies it to the child
    environment it builds. Same result for the script, which is what parity means.
    """
    environ.pop("VIRTUAL_ENV", None)
    if "PATH" in environ:
        env_bin = f"{sys.prefix}/bin"
        environ["PATH"] = os.pathsep.join(p for p in environ["PATH"].split(os.pathsep) if p != env_bin)
    return environ


def _export_bit(key: str, value: str) -> str:
    """One `export` pair, quoted the way pyinfra quotes it (its QuoteString == shlex.quote)."""
    pair = f"{key}={value}"
    return pair if _UNSAFE_RE.search(pair) is None else shlex.quote(pair)


def is_enabled(name: str, entry: dict, *, warn: Callable[[str], None] = warn) -> bool:
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


def task_command(name: str, config: Config, *, warn: Callable[[str], None] = warn) -> list[str]:
    """Resolve the config key `name` to the command that runs it.

    `tasks/<name>.sh` is the entry point for every shell task and takes precedence when
    both spellings exist (a `.py` of the same name is that script's helper, not a second
    entry point) — the operator is told which one wins. A `.py` entry point runs under
    *this* run's interpreter, `sys.executable`, so its imports resolve against the
    project venv that `uv run` created (`pyyaml` is a project dependency) instead of the
    host's system python: a fresh VM has no `python3-yaml`, and `apply` must work there.
    Neither spelling existing is a hard error naming the script, so `status` catches the
    typo instead of `apply` failing after ten installed services.
    """
    tasks = config.root / "tasks"
    sh = tasks / f"{name}.sh"
    py = tasks / f"{name}.py"
    if sh.is_file():
        if py.is_file():
            warn(f"{name}: tasks/{name}.sh and tasks/{name}.py both exist; running the .sh")
        return ["bash", str(sh)]
    if py.is_file():
        return [sys.executable, str(py)]
    raise ConfigError(
        f"{config.path}: script {name}: no tasks/{name}.sh or tasks/{name}.py — the config key "
        f"must match a file in {tasks}/"
    )


def check_shape(name: str, entry: Any, config: Config) -> dict:
    """Validate the *shape* of one `.scripts.<name>` entry; raise ConfigError naming it.

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
        raise ConfigError(
            f"{config.path}: script {name}: expected a mapping of enabled/env/args, "
            f"got {type(entry).__name__}: {entry!r}"
        )
    return entry


def check_values(
    name: str, entry: dict, strict: bool, config: Config, *, warn: Callable[[str], None] = warn
) -> None:
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
            raise ConfigError(f"{config.path}: script {name}: {message}")
        warn(f"{name}: {message} (disabled, not run)")

    env = entry.get("env")
    if not is_null(env) and (
        not isinstance(env, dict)
        or any(not isinstance(k, str) or not isinstance(v, str) for k, v in env.items())
    ):
        message = f"`env` must be a mapping of strings, got {env!r}"
        if strict:
            raise ConfigError(f"{config.path}: script {name}: {message}")
        warn(f"{name}: {message} (disabled, not run)")


@dataclass(frozen=True)
class Config:
    """A parsed `machine-config.yml` and the checkout its scripts live in."""

    path: Path
    root: Path
    scripts: tuple[tuple[str, Any], ...] = ()

    @property
    def names(self) -> list[str]:
        return [name for name, _ in self.scripts]

    def entry(self, name: str) -> dict:
        for key, raw in self.scripts:
            if key == name:
                return check_shape(name, raw, self)
        raise KeyError(name)


def load_config(path: Path, root: Path) -> Config:
    """Read and validate the *top level* of `path`; raise ConfigError with one line."""
    try:
        raw = path.read_text()
    except OSError as e:
        # missing file: point at the example / --config override instead of a generic error
        hint = ""
        if path == root / "machine-config.yml" and (root / "machine-config.yml.example").is_file():
            hint = ". copy machine-config.yml.example there, or pass --config <file>"
        detail = "the file does not exist" if isinstance(e, FileNotFoundError) else f"{type(e).__name__}: {e}"
        raise ConfigError(f"{path}: cannot read config — {detail}{hint}") from e
    try:
        # BaseLoader keeps every scalar a string, exactly as written (true stays "true")
        doc = yaml.load(raw, Loader=yaml.BaseLoader)
    except yaml.YAMLError as e:
        # unparsable YAML: one line naming the file, not a traceback
        msg = " ".join(f"{type(e).__name__}: {e}".split())
        raise ConfigError(f"{path}: cannot parse the config ({msg})") from e

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
        raise ConfigError(f"{path}: expected `.scripts` to map script name to entry; {problem}")
    return Config(path=path, root=root, scripts=tuple(doc["scripts"].items()))


@dataclass
class Task:
    """Everything one task script run means. The contract, in data form.

    `command` is exactly what pyinfra is handed today; `env` is exactly what pyinfra
    is handed today (plus what the ambient environment contributes, which is the same
    in both paths); `stdin` is what the child's fd 0 is. A conformance test asserts
    the CLI run and the pyinfra run agree on all three (R-ARCH-102).
    """

    name: str
    argv: list[str]
    env: dict[str, str]
    description: str = ""
    args: list[str] = field(default_factory=list)
    stdin: str = STDIN_NULL
    # keys whose value must never be echoed (config `env:`, not INTERACTIVE)
    secrets: frozenset[str] = frozenset()

    @property
    def command(self) -> str:
        """The command string pyinfra executes, with pyinfra's `/dev/null` redirect."""
        return shlex.join(self.argv) + (" </dev/null" if self.stdin == STDIN_NULL else "")

    @property
    def env_masked(self) -> dict[str, str]:
        return {k: (MASKED if k in self.secrets else v) for k, v in self.env.items()}

    def echo(self) -> str:
        """The command line as pyinfra's `-vvv` echoes it: exports, masked values.

        Mirrors `pyinfra.connectors.util.make_unix_command`: `export k=v ... && cmd`,
        each pair shlex-quoted when it is not shell-safe, secret values as `*MASKED*`.
        """
        if not self.env:
            return self.command
        bits = " ".join(_export_bit(k, MASKED if k in self.secrets else v) for k, v in self.env.items())
        return f"export {bits} && {self.command}"


def build_task(name: str, entry: dict, config: Config, *, warn: Callable[[str], None] = warn) -> Task:
    """The command + env for one config entry. Parity-critical; keep it total.

    Config env is applied after `INTERACTIVE` so a per-script `INTERACTIVE: 'true'` still
    wins, exactly as deploy.py did. Shape/value validation is the caller's job
    (`build_plan()` does it once per entry, strict only for an entry that runs).
    """
    args = [a for a in (entry.get("args") or [])]
    env_config = {k: v for k, v in (entry.get("env") or {}).items()}
    return Task(
        name=name,
        argv=[*task_command(name, config, warn=warn), *args],
        env={"INTERACTIVE": "false", **env_config},
        description=str(entry.get("description") or ""),
        args=args,
        secrets=frozenset(env_config),
    )


@dataclass
class PlanItem:
    """One config key of the plan, with the run it would be (None = not run)."""

    name: str
    enabled: bool
    description: str = ""
    entry: dict = field(default_factory=dict)
    args: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    task: Task | None = None

    @property
    def command(self) -> str:
        return self.task.command if self.task else ""


@dataclass
class Plan:
    """The ordered, validated result of reading a config — what `apply` would run."""

    config: Config
    items: list[PlanItem] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def enabled(self) -> list[PlanItem]:
        return [i for i in self.items if i.enabled]


def build_plan(config: Config, *, warn: Callable[[str], None] = warn) -> Plan:
    """Read every `.scripts` entry in config order and validate it.

    `warn` receives the raw message (no `-->` prefix) for each problem; the default
    prints it in pyinfra's style, so `deploy.py` keeps its current stderr. Warnings are
    emitted *while walking* the entries and the first hard error aborts the walk — the
    exact order a script's `enabled:` warning has before a later script's `env:` typo.
    A disabled entry is never resolved against `tasks/`, so `status` on a config with a
    stale disabled key still works.
    """
    plan = Plan(config=config)

    def note_warning(message: str) -> None:
        plan.warnings.append(message)
        warn(message)

    for name, raw in config.scripts:
        entry = check_shape(name, raw, config)
        enabled = is_enabled(name, entry, warn=note_warning)
        check_values(name, entry, strict=enabled, config=config, warn=note_warning)
        args = [a for a in (entry.get("args") or [])]
        env = {k: v for k, v in (entry.get("env") or {}).items()}
        task = build_task(name, entry, config, warn=note_warning) if enabled else None
        plan.items.append(
            PlanItem(
                name=name,
                enabled=enabled,
                description=str(entry.get("description") or ""),
                entry=entry,
                args=args,
                env=env,
                task=task,
            )
        )
    return plan


def iter_enabled(config: Config) -> Iterator[Task]:
    """The tasks deploy.py runs today: enabled entries, in config order."""
    for item in build_plan(config).enabled:
        assert item.task is not None  # enabled items always resolve
        yield item.task


def pyinfra_env(task: Task, hidden: Callable[[str], Any]) -> dict[str, Any]:
    """The `_env` dict for one task: config values wrapped as pyinfra secrets.

    Lives here so the adapter cannot invent its own masking rule: `INTERACTIVE` is
    echoed plainly, everything from `env:` is masked, in both paths.
    """
    return {k: (hidden(v) if k in task.secrets else v) for k, v in task.env.items()}
