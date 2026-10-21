"""The `kwisatz` command line: one command table, argparse built from it, exit codes.

The command table below is the single source of truth (R-CMD-001): `--help`,
`kwisatz commands --json` and the dispatcher all read it, so a flag cannot exist in one
and not the others. Keep `errors.EXIT_CODES` in sync — the codes are published with the
table, because that is what agents branch on.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import checks
from . import exec as runner
from . import jsonio, orchestrator, plan as planner, repo as repoio, state
from .errors import EXIT_CODES, CliError, Exit, usage
from .output import Out
from .repo import Repo

from . import __version__


@dataclass(frozen=True)
class Flag:
    flags: tuple[str, ...]
    help: str
    metavar: str | None = None
    default: object = None

    def names(self) -> list[str]:
        return list(self.flags)


@dataclass(frozen=True)
class CommandSpec:
    name: str
    summary: str
    detail: str = ""
    args: tuple[tuple[str, str], ...] = ()
    flags: tuple[Flag, ...] = ()
    mutates: bool = False
    milestone: str = "M1"

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "summary": self.summary,
            "mutates": self.mutates,
            "milestone": self.milestone,
            "args": [{"name": n, "help": h} for n, h in self.args],
            "flags": [{"flags": list(f.flags), "help": f.help, "value": f.metavar} for f in self.flags],
        }


GLOBAL_FLAGS: tuple[Flag, ...] = (
    Flag(("-c", "--config"), "read machine-config.yml from <file>", "<file>"),
    Flag(("-C", "--repo"), "operate on the kwisatz checkout at <dir>", "<dir>"),
    Flag(("-n", "--dry-run"), "print the plan the run would have executed; mutate nothing"),
    Flag(("-y", "--yes"), "assume yes wherever a command would otherwise prompt"),
    Flag(("--interactive",), "allow the task script to prompt (needs a terminal)"),
    Flag(("--json",), "one JSON document on stdout, progress on stderr"),
    Flag(("-q", "--quiet"), "suppress progress output"),
    Flag(("-v", "--verbose"), "raise verbosity (repeatable)"),
    Flag(("--no-color",), "never emit ANSI colour"),
    Flag(("--env",), "set KEY=VALUE for the task run, wins over config env", "<KEY=VALUE>"),
    Flag(("--timeout",), "wall-clock budget for the whole command", "<s>", 3600),
    Flag(("--lock-timeout",), "how long to wait for another kwisatz run", "<s>", 0),
    Flag(("--reveal",), "print env values unmasked (and say so)"),
)

COMMANDS: tuple[CommandSpec, ...] = (
    CommandSpec(
        "install",
        "make `kwisatz` available on PATH for this user",
        "syncs the project venv, writes ~/.local/bin/kwisatz and the config file that records "
        "the checkout. uv must already be installed (it prints the command if not). Use -C to "
        "install a checkout that is not the running one.",
        mutates=True,
    ),
    CommandSpec(
        "init",
        "first run: create machine-config.yml and run doctor",
        "copies machine-config.yml.example (or the inference example) and never enables more "
        "services than the example does",
        flags=(
            Flag(("--from-example",), "base | inference", "<which>"),
            Flag(("--force",), "overwrite an existing machine-config.yml"),
        ),
        mutates=True,
    ),
    CommandSpec(
        "apply",
        "run one, several, or every enabled target",
        "no target = every enabled script in config order, stopping at the first failure. A named "
        "target runs exactly the command a full apply would run for it — same env, same args, "
        "even when it is disabled in the config or has no entry at all.",
        args=(("[TARGET]…", "target names; `traefik` resolves `setup-traefik`"),),
        mutates=True,
    ),
    CommandSpec(
        "status",
        "show the plan without running anything",
        "the ordered enabled plan: index, target, description, resolved command with masked env",
    ),
    CommandSpec(
        "list",
        "every target kwisatz knows about",
        "config keys and tasks/* together, with kind, enabled state and description",
        flags=(Flag(("--all",), "include disabled and unconfigured targets"),),
    ),
    CommandSpec(
        "info",
        "everything about one target",
        "resolved script, config state, args, env keys, the script's own --help, the ordering "
        "rules that apply, and the last apply record",
        args=(("TARGET", "the target to describe"),),
    ),
    CommandSpec(
        "doctor",
        "is this box ready",
        "OS, sudo, uv, python, docker, GPU, free disk, plus the ordering and host facts of §6.5",
    ),
    CommandSpec(
        "commands",
        "the CLI itself, as data",
        "command, flag and exit-code table — the agent's discovery path, no README required",
    ),
)

BY_NAME = {c.name: c for c in COMMANDS}
HANDLERS = {
    "apply": "cmd_apply",
    "status": "cmd_status",
    "list": "cmd_list",
    "info": "cmd_info",
    "doctor": "cmd_doctor",
    "commands": "cmd_commands",
    "install": "cmd_install",
    "init": "cmd_init",
}


@dataclass
class App:
    """One command run: the flags, the output policy, the resolved repo and config."""

    args: argparse.Namespace
    out: Out
    repo: Repo | None = None
    config: orchestrator.Config | None = None
    plan: planner.Plan | None = None
    warnings: list[str] = field(default_factory=list)
    warnings_shown: bool = False
    result: dict = field(default_factory=dict)
    errors: list[dict] = field(default_factory=list)

    # ── resolution ───────────────────────────────────────────────────────────
    def repo_dir(self) -> Repo:
        if self.repo is None:
            self.repo = repoio.resolve_repo(getattr(self.args, "repo", None))
        return self.repo

    def load_plan(self) -> tuple[Repo, orchestrator.Config, planner.Plan]:
        """Repo + config + validated plan, once per run. ConfigError → exit 3."""
        repo = self.repo_dir()
        if self.plan is None:
            path = repoio.resolve_config(repo, getattr(self.args, "config", None))
            try:
                config = orchestrator.load_config(path, repo.path)
            except orchestrator.ConfigError as e:
                raise CliError(
                    Exit.CONFIG,
                    str(e),
                    hint="kwisatz init writes machine-config.yml from the shipped example",
                ) from e
            self.plan = orchestrator.build_plan(config, warn=self.warnings.append)
            self.config = config
        return repo, self.config, self.plan  # type: ignore[return-value]

    # ── output ───────────────────────────────────────────────────────────────
    def warn(self, message: str) -> None:
        self.warnings.append(message)

    def fail(self, code: int, message: str, *, target: str | None = None, hint: str | None = None) -> None:
        """Record an error, and print it now if we are not in JSON mode."""
        entry = {"message": message, "exit_code": code}
        if target:
            entry["target"] = target
        if hint:
            entry["hint"] = hint
        entry["_shown"] = False
        self.errors.append(entry)
        if not self.out.json:
            self.out.error(message)
            if hint:
                self.out.note(f"next: {hint}")
            entry["_shown"] = True

    def timed_out_code(self) -> int:
        return Exit.HEALTH


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── commands ────────────────────────────────────────────────────────────────────


def cmd_apply(app: App) -> int:
    """§6.1 + §6.2: the whole config, or exactly the targets named."""
    repo, config, pl = app.load_plan()
    wanted = list(getattr(app.args, "targets", None) or [])
    if wanted:
        targets = planner.order_targets([planner.resolve_target(n, config, pl) for n in wanted], config)
    else:
        all_targets = list(planner.targets_from_plan(config, pl).values())
        targets = planner.order_targets([t for t in all_targets if t.enabled], config)

    table = checks.load_prerequisites()
    app.warnings.extend(planner.check_prerequisite_order(targets, config, table["requires"]))
    app.warnings.extend(checks.fact_advisories(targets, table))

    for target in targets:
        if not target.configured:
            # R-APP-020: the ad-hoc path is the point of `apply <target>`
            app.warn(
                f"'{target.name}' is not in {config.path.name} — running with script defaults. "
                f"kwisatz config enable {target.name} would keep it in a full apply"
            )
        elif target.task is None:
            app.warn(
                f"'{target.name}' is disabled in {config.path.name} — running it anyway. "
                f"kwisatz config enable {target.name} keeps it in a full apply"
            )
            target.task = orchestrator.build_task(target.name, config.entry(target.name), config)
        if target.task is not None:
            target.env = dict(target.task.env)

    if getattr(app.args, "dry_run", False):
        app.result = {"plan": len(targets), "ran": 0, "dry_run": True, "items": planner.plan_items(targets)}
        if not app.out.json:
            app.out.action("dry run — nothing will be executed")
            planner.print_plan(app.out, targets)
        return Exit.OK

    interactive = getattr(app.args, "interactive", False)
    if interactive and not sys.stdin.isatty():
        raise CliError(Exit.PREREQUISITE, "--interactive requires a terminal", hint="run without --interactive")

    for message in app.warnings:
        app.out.warning(message)
    app.warnings_shown = True

    repo.ensure_work()
    lock = repoio.Lock(repo, float(getattr(app.args, "lock_timeout", 0) or 0))
    lock.acquire()
    try:
        return _run_targets(app, targets, repo)
    finally:
        lock.release()


def _run_targets(app: App, targets: list[planner.Target], repo: Repo) -> int:
    extra = _env_overrides(app)
    timeout = float(getattr(app.args, "timeout", 3600) or 3600)
    interactive = bool(getattr(app.args, "interactive", False))
    started_at = now_iso()
    started = time.monotonic()
    items: list[dict] = []
    total = len(targets)
    failed = 0

    for index, target in enumerate(targets, 1):
        if target.task is None:  # a disabled entry with nothing runnable behind it
            raise CliError(
                Exit.CONFIG,
                f"{config_of(app)}: script {target.name}: nothing to run",
                target=target.name,
                hint=f"kwisatz info {target.name}",
            )
        header = f"[{index}/{total}] {target.name}" + (f" — {target.description}" if target.description else "")
        app.out.progress(header)
        app.out.action(f"running {target.name}")
        log = repo.logs / f"kwisatz-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}-{target.name}.log"
        outcome = runner.run_task(
            target.task,
            root=repo.path,
            interactive=interactive,
            extra_env=extra,
            log_path=log,
            timeout=timeout,
            echo_stdout=not app.out.json,
            heartbeat=3.0,
            on_heartbeat=lambda elapsed, pid, name=target.name: app.out.progress(
                f"  … {name} still running {elapsed}s · pid {pid}"
            ),
        )
        item: dict = {
            "target": target.name,
            "index": index,
            "status": "applied",
            "exit_code": 0,
            "duration_ms": outcome.duration_ms,
            "command": target.task.command,
            "env": jsonio.mask_env({**target.task.env, **extra}, reveal=_reveal(app)),
            "stdout_tail": outcome.stdout_tail,
            "log_path": outcome.log_path,
        }
        if outcome.timed_out:
            item["status"] = "failed"
            item["exit_code"] = None
            failed += 1
            app.fail(
                Exit.HEALTH,
                f"{target.name} timed out after {int(timeout)}s",
                target=target.name,
                hint=f"kwisatz apply {target.name} --timeout <s> · kwisatz logs {target.name}",
            )
        elif outcome.returncode == 0:
            app.out.ok(f"{target.name} · {outcome.duration_ms // 1000}s")
        else:
            item["status"] = "failed"
            item["exit_code"] = outcome.returncode
            failed += 1
            app.fail(
                Exit.TASK_FAILED,
                f"{target.name} exited {outcome.returncode}",
                target=target.name,
                hint=f"kwisatz apply {target.name}  (retry this one target only)",
            )
        items.append(item)
        if failed:
            app.out.warning(f"stopping — the remaining {total - index} script(s) did not run")
            break

    for rest in targets[len(items) :]:
        items.append({"target": rest.name, "index": len(items) + 1, "status": "not-run", "exit_code": None})

    app.result = {
        "plan": total,
        "ran": sum(1 for i in items if i["status"] != "not-run"),
        "ok": sum(1 for i in items if i["status"] == "applied"),
        "failed": failed,
        "skipped": sum(1 for i in items if i["status"] == "not-run"),
        "items": items,
    }
    _summary(app, items)
    state.record(
        repo,
        {
            "command": "apply",
            "started_at": started_at,
            "duration_ms": int((time.monotonic() - started) * 1000),
            "repo": repoio.repo_dict(repo),
            "config": str(app.config.path) if app.config else "",
            "exit_code": Exit.TASK_FAILED if failed else Exit.OK,
            "items": [{k: i[k] for k in ("target", "status", "exit_code", "duration_ms")} for i in items],
        },
    )
    if app.out.json:
        return Exit.TASK_FAILED if failed else Exit.OK
    return Exit.TASK_FAILED if failed else Exit.OK


def _summary(app: App, items: list[dict]) -> None:
    """R-OUT-007: target · outcome · duration · next step."""
    if app.out.json:
        return
    app.out.result("")
    app.out.result("Summary")
    for item in items:
        duration = f"{item.get('duration_ms', 0) // 1000} s" if item.get("duration_ms") else "—"
        app.out.result(f"  {item['target']:<28} {item['status']:<10} {duration}")
    if not any(i["status"] == "failed" for i in items):
        app.out.result("→ next: kwisatz status   ·   kwisatz list --all")


def config_of(app: App) -> str:
    return str(app.config.path) if app.config else "machine-config.yml"


def cmd_status(app: App) -> int:
    """§6.3: a read-only superset of `run-setup.sh status`. Never runs a script."""
    _, config, pl = app.load_plan()
    targets = planner.order_targets(list(planner.targets_from_plan(config, pl).values()), config)
    enabled = [t for t in targets if t.enabled]
    disabled = [t for t in targets if not t.enabled]

    app.result = {
        "plan": len(enabled),
        "ran": 0,
        "items": planner.plan_items(enabled),
        "disabled": [{"target": t.name, "description": t.description} for t in disabled],
    }
    if not app.out.json:
        if not enabled:
            app.out.result("nothing is enabled — kwisatz list --all, then kwisatz config enable <target>")
        else:
            planner.print_plan(app.out, enabled)
            if disabled:
                app.out.note(f"{len(disabled)} disabled; kwisatz list --all")
    return Exit.OK


def cmd_list(app: App) -> int:
    _, config, pl = app.load_plan()
    known = planner.catalog(config, pl)
    shown = known if getattr(app.args, "all", False) else [t for t in known if t.enabled]
    app.result = {
        "count": len(shown),
        "total": len(known),
        "items": [
            {
                "target": t.name,
                "kind": t.kind,
                "enabled": t.enabled,
                "configured": t.configured,
                "description": t.description,
                "script": t.script,
                "env": jsonio.mask_env(t.env, reveal=_reveal(app)),
            }
            for t in shown
        ],
    }
    if app.out.json:
        return Exit.OK
    app.out.result(f"{'TARGET':<36} {'KIND':<5} {'STATE':<14} DESCRIPTION")
    for target in shown:
        state_str = "enabled" if target.enabled else ("disabled" if target.configured else "unconfigured")
        app.out.result(f"{target.name:<36} {target.kind or '-':<5} {state_str:<14} {target.description}")
    if not getattr(app.args, "all", False) and len(shown) < len(known):
        app.out.note(f"{len(known) - len(shown)} more; kwisatz list --all")
    return Exit.OK


def cmd_info(app: App) -> int:
    repo, config, pl = app.load_plan()
    target = planner.resolve_target(app.args.target, config, pl)
    script = Path(target.script) if target.script else None
    table = checks.load_prerequisites()
    prerequisites = planner.check_prerequisite_order([target], config, table["requires"])
    prerequisites += checks.fact_advisories([target], table)
    help_excerpt = _help_of(script) if script and script.is_file() else ""

    app.result = {
        "target": target.name,
        "script": str(script) if script else None,
        "kind": target.kind,
        "in_config": target.configured,
        "enabled": target.enabled,
        "description": target.description,
        "args": target.args,
        "env": jsonio.mask_env(target.env, reveal=_reveal(app)),
        "config": str(config.path),
        "prerequisites": prerequisites,
        "help_excerpt": help_excerpt,
        "last_apply": (state.read(repo, target.name, 1) or [{}])[0],
    }
    if not app.out.json:
        app.out.result(target.name)
        app.out.result(f"  script     {script}")
        app.out.result(
            f"  config     {'enabled' if target.enabled else 'disabled'}"
            if target.configured
            else f"  config     not in {config.path.name}"
        )
        app.out.result(f"  description {target.description or '(none)'}")
        app.out.result(f"  args       {' '.join(target.args) if target.args else '(none)'}")
        app.out.result(f"  env keys   {', '.join(target.env) if target.env else '(none)'}")
        if app.result["last_apply"]:
            app.out.result(f"  last apply {json.dumps(app.result['last_apply'], sort_keys=True)}")
        for message in prerequisites:
            app.out.warning(message)
        if help_excerpt:
            app.out.result("")
            for line in help_excerpt.splitlines():
                app.out.result(f"  {line}")
    return Exit.OK


def cmd_doctor(app: App) -> int:
    repo = app.repo_dir()
    table = checks.load_prerequisites()
    found = checks.checks()
    missing = [c.name for c in found if c.required and not c.ok]
    app.result = {
        "checks": [c.as_dict() for c in found],
        "prerequisites": table,
        "ok": not missing,
        "missing": missing,
    }
    app.out.progress(f"kwisatz {__version__} · repo {repo.path} ({repo.branch or 'no branch'} {repo.git_sha})")
    for check in found:
        detail = f"{check.name}: {check.detail}" if check.detail else check.name
        if check.ok:
            app.out.ok(detail)
        elif check.required:
            app.out.error(f"{detail} — {check.hint}")
        else:
            app.out.warning(f"{detail} — {check.hint}")
    if not app.out.json and missing:
        app.out.note("kwisatz doctor --json lists every check")
    return Exit.PREREQUISITE if missing else Exit.OK


def cmd_commands(app: App) -> int:
    app.result = {
        "version": __version__,
        "commands": [c.as_dict() for c in COMMANDS],
        "global_flags": [{"flags": list(f.flags), "help": f.help, "value": f.metavar} for f in GLOBAL_FLAGS],
        "exit_codes": EXIT_CODES,
    }
    if not app.out.json:
        app.out.result("kwisatz — commands")
        width = max(len(c.name) for c in COMMANDS)
        for spec in COMMANDS:
            app.out.result(f"  kwisatz {spec.name:<{width}}  {spec.summary}")
        app.out.result("")
        app.out.result("exit codes: " + "  ".join(f"{code}={name.split()[0]}" for code, name in EXIT_CODES.items()))
    return Exit.OK


def cmd_install(app: App) -> int:
    """R-INS-001: put `kwisatz` on PATH for this user, and touch nothing else."""
    repo = app.repo_dir()
    if shutil.which("uv") is None:
        raise CliError(
            Exit.PREREQUISITE,
            "uv is not installed",
            hint="curl -LsSf https://astral.sh/uv/install.sh | sh   then kwisatz install",
        )
    app.out.action(f"syncing the project venv in {repo.path}")
    sync = subprocess.run(
        ["uv", "sync", "--project", str(repo.path)], capture_output=True, text=True, timeout=900, check=False
    )
    if sync.returncode != 0:
        detail = (sync.stderr or sync.stdout or "").strip().splitlines()
        raise CliError(
            Exit.PREREQUISITE,
            f"uv sync failed (exit {sync.returncode}): {detail[-1] if detail else 'no output'}",
            hint=f"uv sync --project {repo.path}",
        )

    launcher = Path.home() / ".local" / "bin" / "kwisatz"
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text(
        "#!/bin/sh\n"
        f"# kwisatz {__version__} — rewrite this with `kwisatz install --repo <path>` "
        "if the checkout moves\n"
        f"exec uv run --project {repo.path} kwisatz \"$@\"\n"
    )
    launcher.chmod(0o755)
    repoio.CONFIG_JSON.parent.mkdir(parents=True, exist_ok=True)
    repoio.CONFIG_JSON.write_text(json.dumps({"repo": str(repo.path), "version": __version__}, indent=2) + "\n")

    app.result = {"launcher": str(launcher), "repo": str(repo.path), "config": str(repoio.CONFIG_JSON)}
    if not app.out.json:
        app.out.ok(f"kwisatz is on PATH at {launcher}")
        app.out.result("next: kwisatz init   then   kwisatz status")
    return Exit.OK


def cmd_init(app: App) -> int:
    """R-INS-004: ensure a config file exists, then say what this box is missing."""
    repo = app.repo_dir()
    target = repoio.resolve_config(repo, getattr(app.args, "config", None))
    which = getattr(app.args, "from_example", None) or "base"
    source = repo.path / (
        "machine-config-inference.yml.example" if which == "inference" else "machine-config.yml.example"
    )
    if not source.is_file():
        raise CliError(Exit.CONFIG, f"{source}: the example config is missing", hint=f"repo {repo.path}")

    created = False
    if target.exists() and not getattr(app.args, "force", False):
        app.out.note(f"{target} already exists — left untouched (use --force to overwrite)")
    elif getattr(app.args, "dry_run", False):
        app.out.action(f"dry run — would write {target} from {source.name}")
    else:
        target.write_text(source.read_text())
        created = True
        app.out.ok(f"wrote {target} (from {source.name})")

    app.result = {"config": str(target), "created": created, "source": str(source)}
    doctor_code = cmd_doctor(app)  # app.result is replaced: doctor is the last word
    app.result.update({"created": created, "config": str(target), "source": str(source)})
    app.result["doctor_exit_code"] = doctor_code
    if doctor_code == Exit.PREREQUISITE:
        app.out.warning("prerequisites are missing — fix them before kwisatz apply")
    app.out.result("next: kwisatz status   ·   kwisatz list --all   ·   kwisatz apply")
    return Exit.OK


def cmd_version(app: App) -> int:
    repo = None
    try:
        repo = app.repo_dir()
    except CliError:  # --version answers anywhere
        pass
    app.result = {
        "version": __version__,
        "repo": str(repo.path) if repo else None,
        "git_sha": repo.git_sha if repo else "",
        "branch": repo.branch if repo else "",
    }
    tail = f" · {repo.path} ({repo.branch}, {repo.git_sha})" if repo and repo.git_sha else ""
    app.out.result(f"kwisatz {__version__}{tail}")
    return Exit.OK


# ── helpers ─────────────────────────────────────────────────────────────────────


def _env_overrides(app: App) -> dict[str, str]:
    out: dict[str, str] = {}
    for item in getattr(app.args, "env", None) or []:
        if "=" not in item:
            raise usage(f"--env expects KEY=VALUE, got {item!r}", hint="kwisatz apply --env KEY=VALUE")
        key, _, value = item.partition("=")
        out[key] = value
    return out


def _reveal(app: App) -> bool:
    if getattr(app.args, "reveal", False):
        app.out.warning("--reveal prints env values as configured; keep secrets in /srv/<service>/.env")
        return True
    return False


def _help_of(script: Path) -> str:
    """The script's own `--help`, never the CLI's guess (R-AGE-003)."""
    argv = {".sh": ["bash"], ".py": [sys.executable]}.get(script.suffix)
    if argv is None:
        return ""
    argv = [*argv, str(script), "--help"]
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=15, check=False, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (done.stdout or done.stderr) if done.returncode == 0 else ""


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="kwisatz",
        description="kwisatz — one command for the whole machine, or just one service.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="run `kwisatz` with no command for the command map",
    )
    parser.add_argument("--version", action="store_true", help="print version and repo SHA, exit 0")
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    for spec in COMMANDS:
        p = sub.add_parser(
            spec.name,
            help=spec.summary,
            description=(spec.detail or spec.summary) + "\n\n" + _flags_help(spec),
            formatter_class=argparse.RawDescriptionHelpFormatter,
            add_help=False,
        )
        p.add_argument("-h", "--help", action="help", help="show this help message and exit")
        for flag in GLOBAL_FLAGS:
            names = flag.names()
            if flag.metavar:
                p.add_argument(*names, metavar=flag.metavar, default=flag.default, help=flag.help)
            elif names[0] in ("-v", "--verbose"):
                p.add_argument(*names, action="count", default=0, help=flag.help)
            elif isinstance(flag.default, list):
                p.add_argument(*names, action="append", default=[], help=flag.help)
            else:
                p.add_argument(*names, action="store_true", default=False, help=flag.help)
        for name, help_text in spec.args:
            if name.startswith("["):
                p.add_argument("targets", nargs="*", help=help_text)
            else:
                p.add_argument("target", help=help_text)
        for flag in spec.flags:
            if flag.metavar:
                p.add_argument(*flag.names(), metavar=flag.metavar, default=flag.default, help=flag.help)
            else:
                p.add_argument(*flag.names(), action="store_true", default=False, help=flag.help)
    return parser


def _flags_help(spec: CommandSpec) -> str:
    lines = ["options:"]
    for flag in [*GLOBAL_FLAGS, *spec.flags]:
        value = f" {flag.metavar}" if flag.metavar else ""
        lines.append(f"  {', '.join(flag.names()):<18}{value:<8} {flag.help}")
    return "\n".join(lines)


def _make_app(args: argparse.Namespace) -> App:
    if getattr(args, "json", False) and getattr(args, "interactive", False):
        raise usage("--json never prompts", hint="drop --json, or drop --interactive")
    if getattr(args, "dry_run", False) and getattr(args, "interactive", False):
        raise usage("--dry-run never runs a script, so --interactive is meaningless", hint="pick one")
    return App(
        args=args,
        out=Out(
            quiet=getattr(args, "quiet", False),
            verbose=bool(getattr(args, "verbose", 0)),
            json=getattr(args, "json", False),
            color=False if getattr(args, "no_color", False) else None,
        ),
    )


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    started = time.monotonic()
    parser = _build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:  # argparse already wrote usage to stderr
        return int(e.code if isinstance(e.code, int) else 2)

    if getattr(args, "version", False):
        app = _make_app(args)
        return _finish(app, cmd_version(app), started)

    command = getattr(args, "command", None)
    if command not in HANDLERS:
        return _no_command(argv)

    try:
        app = _make_app(args)
    except CliError as e:
        _print_error(e)
        return e.code

    handler = globals()[HANDLERS[command]]
    code = Exit.OK
    try:
        code = handler(app)
    except CliError as e:
        app.errors.append({**e.error(), "_shown": False})
        code = e.code
    except KeyboardInterrupt:  # pragma: no cover
        app.errors.append({"message": "interrupted", "exit_code": Exit.TASK_FAILED, "_shown": False})
        code = Exit.TASK_FAILED
    return _finish(app, code, started)


def _no_command(argv: list[str]) -> int:
    first = next((a for a in argv if not a.startswith("-")), None)
    if first is None:  # bare `kwisatz`: the command map, then exit 2 (R-CMD-003)
        app = App(args=argparse.Namespace(), out=Out())
        cmd_commands(app)
        return Exit.USAGE
    closest = planner.similar(first, list(HANDLERS), 1)
    print(f"kwisatz: unknown command {first!r}", file=sys.stderr)
    print(f"        try: kwisatz <{'|'.join(HANDLERS)}>", file=sys.stderr)
    if closest and closest[0] != first:
        print(f"  did you mean: kwisatz {closest[0]} ?", file=sys.stderr)
    return Exit.USAGE


def _print_error(error: CliError) -> None:
    print(f"--> ERROR: {error.message}", file=sys.stderr)
    if error.hint:
        print(f"--> note: {error.hint}", file=sys.stderr)


def _finish(app: App, code: int, started: float) -> int:
    """Exactly one JSON document when --json; otherwise the warnings/errors so far."""
    if app.out.json:
        doc = jsonio.envelope(
            command=getattr(app.args, "command", None) or "version",
            ok=code == Exit.OK,
            exit_code=code,
            started_at=now_iso(),
            duration_ms=int((time.monotonic() - started) * 1000),
            repo=repoio.repo_dict(app.repo) if app.repo else None,
            config={"path": str(app.config.path)} if app.config else None,
            result=app.result or None,
            warnings=app.warnings,
            errors=[{k: v for k, v in e.items() if not k.startswith("_")} for e in app.errors],
        )
        jsonio.emit(doc)
        return code

    if not app.warnings_shown:
        for message in app.warnings:
            app.out.warning(message)
    return code


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
