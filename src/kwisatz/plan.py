"""Target resolution and the catalog (§4, §6.2.1).

A *target* is anything the operator can point at: a config key, or — since
R-APP-020 — a script that has no config entry at all. Resolution is prefix-tolerant
because task scripts follow `setup-<component>.sh` / `configure-<component>.sh`
(`CONTEXT.md`), so `traefik`, `setup-traefik` and `configure-traefik` all mean the
same thing. Resolution never silently picks between two different scripts.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from . import jsonio, orchestrator
from .errors import Exit, config_error, usage
from .orchestrator import Config, Plan, Task

PREFIXES = ("setup-", "configure-")


@dataclass
class Target:
    """One thing `kwisatz apply` can run, and what it will do."""

    name: str
    #: `sh` / `py`, or `""` when there is no file to look at
    kind: str
    configured: bool
    enabled: bool
    description: str = ""
    args: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    task: Task | None = None

    @property
    def script(self) -> str:
        return next((a for a in (self.task.argv[1:] if self.task else [])), "")

    def echo(self) -> str:
        return self.task.echo() if self.task else ""


def canonical(name: str) -> str:
    """`setup-traefik`, `configure-traefik` and `traefik` are one target name."""
    for prefix in PREFIXES:
        if name.startswith(prefix):
            return name[len(prefix) :]
    return name


def task_files(root: Path) -> dict[str, Path]:
    """Every runnable entry point in `tasks/`, keyed by file stem (config order is N/A)."""
    tasks = root / "tasks"
    found: dict[str, Path] = {}
    if not tasks.is_dir():
        return found
    for path in sorted(tasks.glob("*.py")) + sorted(tasks.glob("*.sh")):
        found.setdefault(path.stem, path)
    # `.sh` wins, exactly as orchestrator.task_command() resolves it
    for stem in list(found):
        sh = tasks / f"{stem}.sh"
        if sh.is_file():
            found[stem] = sh
    return found


def targets_from_plan(config: Config, plan: Plan) -> dict[str, Target]:
    """The config keys: validated entries, with the task each one would run."""
    out: dict[str, Target] = {}
    for item in plan.items:
        kind = ""
        files = task_files(config.root)
        path = files.get(item.name)
        if path:
            kind = path.suffix.lstrip(".")
        out[item.name] = Target(
            name=item.name,
            kind=kind,
            configured=True,
            enabled=item.enabled,
            description=item.description,
            args=list(item.args),
            env=dict(item.env),
            task=item.task,
        )
    return out


def catalog(config: Config, plan: Plan) -> list[Target]:
    """The union of config keys and `tasks/*` — every name `apply` accepts."""
    targets = targets_from_plan(config, plan)
    for stem, path in task_files(config.root).items():
        if stem in targets:
            continue
        kind = path.suffix.lstrip(".")
        # a script with no config entry is runnable with the script's own defaults
        # a script with no config entry is runnable with the script's own defaults;
        # the `.sh`/`.py` precedence warning belongs to `apply`, not to a listing
        task = Task(
            name=stem,
            argv=orchestrator.task_command(stem, config, warn=lambda _m: None),
            env={"INTERACTIVE": "false"},
        )
        targets[stem] = Target(
            name=stem,
            kind=kind,
            configured=False,
            enabled=False,
            description="",
            env=dict(task.env),
            task=task,
        )
    return [targets[name] for name in sorted(targets)]


def _script_of(name: str, config: Config) -> Path | None:
    files = task_files(config.root)
    return files.get(name)


def resolve_target(name: str, config: Config, plan: Plan) -> Target:
    """One user-supplied name → the thing to run. Raises USAGE (ambiguous) or CONFIG."""
    targets = targets_from_plan(config, plan)
    names = list(targets)
    if name in targets:
        return targets[name]

    want = canonical(name)
    files = task_files(config.root)
    candidates: set[str] = set()
    for candidate in [*names, *files]:
        if canonical(candidate) == want:
            candidates.add(candidate)
    # two spellings of the *same* script (config key + file, or setup- + configure-)
    # are one target, not an ambiguity
    distinct = {_script_of(c, config) for c in candidates}
    if len(candidates) > 1 and len(distinct) > 1:
        raise usage(
            f"target {name!r} is ambiguous",
            hint="run one of: " + ", ".join(sorted(candidates)),
        )
    if candidates:
        (chosen,) = candidates
        if chosen in targets:
            return targets[chosen]
        return unconfigured_target(chosen, config)

    if name in files:
        return unconfigured_target(name, config)

    known = sorted(set(targets) | set(files))
    raise config_error(
        f"unknown target {name!r}: no config key and no tasks/{name}.sh or .py",
        hint="closest: " + ", ".join(similar(name, known, 5)),
        target=name,
    )


def unconfigured_target(name: str, config: Config, *, warn=orchestrator.warn) -> Target:
    """A script that is not in `machine-config.yml` (§6.2.3): ambient env, run anyway."""
    files = task_files(config.root)
    path = files.get(name)
    if path is None:
        raise config_error(
            f"target {name!r} has no tasks/{name}.sh or tasks/{name}.py",
            hint="kwisatz list shows every runnable target",
            target=name,
        )
    task = Task(
        name=name, argv=orchestrator.task_command(name, config, warn=warn), env={"INTERACTIVE": "false"}
    )
    return Target(
        name=name,
        kind=path.suffix.lstrip("."),
        configured=False,
        enabled=False,
        description="",
        env=dict(task.env),
        task=task,
    )


def order_targets(targets: list[Target], config: Config) -> list[Target]:
    """Config order for the configured ones, then the unconfigured ones as given (§6.3.4)."""
    order = {name: i for i, name in enumerate(config.names)}
    configured = sorted((t for t in targets if t.configured), key=lambda t: order[t.name])
    rest = [t for t in targets if not t.configured]
    # keep the user's order when nothing in the config ties them
    return configured + rest


def similar(word: str, names: list[str], count: int) -> list[str]:
    """The `did you mean …` list: closest first, ties broken alphabetically."""
    scored = sorted((_distance(word, n), n) for n in names)
    return [n for _, n in scored[:count]]


def _distance(a: str, b: str) -> int:
    if a == b:
        return 0
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        row = [i]
        for j, cb in enumerate(b, 1):
            row.append(min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = row
    return previous[-1]


def check_prerequisite_order(
    targets: list[Target], config: Config, rules: dict[str, list[str]]
) -> list[str]:
    """§6.5 advisory: a required predecessor must be enabled *and* earlier in the config.

    Never aborts; the task scripts are the implementation, this is the warning that
    stops `configure-firewall` before `setup-sshd` from being a silent lockout.
    """
    messages: list[str] = []
    order = {name: i for i, name in enumerate(config.names)}
    running = {t.name for t in targets}
    for target in targets:
        for needed in rules.get(target.name, []) + rules.get(canonical(target.name), []):
            entry = _entry_of(needed, config)
            if entry is None:
                messages.append(
                    f"{target.name}: expects {needed} first — it is not in machine-config.yml "
                    f"(kwisatz config enable {needed} && kwisatz apply {needed})"
                )
            elif needed not in running:
                messages.append(
                    f"{target.name}: expects {needed} to run first, but it is not enabled in this "
                    f"run (kwisatz apply {needed})"
                )
            elif order.get(needed, 0) > order.get(target.name, 0):
                messages.append(
                    f"{target.name}: expects {needed} earlier in machine-config.yml "
                    f"(lockout risk: reorder the two keys)"
                )
    return messages


def _entry_of(name: str, config: Config) -> dict | None:
    for key, raw in config.scripts:
        if key == name:
            return orchestrator.check_shape(name, raw, config)
    return None


def exit_for_script(code: int) -> int:
    """A task script's own codes (0/1/2 per conventions) onto §9."""
    return Exit.TASK_FAILED if code else Exit.OK


def plan_items(targets: list[Target], *, status: str = "planned") -> list[dict]:
    """The plan as data — the same `echo` the human view prints (values masked)."""
    return [
        {
            "target": t.name,
            "index": i,
            "status": status,
            "description": t.description,
            "command": t.task.command if t.task else "",
            "echo": t.echo(),
            "args": t.args,
            "env": jsonio.mask_env(t.env),
        }
        for i, t in enumerate(targets, 1)
    ]


def print_plan(out, targets: list[Target]) -> None:
    """The human plan view: `[i/n] name`, its description, the masked command line."""
    for item in plan_items(targets):
        out.result(f"[{item['index']}/{len(targets)}] {item['target']}")
        if item["description"]:
            out.result(f"    {item['description']}")
        if item["args"]:
            out.result(f"    args: {' '.join(item['args'])}")
        out.result(f"    {item['echo']}")
