"""Where a target's logs actually live (§6.7 R-OPS-005).

Three sources, chosen by what discovery found — never by a guess:

  docker   `docker compose -f <stack>/docker-compose.yml logs …`
  systemd  `journalctl -u <unit> …`
  else     the newest `logs/kwisatz-<ts>-<target>.log` the last apply wrote

The last one is what makes `kwisatz logs <unconfigured-script>` useful: task scripts are
the implementation, and their stdout is already captured there (R-SAFE-007, mode 0600).
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import services as serviceio

DOCKER = "docker"
JOURNAL = "journal"
APPLY_LOG = "apply-log"

#: The units both log tools agree on, in seconds (`1d` is what a compose `--since` accepts too).
_DURATION_UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400}
_DURATION = re.compile(r"^(?:\d+[smhd])+$", re.IGNORECASE)
_DURATION_TOKEN = re.compile(r"(\d+)([smhd])", re.IGNORECASE)


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
    """Pass the log tool's stdout straight through (R-OUT-004: do not re-format logs).

    `subprocess.run` answers a spent deadline by raising, and nobody caught it: the follow the
    spec promises (R-OPS-005: "`-f` is bounded by `--timeout`") ended in a traceback. The bound
    is reported the same way `exec.RunResult` reports it — a process that finished without ever
    handing us a code (`returncode=None`) — because that is the truth, and `cmd_logs` decides
    what it means for the exit code.
    """
    try:
        return subprocess.run(argv, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(argv, returncode=None)


def journal_since(value: str) -> str:
    """`10m` → `10 minutes ago`; any other spelling is passed through untouched.

    `--since 10m` is compose's dialect and the spec's own example, so the same command works on
    a stack and dies on a unit: `journalctl` parses no relative shorthand and answers
    `Failed to parse timestamp: 10m` with exit 1. What systemd 255 does parse is the human
    phrasing below, so a bare duration becomes that, and an ISO timestamp (or `now`, which
    means the same thing to both tools) is handed on unchanged.
    """
    text = value.strip()
    if not _DURATION.match(text):
        return value
    total = sum(int(count) * _DURATION_UNITS[unit.lower()] for count, unit in _DURATION_TOKEN.findall(text))
    for unit, seconds in (("day", 86400), ("hour", 3600), ("minute", 60)):
        if total and total % seconds == 0:
            return _ago(total // seconds, unit)
    return _ago(total, "second")


def _ago(count: int, unit: str) -> str:
    return f"{count} {unit}{'s' if count != 1 else ''} ago"


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
            argv = [*argv, "--since", journal_since(str(since))]
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
