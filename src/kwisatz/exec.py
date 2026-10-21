"""Running a task: the environment contract, stdin, streaming, timeouts.

The runner applies what `orchestrator.Task` describes and nothing else — no `apt`, no
`docker`, no `/srv` writes (R-SAFE-003: only the task scripts change the machine).

Output rules it implements:
  * non-JSON runs stream the script's stdout through unchanged (R-OUT-004) and write a
    full copy to `logs/…`; `--json` keeps it out of stdout entirely (R-JSON-001) and
    reports a capped tail instead (R-JSON-011);
  * an idle script says so (`still running … 312 s · pid 4242`) rather than looking
    hung (R-OUT-005);
  * the wall-clock budget kills the whole process group, so a `docker compose up`
    cannot outlive the command (R-AGE-002).
"""

from __future__ import annotations

import os
import select
import signal
import subprocess
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

from . import orchestrator
from .jsonio import TAIL_BYTES, TAIL_LINES
from .orchestrator import STDIN_INHERIT, Task


@dataclass
class RunResult:
    returncode: int | None
    duration_ms: int
    timed_out: bool = False
    stdout_tail: list[str] = field(default_factory=list)
    log_path: str | None = None


def child_env(
    task: Task, *, interactive: bool = False, extra: dict[str, str] | None = None
) -> dict[str, str]:
    """Ambient environment, venv stripped, task env, then `--env` overrides.

    The venv strip is the same call deploy.py makes on `os.environ`, so both entry
    points hand the script the same `PATH` and no `VIRTUAL_ENV`.
    """
    env = dict(os.environ)
    orchestrator.strip_venv_from_environ(env)
    env.update(task.env)
    if extra:
        env.update(extra)
    if interactive:
        env["INTERACTIVE"] = "true"
    return env


def run_task(
    task: Task,
    *,
    root: Path,
    interactive: bool = False,
    extra_env: dict[str, str] | None = None,
    log_path: Path | None = None,
    timeout: float = 3600.0,
    echo_stdout: bool = True,
    heartbeat: float = 3.0,
    on_heartbeat=None,
    inherit_stdio: bool = False,
) -> RunResult:
    started = time.monotonic()
    env = child_env(task, interactive=interactive, extra=extra_env)
    stdin = subprocess.DEVNULL if task.stdin == orchestrator.STDIN_NULL else None
    if interactive or inherit_stdio:
        # R-APP-013: the operator gets the script's own prompts, live, on this terminal.
        # `run` uses the same fd inheritance (R-JSON-001's exception) without forcing
        # INTERACTIVE=true, which is only what --interactive means.
        stdin, stdout = None, None
    else:
        stdout = subprocess.PIPE
    tail: deque[str] = deque(maxlen=TAIL_LINES * 2)
    tail_bytes = 0

    handle = _open_log(log_path)
    try:
        proc = subprocess.Popen(
            task.argv,
            cwd=str(root),
            env=env,
            stdin=stdin,
            stdout=stdout,
            stderr=None,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
    except OSError as e:  # tasks/<name>.sh not executable, bash missing, …
        if handle:
            handle.close()
        return RunResult(returncode=127, duration_ms=_ms(started), stdout_tail=[], log_path=_name(log_path))

    timed_out = False
    try:
        if stdout is None:
            _reap(proc, timeout)
        else:
            _drain(proc, proc.stdout, handle, echo_stdout, tail, started, timeout, heartbeat, on_heartbeat)
    except TimeoutExpired:
        timed_out = True
        _kill(proc)
    finally:
        if handle:
            handle.close()
    return RunResult(
        returncode=None if timed_out else _returncode(proc),
        duration_ms=_ms(started),
        timed_out=timed_out,
        stdout_tail=_cap(tail, tail_bytes),
        log_path=_name(log_path),
    )


class TimeoutExpired(Exception):
    pass


def _drain(proc, stream, handle, echo: bool, tail: deque[str], started: float, timeout: float,
           heartbeat: float, on_heartbeat) -> None:
    last_seen = time.monotonic()
    while True:
        remaining = timeout - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutExpired
        try:
            ready, _, _ = select.select([stream], [], [], min(0.5, remaining))
        except (OSError, ValueError):  # closed / redirected pipe
            break
        if ready:
            line = stream.readline()
            if not line:
                break
            if echo:
                sys.stdout.write(line)
                sys.stdout.flush()
            if handle:
                handle.write(line)
                handle.flush()
            tail.append(line.rstrip("\n"))
            last_seen = time.monotonic()
        elif proc.poll() is not None:
            break
        elif heartbeat and time.monotonic() - last_seen >= heartbeat:
            last_seen = time.monotonic()
            if on_heartbeat:
                on_heartbeat(int(time.monotonic() - started), proc.pid)
    # flush whatever is still buffered in the pipe
    for line in stream:
        if echo:
            sys.stdout.write(line)
        if handle:
            handle.write(line)
        tail.append(line.rstrip("\n"))


def _reap(proc, timeout: float) -> None:
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        raise TimeoutExpired from None


def _returncode(proc) -> int:
    code = proc.poll()
    return -code if code is not None and code < 0 else (code if code is not None else 1)


def _kill(proc) -> None:
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (OSError, ProcessLookupError):
        proc.kill()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:  # pragma: no cover — SIGKILL does not ignore
        pass


def _ms(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


def _cap(lines: list[str] | deque[str], _unused: int) -> list[str]:
    kept: list[str] = []
    total = 0
    for line in reversed(list(lines)):
        total += len(line) + 1
        if total > TAIL_BYTES or len(kept) >= TAIL_LINES:
            break
        kept.append(line)
    return list(reversed(kept))


def _open_log(path: Path | None):
    """R-SAFE-007: task logs are 0600, because script output is not scrubbed."""
    if path is None:
        return None
    path.parent.mkdir(mode=0o700, exist_ok=True)
    handle = path.open("w", encoding="utf-8")
    os.chmod(path, 0o600)
    return handle


def _name(path: Path | None) -> str | None:
    return str(path) if path else None
