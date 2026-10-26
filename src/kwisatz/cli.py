"""The `kwisatz` command line: one command table, argparse built from it, exit codes.

The command table below is the single source of truth (R-CMD-001): `--help`,
`kwisatz commands --json` and the dispatcher all read it, so a flag cannot exist in one
and not the others. Keep `errors.EXIT_CODES` in sync — the codes are published with the
table, because that is what agents branch on.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import __version__, checks, jsonio, orchestrator, state
from . import config as configio
from . import exec as runner
from . import logs as logsio
from . import plan as planner
from . import repo as repoio
from . import services as serviceio
from .errors import EXIT_CODES, CliError, Exit, config_error, usage
from .output import Out
from .repo import Repo


@dataclass(frozen=True)
class Flag:
    flags: tuple[str, ...]
    help: str
    metavar: str | None = None
    default: object = None
    #: repeatable option (`--env K=1 --env K=2`), which argparse cannot infer from the shape
    append: bool = False

    def names(self) -> list[str]:
        return list(self.flags)


@dataclass(frozen=True)
class CommandSpec:
    name: str
    summary: str
    detail: str = ""
    args: tuple[tuple[str, str], ...] = ()
    flags: tuple[Flag, ...] = ()
    #: nested verbs (`kwisatz config enable x`); nothing else may dispatch on a second word
    subcommands: tuple[CommandSpec, ...] = ()
    mutates: bool = False
    milestone: str = "M1"

    def as_dict(self) -> dict:
        out = {
            "name": self.name,
            "summary": self.summary,
            "mutates": self.mutates,
            "milestone": self.milestone,
            "args": [{"name": n, "help": h} for n, h in self.args],
            "flags": [{"flags": list(f.flags), "help": f.help, "value": f.metavar} for f in self.flags],
        }
        if self.subcommands:
            out["subcommands"] = [c.as_dict() for c in self.subcommands]
        return out

    def walk(self):
        """This command and every verb under it, for the dispatcher and `commands --json`."""
        yield self
        for sub in self.subcommands:
            yield from sub.walk()


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
    Flag(("--env",), "set KEY=VALUE for the task run, wins over config env", "<KEY=VALUE>", append=True),
    Flag(("--timeout",), "wall-clock budget for the whole command", "<s>", 3600),
    Flag(("--lock-timeout",), "how long to wait for another kwisatz run", "<s>", 0),
    Flag(("--reveal",), "print env values unmasked (and say so)"),
)

COMMANDS: tuple[CommandSpec, ...] = (
    CommandSpec(
        "install",
        "make `kwisatz` available on PATH for this user",
        "syncs the project venv, writes ~/.local/bin/kwisatz and the config file that records "
        "the checkout. uv must already be installed — kwisatz does not download and run an "
        "installer on its own, but `--with-uv <version>` will (pinned official installer, and "
        "only with `--yes`, because that command executes upstream code).",
        flags=(
            Flag(("--with-uv",), "install this pinned uv version first", "<x.y.z>"),
        ),
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
        flags=(
            Flag(("--keep-going",), "run every target, not only up to the first failure (exit 8)"),
            Flag(("--no-sudo-warmup",), "do not refresh the sudo ticket before a multi-target run"),
            Flag(("--events",), "NDJSON progress lines on stdout before the final document"),
        ),
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
    CommandSpec(
        "config",
        "inspect and edit machine-config.yml without an editor",
        "every mutation is a comment-preserving, order-preserving ruamel round-trip: `enable` on "
        "a file with 20 comments changes one line and leaves the rest byte-identical. Writes are "
        "atomic, mode 0600, and the old file goes to .kwisatz/config-backups (5 kept).",
        subcommands=(
            CommandSpec("show", "the whole config, or one entry", args=(("[TARGET]", "one target only"),)),
            CommandSpec("validate", "every config problem at once, before apply has to find them"),
            CommandSpec(
                "enable",
                "flip enabled: true, comments untouched",
                args=(("TARGET", "the target to enable"),),
                mutates=True,
            ),
            CommandSpec(
                "disable",
                "flip enabled: false, comments untouched",
                args=(("TARGET", "the target to disable"),),
                mutates=True,
            ),
            CommandSpec(
                "set",
                "write one env key, quoted so it reads back as a string",
                args=(("TARGET", "the target"), ("KEY=VALUE", "the value to write")),
                mutates=True,
            ),
            CommandSpec(
                "unset",
                "drop one env key",
                args=(("TARGET", "the target"), ("KEY", "the key to remove")),
                mutates=True,
            ),
            CommandSpec(
                "args",
                "replace the args a target runs with",
                args=(("TARGET", "the target"), ("[FLAG]\u2026", "the new args, verbatim")),
                mutates=True,
            ),
            CommandSpec("path", "the file every config command reads and writes"),
            CommandSpec(
                "init",
                "create machine-config.yml from a shipped example",
                flags=(Flag(("--from-example",), "base | inference", "<which>"),),
                mutates=True,
            ),
        ),
        mutates=True,
        milestone="M2",
    ),
    CommandSpec(
        "services",
        "what is running on this box right now",
        "from /srv/*/docker-compose.yml, the com.docker.compose labels on every container, and "
        "systemd units named after a task; the healthy signal is the one the task scripts use",
        milestone="M2",
    ),
    CommandSpec(
        "logs",
        "the logs of a target's stack, unit, or last apply",
        "compose logs for a docker stack, journalctl for a systemd unit, the newest stored apply "
        "log otherwise, chosen by what discovery found rather than by a guess",
        args=(("[TARGET]", "the target whose logs to read"),),
        flags=(
            Flag(("--tail",), "lines to print", "<n>", 200),
            Flag(("--since",), "only logs after this time (journal/compose)", "<10m>"),
            Flag(("-f", "--follow"), "keep streaming, bounded by --timeout"),
        ),
        milestone="M2",
    ),
    CommandSpec(
        "state",
        "what kwisatz applied last, and with what",
        "one record per run, written after the scripts exited so a crashed run cannot read as a "
        "success",
        args=(("[TARGET]", "only the runs that touched this target"),),
        milestone="M2",
    ),
    CommandSpec(
        "models",
        "the model catalog, through the tool that owns it",
        "a thin, honest wrapper over tasks/sync-models.py, which has no --dry-run: `models sync "
        "--dry-run` prints the command and changes nothing instead of inventing one",
        subcommands=(
            CommandSpec("sync", "run tasks/sync-models.py", mutates=True),
            CommandSpec("status", "catalog summary and llama-swap, without running anything"),
            CommandSpec("show", "the resolved catalog file and the models it defines"),
        ),
        mutates=True,
        milestone="M2",
    ),
    CommandSpec(
        "run",
        "run a task script with arguments the CLI never parses",
        # the `--` rule sits here because it is what the parser cannot enforce for you:
        # kwisatz flags belong before the target, the script's arguments after `--`
        detail=(
            "kwisatz flags come before the target, the script's arguments go after `--`:"
            "  `kwisatz run traefik -- --force`. The script's own --force/--check/--help stay "
            "reachable and are never parsed here; the script's stdout is the command's stdout "
            "(R-JSON-001's one exception). A script flag that arrives without `--` is a usage "
            "error, not something the CLI guesses."
        ),
        args=(("TARGET", "the target to run"), ("[ARGS]\u2026", "after `--`, forwarded verbatim")),
        mutates=True,
        milestone="M2",
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
    "config": "cmd_config",
    "services": "cmd_services",
    "logs": "cmd_logs",
    "state": "cmd_state",
    "models": "cmd_models",
    "run": "cmd_run",
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
        raise CliError(
            Exit.PREREQUISITE,
            "--interactive needs a terminal — the script would prompt on a closed stdin",
            hint="run without --interactive, or run it in a shell",
        )

    if not getattr(app.args, "dry_run", False):
        # R-SAFE-005: a full apply is where an unnoticed config edit costs the most
        if not wanted:
            for message in _config_changed(repo, config):
                app.warn(message)
        # §9: a box that cannot sudo without a prompt is a prerequisite, so say `4` before the
        # first script runs instead of letting the deploy discover it. R-APP-013 hands the child
        # /dev/null stdin, where sudo falls back to getpass and dies with `termios.error` /
        # `EOFError` inside gevent: exit 1, a traceback on stderr, and a hint that says "retry
        # this one target" about a box that can never do it. Answering those prompts is what
        # `--interactive` is for, so that path stays exempt.
        if not interactive:
            _require_passwordless_sudo(app, targets, table)
        if len(targets) > 1 and not getattr(app.args, "no_sudo_warmup", False):
            _sudo_warmup(app)

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


def _deploy_argv(app: App, repo: Repo, names: list[str], extra: dict[str, str]) -> list[str]:
    """One deploy of exactly `names` — `-y -vvv`, this checkout's deploy.py, `select=`.

    `--env K=V` cannot be handed to the child the way a direct run would (deploy.py
    builds the task env, and the connector re-exports the config's own values on top of
    whatever it inherits), so it travels as `--data env=` and lands inside the same
    `build_task()` that computes the command. pyinfra parses the JSON back into a dict.
    """
    # `-v` is a count, so it belongs in the deploy: pyinfra reads its own `-v`s as a count too
    # (`-y -vvv -v`), which is what lets the operator's `apply -v` mean "say more" downstream.
    argv = repoio.deploy_argv(repo, app.config.path, names, verbosity=app.out.verbosity)
    if extra:
        argv += ["--data", "env=" + json.dumps(extra, separators=(",", ":"))]
    return argv


def _run_targets(app: App, targets: list[planner.Target], repo: Repo) -> int:
    extra = _env_overrides(app)
    timeout = float(getattr(app.args, "timeout", 3600) or 3600)
    interactive = bool(getattr(app.args, "interactive", False))
    keep_going = bool(getattr(app.args, "keep_going", False))
    started_at = now_iso()
    started = time.monotonic()
    # §5.2: `--timeout` is the *command's* budget, not each target's. Handing every target the
    # full number was the bug: 14 enabled targets under `--timeout 3600` could legitimately run
    # 14 hours behind a flag that promises one. From here on each target gets only what is left
    # of the deadline, and a target that cannot start inside it is `not-run`, not a fresh budget.
    deadline = started + timeout
    items: list[dict] = []
    total = len(targets)
    failed = 0
    timed_out_any = False
    budget_ran_out = False

    for index, target in enumerate(targets, 1):
        if target.task is None:  # a disabled entry with nothing runnable behind it
            raise CliError(
                Exit.CONFIG,
                f"{config_of(app)}: script {target.name}: nothing to run",
                target=target.name,
                hint=f"kwisatz info {target.name}",
            )
        budget = max(0.0, deadline - time.monotonic())
        if budget <= 0:
            # the deadline is not a target's problem, so `--keep-going` cannot answer it by
            # running on: the run did not finish, which is exit 5 whatever the flag says.
            budget_ran_out = True
            # deliberately not counted as `failed`: the item keeps the honest `not-run` status,
            # and budget_ran_out is what decides the exit code below.
            app.fail(
                Exit.HEALTH,
                f"the command's --timeout {int(timeout)}s budget ran out before {target.name} ran",
                target=target.name,
                hint=f"kwisatz apply {target.name} --timeout <s>   ·   kwisatz logs {target.name}",
            )
            break
        header = f"[{index}/{total}] {target.name}" + (f" — {target.description}" if target.description else "")
        app.out.progress(header)
        app.out.action(f"running {target.name}")
        log = repo.logs / f"kwisatz-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}-{target.name}.log"
        if interactive:
            # the one path that is not a deploy: an interactive run is the operator
            # running the script on their own terminal, which is what `--interactive`
            # has always meant, and pyinfra cannot attach a TTY (R-APP-013).
            app.out.verbose("  script " + shlex.join(target.task.argv))
            outcome = runner.run_task(
                target.task,
                root=repo.path,
                interactive=True,
                extra_env=extra,
                log_path=log,
                timeout=budget,
                echo_stdout=not app.out.json,
                heartbeat=3.0,
                on_heartbeat=lambda elapsed, pid, name=target.name: app.out.progress(
                    f"  … {name} still running {elapsed}s · pid {pid}"
                ),
            )
        else:
            # R-APP-001/§11.3: the task runs inside a pyinfra deploy of this checkout, so
            # the command, the env and the stdin are deploy.py's, not the CLI's.
            deploy = _deploy_argv(app, repo, [target.name], extra)
            # `-v` names the command it is running, on stderr, before it runs: the same detail is
            # what makes `-v` worth typing when a deploy is about to write to the machine.
            app.out.verbose("  deploy " + shlex.join(deploy))
            outcome = runner.run_deploy(
                argv=deploy,
                root=repo.path,
                env=runner.deploy_env(repo.path),
                log_path=log,
                timeout=budget,
                echo_stdout=not app.out.json,
                heartbeat=3.0,
                on_heartbeat=lambda elapsed, pid, name=target.name: app.out.progress(
                    f"  … {name} still running {elapsed}s · pid {pid}"
                ),
            )
        _event(app, {"type": "step", "action": "start", "target": target.name, "index": index})
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
            timed_out_any = True
            # name the slice this target actually got; `round`, so a 2.95 s allowance that the
            # loop itself shaved does not report "2s", and say whose budget it was only when the
            # difference is the deadline rather than the few milliseconds this loop costs.
            spent = max(1, round(budget))
            shared = "" if timeout - budget < 0.5 else f" of the command's {int(timeout)}s budget"
            app.fail(
                Exit.HEALTH,
                f"{target.name} timed out after {spent}s{shared}",
                target=target.name,
                hint=f"kwisatz apply {target.name} --timeout <s> · kwisatz logs {target.name}",
            )
        elif outcome.returncode == 0:
            app.out.ok(f"{target.name} · {outcome.duration_ms // 1000}s")
        else:
            item["status"] = "failed"
            item["exit_code"] = outcome.returncode
            failed += 1
            code = outcome.returncode
            app.fail(
                Exit.TASK_FAILED,
                (
                    f"{target.name} exited {code}"
                    if code is not None
                    else f"{target.name} never reported an exit status · kwisatz logs {target.name}"
                ),
                target=target.name,
                hint=f"kwisatz apply {target.name}  (retry this one target only)",
            )
        items.append(item)
        _event(app, {"type": "step", "action": "end", "target": target.name, "status": item["status"]})
        if failed and not keep_going:
            # the last target leaves nothing behind; "the remaining 0 script(s) did not run"
            # is a line about a run that had no remainder at all
            if index < total:
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
    code = _run_exit_code(app, failed, timed_out_any, keep_going, budget_ran_out)
    _summary(app, items)
    state.record(
        repo,
        {
            "command": "apply",
            "started_at": started_at,
            "duration_ms": int((time.monotonic() - started) * 1000),
            "repo": repoio.repo_dict(repo),
            "config": str(app.config.path) if app.config else "",
            "config_sha": state.config_sha(app.config.path) if app.config else "",
            "entries": state.entries_map(app.config) if app.config else {},
            "exit_code": code,
            "items": [{k: i.get(k) for k in ("target", "status", "exit_code", "duration_ms")} for i in items],
        },
    )
    return code


def _run_exit_code(app: App, failed: int, timed_out: bool, keep_going: bool, budget_ran_out: bool = False) -> int:
    """The run's verdict: a timeout is a HEALTH (R-AGE-002), not an ordinary script failure.

    They used to collapse into `1`, which made an agent retry a hung 20-minute stack as if the
    script had exited badly. `--keep-going` keeps `PARTIAL`, because that is what the flag's own
    contract says: it finished, and at least one thing failed.

    A spent whole-command budget is the exception to that last sentence, so it is decided first:
    the run did *not* finish, which is `5` even with `--keep-going`. The skipped target keeps its
    `not-run` status instead of inflating `failed`, so this branch is the only thing that knows.
    """
    if budget_ran_out:
        return app.timed_out_code()
    if not failed:
        return Exit.OK
    if keep_going:
        return Exit.PARTIAL
    return app.timed_out_code() if timed_out else Exit.TASK_FAILED


def _summary(app: App, items: list[dict]) -> None:
    """R-OUT-007: target · outcome · duration · next step."""
    if app.out.json:
        return
    if app.out.quiet:
        # R-OUT-003: one line on success, no table, no next-step chatter
        bad = [i for i in items if i["status"] != "applied"]
        one = items[0]["target"] if len(items) == 1 else f"{len(items) - len(bad)}/{len(items)} targets"
        app.out.result(f"{one} {'failed: ' + bad[0]['target'] if bad else 'applied'}")
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

    items = planner.plan_items(enabled)
    running = _running_services(app)
    for item in items:
        service = serviceio.find(running, item["target"])
        item["runtime"] = service.annotation() if service else ""
    app.result = {
        "plan": len(enabled),
        "ran": 0,
        "items": items,
        "disabled": [{"target": t.name, "description": t.description} for t in disabled],
    }
    if not app.out.json:
        if not enabled:
            app.out.result("nothing is enabled — kwisatz list --all, then kwisatz config enable <target>")
        else:
            planner.print_plan(app.out, enabled)
            # R-STA-002: "what will run" is only half the question; "what is already up" is the other half
            live = [(i["target"], i["runtime"]) for i in items if i["runtime"]]
            if live:
                app.out.note("running: " + ", ".join(f"{name} {state}" for name, state in live))
            if disabled:
                app.out.note(f"{len(disabled)} disabled; kwisatz list --all")
    return Exit.OK


def _running_services(app: App) -> list:
    """The stack states for this run, cached on the app (discovery shells out; it is not free)."""
    cached = getattr(app, "_services", None)
    if cached is None:
        names = [item.name for item in _load_plan_or_none(app)]
        try:
            names += list(planner.task_files(app.repo_dir().path))
        except CliError:
            pass
        cached = serviceio.discover(names)
        app._services = cached
    return cached


def cmd_list(app: App) -> int:
    _, config, pl = app.load_plan()
    known = planner.catalog(config, pl)
    shown = known if getattr(app.args, "all", False) else [t for t in known if t.enabled]
    running = _running_services(app)
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
                "runtime": (serviceio.find(running, t.name) or _none()).annotation(),
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
        app.out.result(f"  script     {script or '(none)'}")
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
    """§6.7 R-OPS-003: prerequisites, the §6.5 table, port sanity, and what is already running.

    Exit codes are the whole point of this command for an agent: `4` means "this box cannot
    run kwisatz yet", `5` means "it can, but something installed is unhealthy", `0` means go.
    Nothing else changes, and nothing here mutates the machine.
    """
    repo = app.repo_dir()
    found = checks.host_checks()
    config = None
    try:
        _, config, _ = app.load_plan()
        names = [item.name for item in app.plan.items]
    except (CliError, orchestrator.ConfigError) as e:
        names = []
        app.warn(f"machine-config.yml is not readable, so the ordering and port checks are skipped: {e}")
    else:
        table = checks.load_prerequisites()
        app.warnings.extend(planner.check_prerequisite_order(list(app.plan.enabled), config, table["requires"]))
        app.warnings.extend(checks.fact_advisories(list(app.plan.enabled), table))

    running = serviceio.discover(names)
    conflicts = checks.port_conflicts(config, running) if config is not None else []
    broken = serviceio.unhealthy(running)
    missing = [c for c in found if c.required and not c.ok]
    code = Exit.PREREQUISITE if missing else (Exit.HEALTH if broken or not all(c.ok for c in conflicts) else Exit.OK)
    items = [{"name": c.name, "kind": "prerequisite", "ok": c.ok, **c.as_dict()} for c in found]
    items += [{"name": c.detail, "kind": "port", "ok": c.ok, **c.as_dict()} for c in conflicts]
    items += [
        {"name": s.name, "kind": "service", "ok": s.state not in (serviceio.UNHEALTHY, serviceio.STOPPED),
         "state": s.state, "source": s.source, "hint": f"kwisatz logs {s.name}"}
        for s in broken
    ]
    app.result = {
        # the flat list an agent branches on: `doctor --json | jq '.result.items[]|select(.ok|not)'`
        "items": items,
        "checks": [c.as_dict() for c in found],
        "ports": [c.as_dict() for c in conflicts],
        "unhealthy": [s.as_dict() for s in broken],
        "prerequisites": checks.load_prerequisites(),
        "ok": code == Exit.OK,
        "missing": [c.name for c in missing],
        "doctor_exit_code": code,
    }
    app.out.progress(f"kwisatz {__version__} · repo {repo.path} ({repo.branch or 'no branch'} {repo.git_sha})")
    for check in found:
        detail = f"{check.name}: {check.detail}" if check.detail else check.name
        if check.ok:
            app.out.verdict("✓", detail)
        elif check.required:
            app.out.verdict("✗", f"{detail} — {check.hint}")
        else:
            app.out.verdict("⚠", f"{detail} — {check.hint}")
    for check in conflicts:
        app.out.verdict("✗", f"{check.detail} — {check.hint}")
    for service in broken:
        app.out.verdict("✗", f"{service.name} is {service.state} — kwisatz logs {service.name}")
    for message in app.warnings:
        app.out.warning(message)
    app.warnings_shown = True
    if code and not app.out.json:
        app.out.note("kwisatz doctor --json lists every check and the exact fix")
    return code


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
    pin = getattr(app.args, "with_uv", None)
    if shutil.which("uv") is None:
        if not pin:
            raise CliError(
                Exit.PREREQUISITE,
                "uv is not installed, and kwisatz does not install a toolchain behind your back",
                hint="curl -LsSf https://astral.sh/uv/install.sh | sh   then kwisatz install",
            )
        if not getattr(app.args, "yes", False):
            raise CliError(
                Exit.USAGE,
                f"--with-uv {pin} would download and execute upstream install code",
                hint="kwisatz install --with-uv " + str(pin) + " --yes",
            )
        installer = f"https://astral.sh/uv/{pin}/install.sh"
        app.out.action(f"installing uv {pin} from the pinned official installer")
        done = subprocess.run(["sh", "-c", f"curl -LsSf {installer} | sh"], timeout=600, check=False)
        if done.returncode != 0 or shutil.which("uv") is None:
            raise CliError(
                Exit.PREREQUISITE,
                f"the uv {pin} installer exited {done.returncode} and uv is still not on PATH",
                hint=f"curl -LsSf {installer} | sh",
            )
    if getattr(app.args, "dry_run", False):
        app.result = {"repo": str(repo.path), "dry_run": True}
        app.out.action(f"dry run — would sync {repo.path} and write ~/.local/bin/kwisatz")
        return Exit.OK
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
        if str(Path.home() / ".local" / "bin") not in os.environ.get("PATH", "").split(os.pathsep):
            app.out.warning(f"{launcher.parent} is not on PATH for this shell — add it to your profile")
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
    if not app.out.json:  # --json owns stdout: this line would be a second document (R-JSON-001)
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


# ── M2: config / services / logs / state / models / run ─────────────────────────────


def cmd_config(app: App) -> int:
    """§6.6: the config file, edited by a command that cannot lose a comment."""
    repo = app.repo_dir()
    path = repoio.resolve_config(repo, getattr(app.args, "config", None))
    verb = getattr(app.args, "subcommand", None)
    if verb == "path":
        app.result = {"config": str(path)}
        if not app.out.json:
            app.out.result(str(path))
        return Exit.OK
    if verb == "init":
        return cmd_init(app)
    if verb == "validate":
        return _config_validate(app, repo, path)
    if verb == "show":
        return _config_show(app, repo, path)
    return _config_mutate(app, repo, path, verb)


def _config_validate(app: App, repo: Repo, path: Path) -> int:
    """R-CFG-007: every problem at once, using the runner's own checks."""
    found = configio.problems(path, repo.path)
    entries = enabled = 0
    try:
        plan = orchestrator.build_plan(orchestrator.load_config(path, repo.path), warn=lambda _m: None)
        entries, enabled = len(plan.items), len(plan.enabled)
    except orchestrator.ConfigError:
        pass
    app.result = {
        "config": str(path),
        "ok": not found,
        "entries": entries,
        "enabled": enabled,
        "problems": found,
    }
    if app.out.json:
        return Exit.CONFIG if found else Exit.OK
    for message in found:
        app.out.error(message)
    if found:
        app.out.note("kwisatz config set/enable … or edit the file, then kwisatz config validate")
        return Exit.CONFIG
    app.out.ok(f"{path.name} is valid — {entries} entries, {enabled} enabled")
    return Exit.OK


def _config_show(app: App, repo: Repo, path: Path) -> int:
    _, _, plan = app.load_plan()
    wanted = getattr(app.args, "target", None)
    items = []
    for item in plan.items:
        if wanted and planner.canonical(item.name) != planner.canonical(wanted):
            continue
        items.append(
            {
                "target": item.name,
                "enabled": item.enabled,
                "description": item.description,
                "args": list(item.args),
                "env": jsonio.mask_env(item.env, reveal=_reveal(app)),
            }
        )
    app.result = {"config": str(path), "entries": items}
    if app.out.json:
        return Exit.OK
    if wanted and not items:
        raise config_error(f"{path}: no entry for {wanted!r}", hint="kwisatz list --all")
    for item in items:
        flag = "enabled " if item["enabled"] else "disabled"
        app.out.result(f"{item['target']:<30} {flag}  {item['description']}")
        if item["args"]:
            app.out.result(f"{'':<30}   args: {' '.join(item['args'])}")
        if item["env"]:
            app.out.result(f"{'':<30}   env:   {', '.join(sorted(item['env']))}")
    return Exit.OK


def _config_mutate(app: App, repo: Repo, path: Path, verb: str) -> int:
    """One write, done carefully: lock, mutate in memory, validate, replace, tell the truth.

    The order is the point. Reading the file through `planner.resolve_target` means
    `config enable docker` writes `setup-docker:` (the key that matches the script), never a
    second key for the same service; validating *after* the write and rolling back on a
    problem means a typo can never be left behind for the next `apply` to trip over.
    """
    name_arg = getattr(app.args, "target", None)
    if not name_arg:
        raise usage("config needs a target", hint="kwisatz config enable <target>")
    repo.ensure_work()
    with repoio.held(repo, float(getattr(app.args, "lock_timeout", 0) or 0)):
        doc = configio.load(path)
        before = path.read_text() if path.is_file() else ""
        key = planner.resolve_target(name_arg, *_plan_pair(app)).name
        if verb == "enable":
            configio.set_enabled(doc, key, True)
        elif verb == "disable":
            configio.set_enabled(doc, key, False)
        elif verb == "set":
            raw = getattr(app.args, "key_value", None) or ""
            if "=" not in raw:
                raise usage(f"config set expects KEY=VALUE, got {raw!r}", hint="kwisatz config set x K=V")
            env_key, _, value = raw.partition("=")
            configio.set_env(doc, key, env_key, value)
        elif verb == "unset":
            env_key = getattr(app.args, "key", None) or ""
            if not configio.unset_env(doc, key, env_key) and not configio.unset_key(doc, key, env_key):
                app.out.note(f"{key}: no {env_key} to remove — nothing changed")
                return Exit.OK
        elif verb == "args":
            configio.set_args(doc, key, list(getattr(app.args, "flags", None) or []))
        else:
            raise usage(f"unknown config verb {verb!r}", hint="kwisatz config show|validate|enable|…")

        intended = configio.dumps(doc)
        lines = configio.diff(before, intended)
        app.result = {
            "config": str(path),
            "target": key,
            "verb": verb,
            "changed": bool(lines),
            "diff": lines,
            "dry_run": bool(getattr(app.args, "dry_run", False)),
        }
        if getattr(app.args, "dry_run", False):
            app.out.action("dry run — nothing was written")
            _print_diff(app, lines)
            return Exit.OK
        if not lines:
            app.out.ok(f"{key}: already configured that way")
            return Exit.OK

        configio.dump(doc, path, backup=configio.backup_path(repo.work, path))
        problems = configio.problems(path, repo.path)
        if problems:
            configio.restore(path, before)
            app.result["rolled_back"] = True
            for message in problems:
                app.out.error(message)
            raise CliError(
                Exit.CONFIG,
                f"{path}: the edit would have left {len(problems)} problem(s); it was reverted",
                target=key,
                hint="kwisatz config validate",
            )
        _print_diff(app, lines)
        app.out.note(f"next: kwisatz apply {key}" if key in [i.name for i in _plan_items(app)] else "next: kwisatz apply")
    return Exit.OK


def _plan_items(app: App):
    return app.plan.items if app.plan is not None else []


def _plan_pair(app: App):
    """(config, plan) from the run's cached resolution — the planner's single source."""
    _, config, plan = app.load_plan()
    return config, plan


def _print_diff(app: App, lines: list[str]) -> None:
    if app.out.json:
        return
    for line in lines:
        if line.startswith("---") or line.startswith("+++"):
            continue
        app.out.result(line)


def cmd_services(app: App) -> int:
    """§6.7 R-OPS-001: what is running, as data, with no guessing."""
    names = [item.name for item in _load_plan_or_none(app)]
    found = serviceio.discover(names)
    app.result = {
        "count": len(found),
        "docker": serviceio.docker_running(),
        "systemd": serviceio.systemd_running(),
        "items": [s.as_dict() for s in found],
    }
    if app.out.json:
        return Exit.OK
    if not found:
        app.out.result("nothing kwisatz manages is running here")
        return Exit.OK
    app.out.result(f"{'SERVICE':<26} {'MANAGER':<9} {'STATE':<12} {'PORTS':<14} SOURCE")
    for service in found:
        ports = ",".join(str(p) for p in service.as_dict()["ports"]) or "—"
        app.out.result(
            f"{service.name:<26} {service.manager:<9} {service.state:<12} {ports:<14} {service.source}"
        )
    bad = serviceio.unhealthy(found)
    for service in bad:
        app.out.warning(f"{service.name} is {service.state} — kwisatz logs {service.name}")
    return Exit.OK


def cmd_logs(app: App) -> int:
    """R-OPS-005: the logs of a stack, a unit, or the last apply, by what exists."""
    repo = app.repo_dir()
    target = getattr(app.args, "target", None) or ""
    if target:
        # R-OPS-005: "no logs" has to mean *this* target logged nothing, not "that name is not
        # one of ours". Resolve it first — the same seam `info`/`run`/`config` use — so a
        # misspelling answers with the suggestion instead of the sentence a stackless target gets.
        target = planner.resolve_target(target, *_plan_pair(app)).name
    names = [item.name for item in _load_plan_or_none(app)]
    found = serviceio.discover(names)
    service = serviceio.find(found, target) if target else None
    source = logsio.source_for(service, target, repo.logs)
    if source.argv is None:
        raise CliError(
            Exit.CONFIG if target else Exit.USAGE,
            source.description,
            target=target or None,
            hint="kwisatz services   ·   kwisatz logs <target> --tail 200",
        )
    argv = logsio.stream_argv(
        source,
        tail=getattr(app.args, "tail", None),
        since=getattr(app.args, "since", None),
        follow=bool(getattr(app.args, "follow", False)),
    )
    timeout = float(getattr(app.args, "timeout", 3600) or 3600)
    app.result = {"source": source.description, "command": argv}
    if source.kind == logsio.APPLY_LOG:
        shown = logsio.tail(Path(source.path), int(getattr(app.args, "tail", 0) or 200))
        app.result["lines"] = shown
        if not app.out.json:  # --json owns stdout; the lines are in `result.lines` there
            for line in shown:
                app.out.result(line)
        return Exit.OK
    if app.out.json:
        # R-JSON-001: nothing but the document may reach stdout, so capture instead of stream
        done = logsio.capture(argv, timeout)
        app.result["stdout_tail"] = done.splitlines()[-200:]
        return Exit.OK
    app.out.progress(source.description)
    done = logsio.stream(argv, timeout)
    if done.returncode is None:
        # R-OPS-005: the deadline is how a bounded follow is *meant* to end — the operator got
        # the stream they asked for and it stopped. `--json` already answers 0 for this same
        # request (`capture()` swallows the timeout), and 5 would call a healthy stack unhealthy
        # because nobody wanted a verdict. Say it on stderr, where progress lines belong.
        app.out.warning(f"stopped after {max(1, round(timeout))}s — --timeout bounds a follow")
        return Exit.OK
    return Exit.OK if done.returncode == 0 else Exit.TASK_FAILED


def cmd_state(app: App) -> int:
    """§6.9: the answer to "did we ever install this, and with what?"."""
    repo = app.repo_dir()
    target = getattr(app.args, "target", None)
    if target:
        # §6.9: a typo and a target that never ran used to be the same answer (count 0, exit 0).
        # Resolve the name through the plan — the way `info` does when it reads `state.read(repo,
        # target.name)` — so an unknown name exits 3 with the existing `closest:` hint, and a
        # misspelling cannot be mistaken for history that was never written.
        target = planner.resolve_target(target, *_plan_pair(app)).name
    records = state.read(repo, target, 50)
    # `items` is the key every other command uses; `records` stays for anyone already reading it
    app.result = {"path": str(state.path(repo)), "count": len(records), "records": records, "items": records}
    if app.out.json:
        return Exit.OK
    if not records:
        app.out.result(f"nothing has been applied yet — {state.path(repo)} does not exist")
        return Exit.OK
    for record in records:
        items = record.get("items") or []
        outcomes = " ".join(f"{i.get('target')}={i.get('status')}" for i in items) or "(no items)"
        app.out.result(
            f"{record.get('started_at', '?')}  exit {record.get('exit_code', '?')}  "
            f"{record.get('command', 'apply')}  {outcomes}"
        )
    return Exit.OK


def cmd_models(app: App) -> int:
    """R-MOD-001: honest about what `tasks/sync-models.py` does and does not do."""
    verb = getattr(app.args, "subcommand", None)
    if verb == "status":
        return _models_status(app, sync=False)
    if verb == "show":
        return _models_status(app, sync=True)
    return _models_sync(app)


def _models_sync(app: App) -> int:
    repo, config, _ = app.load_plan()
    argv = orchestrator.task_command("sync-models", config, warn=app.out.warning)
    if getattr(app.args, "dry_run", False):
        # sync-models.py has no --dry-run, so claiming one would be a lie
        app.result = {"command": argv, "dry_run": True}
        if not app.out.json:
            app.out.action("dry run — tasks/sync-models.py has no --dry-run; nothing was run")
            app.out.result("    " + " ".join(argv))
        return Exit.OK
    task = orchestrator.Task(name="sync-models", argv=argv, env={"INTERACTIVE": "false"}, secrets=frozenset())
    timeout = float(getattr(app.args, "timeout", 3600) or 3600)
    outcome = runner.run_task(
        task,
        root=repo.path,
        log_path=repo.logs / f"kwisatz-{now_iso().replace(':', '')}-sync-models.log",
        timeout=timeout,
        echo_stdout=not app.out.json,
        on_heartbeat=lambda elapsed, pid: app.out.progress(f"  … sync-models still running {elapsed}s · pid {pid}"),
    )
    code, script_code = _map_models_exit(outcome.returncode, outcome.timed_out)
    app.result = {
        "command": " ".join(argv),
        "exit_code": outcome.returncode,
        "script_exit_code": script_code,
        "log_path": outcome.log_path,
        "stdout_tail": outcome.stdout_tail,
    }
    if outcome.timed_out:
        # R-AGE-002: the deadline was spent, so the child never reported a code and there is
        # nothing to quote. Say what stopped it, and exit 5 the way `apply` does.
        app.fail(
            code,
            f"sync-models timed out after {max(1, round(timeout))}s",
            hint="kwisatz models sync --timeout <s>   ·   kwisatz logs sync-models",
        )
    elif outcome.returncode:
        app.fail(
            code,
            f"sync-models.py exited {outcome.returncode}"
            + (" (pre-flight — nothing was mutated)" if outcome.returncode == 1 else ""),
            hint="kwisatz models status   ·   cat models.yml",
        )
    return code


def _map_models_exit(code: int | None, timed_out: bool = False) -> tuple[int, int | None]:
    """sync-models.py's 0/1/2 onto §9, keeping its own code for the caller (R-EXIT-001).

    The timeout is decided *before* the code, because it is the reason the code is missing:
    a killed child reported nothing, and `None` used to read as "no failure", so `models sync
    --timeout` answered 0 / `ok: true` about a script the CLI had just stopped.
    """
    if timed_out:
        return Exit.HEALTH, None
    if code:
        return (Exit.PREREQUISITE, code) if code == 1 else (Exit.TASK_FAILED, code)
    return Exit.OK, code


def _models_status(app: App, sync: bool) -> int:
    """The catalog as the machine sees it: the file that wins, the models it names, llama-swap."""
    repo = app.repo_dir()
    path = next((p for p in (repo.path / "models.yml", repo.path / "models.yml.example") if p.is_file()), None)
    catalog = _catalog_summary(path) if path else {"path": "", "providers": 0, "models": 0, "names": []}
    swap = serviceio.discover(["llama-swap"])
    swap_state = serviceio.find(swap, "llama-swap")
    # the human line says the same thing `result.llama_swap` says, and `UNKNOWN` is the honest
    # word when a stack exists but no manager reports its state
    swap_line = swap_state.state if swap_state else "not installed"
    if swap_state and swap_state.state == serviceio.RUNNING:
        swap_line = "running"
    app.result = {
        "catalog": catalog,
        "llama_swap": swap_state.as_dict() if swap_state else {"name": "llama-swap", "state": serviceio.UNKNOWN},
    }
    if sync:
        app.result["sync_command"] = "tasks/sync-models.py"
    if not app.out.json:
        app.out.result(f"catalog  {catalog['path']}")
        app.out.result(f"models   {catalog['models']} across {catalog['providers']} provider(s)")
        if catalog["names"]:
            app.out.result("         " + ", ".join(catalog["names"]))
        app.out.result(f"swap     {swap_line}")
        if sync:
            app.out.note("kwisatz models sync applies it")
    return Exit.OK


def _catalog_summary(path: Path) -> dict:
    import yaml

    try:
        doc = yaml.safe_load(path.read_text()) or {}
    except (OSError, yaml.YAMLError):
        return {"path": str(path), "providers": 0, "models": 0, "names": [], "unparsable": True}
    providers = doc.get("providers") or []
    names = [str(m.get("name")) for p in providers if isinstance(p, dict) for m in (p.get("models") or []) if isinstance(m, dict)]
    return {"path": str(path), "providers": len(providers), "models": len(names), "names": names}


def cmd_run(app: App) -> int:
    """R-CMD-004 / R-EXIT-001: the script, with whatever the user typed after `--`."""
    repo, config, plan = app.load_plan()
    target = planner.resolve_target(getattr(app.args, "target", None), config, plan)
    if target.task is None and target.configured:
        # `run` is the escape hatch, and an escape hatch does not care about the enabled flag
        target.task = orchestrator.build_task(target.name, config.entry(target.name), config)
    if target.task is None:
        raise CliError(
            Exit.CONFIG,
            f"{config.path}: {target.name} has nothing to run (enabled: false and no task file)",
            target=target.name,
            hint=f"kwisatz apply {target.name}",
        )
    rest = [a for a in (getattr(app.args, "rest", None) or []) if a != "--"]
    task = orchestrator.Task(
        name=target.name,
        argv=[*target.task.argv, *rest],
        env=dict(target.task.env),
        secrets=frozenset(target.task.env) - {"INTERACTIVE"},
        stdin=orchestrator.STDIN_INHERIT,
    )
    command = task.command.replace(" </dev/null", "")
    if getattr(app.args, "dry_run", False):
        # R-SAFE-002: `-n` is a global flag, and this is the one command that used to
        # execute the script while printing nothing that claimed otherwise. The argv is
        # built above, so the plan it shows is exactly what the run would have done.
        app.result = {"target": target.name, "command": command, "dry_run": True}
        if not app.out.json:
            app.out.action("dry run — nothing was executed")
            app.out.result("    " + command)
        return Exit.OK
    repo.ensure_work()
    app.out.verbose("  script " + command)
    timeout = float(getattr(app.args, "timeout", 3600) or 3600)
    log = repo.logs / f"kwisatz-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}-{target.name}.log"
    with repoio.held(repo, float(getattr(app.args, "lock_timeout", 0) or 0)):
        outcome = runner.run_task(
            task,
            root=repo.path,
            extra_env=_env_overrides(app),
            log_path=log,
            timeout=timeout,
            echo_stdout=not app.out.json,
            inherit_stdio=False,
        )
    code, script_code = _map_task_exit(outcome.returncode, outcome.timed_out)
    app.result = {
        "target": target.name,
        "command": command,
        "script_exit_code": script_code,
        "duration_ms": outcome.duration_ms,
        # the log `run` now writes, in the same place `apply` puts it, so the failure hint's
        # `kwisatz logs <target>` has something to read and a JSON caller can go straight to it
        "log_path": outcome.log_path,
    }
    if code:
        # A killed script has no code to name, so the message has to say what stopped it —
        # `run` shares apply's wording (§5.2) so one answer covers both commands.
        if outcome.timed_out:
            app.fail(
                code,
                f"{target.name} timed out after {max(1, round(timeout))}s",
                target=target.name,
                hint=f"kwisatz run {target.name} --timeout <s> · kwisatz logs {target.name}",
            )
        else:
            app.fail(
                code,
                f"{target.name} exited {script_code}",
                target=target.name,
                hint=f"kwisatz logs {target.name}",
            )
    return code


def _map_task_exit(code: int | None, timed_out: bool = False) -> tuple[int, int | None]:
    """A script's 0/1/2 onto §9, with 2 surfaced as 1 + `script_exit_code` (R-EXIT-001).

    A spent deadline is checked first for the same reason `apply` checks it first (R-AGE-002):
    the process group is gone without a status, and `None` is not "exited fine", it is "never
    told us". `run` answered 0 and `ok: true` for a script it had just killed.
    """
    if timed_out:
        return Exit.HEALTH, None
    if code:
        return Exit.TASK_FAILED, code
    return Exit.OK, code


def _none():
    """A "nothing running" service, so a plain target still prints an empty annotation."""
    return serviceio.Service(name="")


def _load_plan_or_none(app: App) -> list:
    """Targets for service discovery: a broken config must not hide what is running."""
    try:
        _, _, plan = app.load_plan()
    except (CliError, orchestrator.ConfigError):
        return []
    return plan.items


def _services_for(app: App, target: str) -> serviceio.Service | None:
    names = [item.name for item in _load_plan_or_none(app)]
    for name in _names_from_disk(app):
        names.append(name)
    return serviceio.find(serviceio.discover(names), target)


def _names_from_disk(app: App) -> list[str]:
    try:
        repo = app.repo_dir()
    except CliError:
        return []
    return list(planner.task_files(repo.path))


def _config_changed(repo: Repo, config) -> list[str]:
    """R-SAFE-005: warn when the plan being applied differs from the one last applied.

    The record carries a sha of the file *and* the enabled/disabled map, so the warning can
    name the keys that moved instead of saying "the config changed".
    """
    records = state.read(repo, None, 1)
    if not records:
        return []
    last = records[0]
    now_sha = state.config_sha(config.path)
    before = last.get("config_sha") or ""
    if not before or before == now_sha:
        return []
    last_entries = last.get("entries") or {}
    now_entries = state.entries_map(config)
    moved = [
        f"{name} {'enabled' if now_entries.get(name) else 'disabled'}"
        for name in now_entries
        if last_entries.get(name) != now_entries.get(name)
    ]
    for name in last_entries:
        if name not in now_entries:
            moved.append(f"{name} removed from the config")
    detail = " (" + ", ".join(moved[:6]) + ")" if moved else ""
    return [
        f"{config.path.name} changed since the last apply on {last.get('started_at', 'an unknown run')}"
        f"{detail} — kwisatz status shows what this run will do"
    ]


def _require_passwordless_sudo(app: App, targets: list[planner.Target], table: dict) -> None:
    """Stop a sudo-needing apply on a box that cannot sudo without a prompt (exit `4`).

    Only the §6.5 host facts decide this, and the probe is not a policy: a cached `sudo -v`
    ticket makes the same probe answer true, so the operator who did the documented thing is not
    stopped. Everywhere else the `_sudo_warmup` warning stays the honest answer, because a target
    that never calls sudo should not be held hostage by this box's sudoers.
    """
    if not checks.requires_sudo(targets, table) or checks.has_sudo():
        return
    names = [t.name for t in targets if checks.facts_of(table, t.name).get("sudo")]
    where = "sudo is not installed" if shutil.which("sudo") is None else "`sudo -n true` fails here"
    raise CliError(
        Exit.PREREQUISITE,
        f"{', '.join(names)} needs passwordless sudo and {where} — its scripts get /dev/null "
        f"stdin, so there is nowhere to ask for the password",
        target=names[0],
        hint="run `sudo -v` in this shell first   ·   kwisatz apply <t> --interactive",
    )


def _sudo_warmup(app: App) -> None:
    """R-SAFE-006: refresh the ticket once, then keep it alive for a long apply.

    The CLI asks `sudo` nothing more than this — the task scripts remain the only thing that
    mutates the machine (R-SAFE-003). A 20-minute apply must not die on an expired credential
    in script 14, so the keep-alive is a daemon thread that exits with the process.
    """
    if not shutil.which("sudo"):
        return
    probe = subprocess.run(["sudo", "-n", "true"], capture_output=True, text=True, timeout=15, check=False)
    if probe.returncode != 0:
        app.warn(
            "sudo needs a password — run `sudo -v` in this shell first, "
            "or scripts that call sudo will fail on a closed stdin"
        )
        return
    threading.Thread(target=_sudo_keepalive, daemon=True).start()


def _sudo_keepalive(interval: float = 180.0) -> None:
    """`sudo -n true` every `interval` seconds while this process lives (no privilege use)."""
    while True:
        time.sleep(interval)
        subprocess.run(["sudo", "-n", "true"], capture_output=True, check=False)


def _event(app: App, payload: dict) -> None:
    """`--events`: NDJSON progress on stdout, terminated by the final document (R-JSON-003)."""
    if not getattr(app.args, "events", False):
        return
    payload.setdefault("at", now_iso())
    jsonio.emit(payload)


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
        epilog="run `kwisatz` with no command (or --help) for this map and the global flags",
    )
    parser.add_argument("--version", action="store_true", help="print version and repo SHA, exit 0")
    # globals work in either position (`kwisatz --repo x apply`, `kwisatz apply --repo x`); the
    # sub-parsers declare them with SUPPRESS defaults, so a sub-command's own default cannot
    # silently erase what the operator put before the verb
    for flag in GLOBAL_FLAGS:
        _add_flag(parser, flag)
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    for spec in COMMANDS:
        _add_command(sub, spec, nested=False)
    return parser


def _add_command(sub, spec: CommandSpec, *, nested: bool) -> None:
    """One sub-parser, built from the spec and nothing else (R-CMD-001)."""
    p = sub.add_parser(
        spec.name,
        help=spec.summary,
        description=(spec.detail or spec.summary) + "\n\n" + _flags_help(spec),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        add_help=False,
    )
    p.add_argument("-h", "--help", action="help", help="show this help message and exit")
    for flag in GLOBAL_FLAGS:
        _add_flag(p, flag, nested=True)
    for name, help_text in spec.args:
        dest, kwargs = _positional(name, help_text)
        p.add_argument(dest, **kwargs)
    for flag in spec.flags:
        _add_flag(p, flag, nested=nested)
    if spec.subcommands:
        verbs = p.add_subparsers(dest="subcommand", metavar="<verb>", required=True)
        for child in spec.subcommands:
            _add_command(verbs, child, nested=True)


def _add_flag(p: argparse.ArgumentParser, flag: Flag, *, nested: bool = False) -> None:
    """Declare one flag, on the top-level parser or on a verb's own parser.

    A verb must accept `kwisatz config enable x --json` without the operator repeating the flag
    before the verb. `default=SUPPRESS` on a nested parser is what makes that safe: an
    unspecified flag leaves the parent's value alone instead of resetting it to `False`.
    """
    if flag.append:
        p.add_argument(*flag.names(), metavar=flag.metavar, action="append", default=[] if not nested else argparse.SUPPRESS, help=flag.help)
        return
    names = flag.names()
    default = argparse.SUPPRESS if nested else flag.default
    if flag.metavar:
        p.add_argument(*names, metavar=flag.metavar, default=default, help=flag.help)
    elif names[0] in ("-v", "--verbose"):
        p.add_argument(*names, action="count", default=default if nested else 0, help=flag.help)
    elif isinstance(flag.default, list):
        p.add_argument(*names, action="append", default=[] if not nested else default, help=flag.help)
    elif flag.default is not None:
        p.add_argument(*names, default=default, help=flag.help)
    else:
        p.add_argument(*names, action="store_true", default=default if nested else False, help=flag.help)


def _positional(name: str, help_text: str) -> tuple:
    """`[ARGS]…` takes everything after `--`; `[TARGET]` is optional; the rest is required."""
    dest = _dest_of(name)
    if name.startswith("[ARGS"):
        # REMAINDER used to swallow every flag after the target, `--json` included; `*` keeps
        # kwisatz's own flags parseable and still takes everything the operator meant for the
        # script, which is everything after `--`.
        return "rest", {"nargs": "*", "default": [], "help": help_text}
    if name.endswith("\u2026"):  # a list: dest pluralises, so `[TARGET]…` is `targets`
        return f"{dest}s", {"nargs": "*", "default": [], "help": help_text}
    if name.startswith("["):
        return dest, {"nargs": "?", "default": None, "help": help_text}
    return dest, {"help": help_text}


def _dest_of(name: str) -> str:
    """`[TARGET]…` → `target`, `KEY=VALUE` → `key_value`: the brackets are decoration."""
    core = name.replace("[", "").replace("]", "").replace("\u2026", "")
    core = core.replace("=", "_").replace("-", "_").replace(" ", "_")
    return core.lower() or "arg"


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
            verbosity=int(getattr(args, "verbose", 0) or 0),
            json=getattr(args, "json", False),
            color=False if getattr(args, "no_color", False) else None,
        ),
    )


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    started = time.monotonic()
    parser = _build_parser()
    # argparse rejects an unknown verb before we get a turn, so the `did you mean` of
    # R-CMD-002 has to be decided from argv first.
    verb = _first_command_token(argv)
    if verb is not None and verb not in HANDLERS:
        return _no_command(argv)
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:  # argparse already wrote usage to stderr
        return int(e.code if isinstance(e.code, int) else 2)

    if getattr(args, "version", False):
        app = _make_app(args)
        return _finish(app, cmd_version(app), started)

    command = getattr(args, "command", None)
    if command is None and getattr(args, "json", False):
        # `kwisatz --json` with nothing else is the agent asking "what can you do", and it
        # wants the answer as a document, not as help text (R-JSON-001 owns stdout).
        args.command = command = "commands"
    if command not in HANDLERS:
        return _no_command(argv, parser)

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
    except orchestrator.ConfigError as e:
        # a config problem read by the shared module: one line naming the file, never a traceback
        app.errors.append({**config_error(str(e)).error(), "_shown": False})
        code = Exit.CONFIG
    except KeyboardInterrupt:  # pragma: no cover
        app.errors.append({"message": "interrupted", "exit_code": Exit.TASK_FAILED, "_shown": False})
        code = Exit.TASK_FAILED
    return _finish(app, code, started)


# options that swallow the next token, so `kwisatz --repo /x --version` is not read as a
# command called "/x"
_VALUE_FLAGS = {name for f in GLOBAL_FLAGS if f.metavar for name in f.flags} | {"-c", "-C"}


def _first_command_token(argv: list[str]) -> str | None:
    """The verb the user meant: the first token that is neither a flag nor a flag's value."""
    skip_next = False
    for token in argv:
        if skip_next:
            skip_next = False
            continue
        if token.startswith("-"):
            if "=" not in token and token in _VALUE_FLAGS:
                skip_next = True
            continue
        return token
    return None


def _no_command(argv: list[str], parser: argparse.ArgumentParser | None = None) -> int:
    first = _first_command_token(argv)
    if first is None:  # bare `kwisatz` is the help — the same answer `--help` gives, exit 0
        if parser is not None:
            parser.print_help()
        return Exit.OK
    print(f"kwisatz: unknown command {first!r}", file=sys.stderr)
    print(f"        try: kwisatz <{'|'.join(HANDLERS)}>", file=sys.stderr)
    close = planner.similar(first, list(HANDLERS), 3)
    if close:
        print(f"  did you mean: kwisatz {close[0]} ?", file=sys.stderr)
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
    # R-OUT-006: no command may exit non-zero in silence. A raised CliError lands in
    # app.errors unshown; without this it would be `exit 3` with nothing on stderr.
    if code != Exit.OK:
        for entry in app.errors:
            if not entry.get("_shown"):
                app.out.error(entry["message"])
                if entry.get("hint"):
                    app.out.note(f"next: {entry['hint']}")
    return code


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
