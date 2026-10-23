"""Where a target's logs actually live (§6.7 R-OPS-005).

Three sources, chosen by what discovery found — never by a guess:

  docker   `docker compose -f <stack>/docker-compose.yml logs …`
  systemd  `journalctl -u <unit> …`
  else     the newest `logs/kwisatz-<ts>-<target>.log` the last apply wrote

The last one is what makes `kwisatz logs <unconfigured-script>` useful: task scripts are
the implementation, and their stdout is already captured there (R-SAFE-007, mode 0600).
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import services as serviceio

DOCKER = "docker"
JOURNAL = "journal"
APPLY_LOG = "apply-log"


@dataclass
class LogSource:
    kind: str
    argv: list[str] | None
    description: str
    path: str = ""


def source_for(service: serviceio.Service | None, target: str, logs_dir: Path) -> LogSource:
    if service is not None and service.manager == "docker" and service.source:
        compose = Path(service.source)
        if compose.is_file():
            return LogSource(
                DOCKER,
                ["docker", "compose", "-f", str(compose), "logs"],
                f"docker compose stack {service.name} ({compose})",
            )
    if service is not None and service.manager == "systemd" and service.unit:
        return LogSource(JOURNAL, ["journalctl", "-u", service.unit], f"systemd unit {service.unit}")
    newest = newest_apply_log(logs_dir, target)
    if newest is not None:
        return LogSource(APPLY_LOG, ["tail", "-n", "200", str(newest)], str(newest), str(newest))
    return LogSource(APPLY_LOG, None, f"no logs for {target!r}: no stack, no unit, no apply log")


def newest_apply_log(logs_dir: Path, target: str) -> Path | None:
    """The latest `logs/kwisatz-<ts>-<target>.log`; newest wins because logs are append-only history."""
    if not target:
        candidates = sorted(logs_dir.glob("kwisatz-*.log"))
        return max(candidates, key=lambda p: p.name) if candidates else None
    candidates = sorted(logs_dir.glob(f"kwisatz-*-{target}.log"))
    return max(candidates, key=lambda p: p.name) if candidates else None


def apply_logs(logs_dir: Path, target: str = "", limit: int = 8) -> list[dict]:
    """The stored apply logs, newest first — the list view when no stack is named."""
    glob = "kwisatz-*.log" if not target else f"kwisatz-*-{target}.log"
    out = []
    for path in sorted(logs_dir.glob(glob), reverse=True)[:limit]:
        try:
            stat = path.stat()
            size = stat.st_size
        except OSError:
            continue
        name = path.name[len("kwisatz-") : -len(".log")]
        stamp, _, target_name = name.rpartition("-")
        out.append({"path": str(path), "target": target_name, "started_at": stamp, "bytes": size})
    return out


def tail(path: Path, lines: int) -> list[str]:
    try:
        with path.open(errors="replace") as handle:
            handle.seek(0, 2)
            handle.seek(max(0, handle.tell() - 64 * 1024))
            data = handle.read().splitlines()
    except OSError:
        return []
    return data[-lines:]


def stream(argv: list[str], timeout: float) -> subprocess.CompletedProcess:
    """Pass the log tool's stdout straight through (R-OUT-004: do not re-format logs)."""
    return subprocess.run(argv, timeout=timeout, check=False)


def stream_argv(source: LogSource, *, tail: int | None, since: str | None, follow: bool) -> list[str]:
    """The same request in each tool's dialect: `journalctl -n`, `compose --tail`, `-f`/`--follow`.

    Handing `--tail` to `journalctl` (or `-n` to compose) is precisely the bug that makes a log
    command work on one box and die on the next, so the dialect is decided once, here.
    """
    argv = list(source.argv or [])
    if not argv:
        return argv
    if source.kind == JOURNAL:
        if since:
            argv = [*argv, "--since", str(since)]
        if tail:
            argv = [*argv, "-n", str(tail)]
        if follow:
            argv = [*argv, "-f"]
    elif source.kind == DOCKER:
        if since:
            argv = [*argv, "--since", str(since)]
        if tail is not None:
            argv = [*argv, "--tail", str(tail)]
        if follow:
            argv = [*argv, "--follow"]
    return argv


def capture(argv: list[str], timeout: float) -> str:
    """Stdout of the log tool, for `--json` (`--follow` would never finish, so it is dropped).

    Only a *trailing* follow flag may go: compose spells its config-file flag `-f <file>`, and
    dropping that one leaves `docker compose <file> logs …`, which answers with its usage text
    instead of the stack's logs. The follow flag is always last, so that is the only position
    to pop.
    """
    argv = list(argv)
    while argv and argv[-1] in ("-f", "--follow"):
        argv.pop()
    if not argv:
        return ""
    tool, *rest = argv
    try:
        done = subprocess.run([tool, *rest], capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout or ""
