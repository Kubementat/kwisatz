"""Running things: the environment contract, stdin, streaming, timeouts.

Two runners, one contract. `run_deploy()` is what `apply` uses: pyinfra runs the task
through `deploy.py`, so the command and the environment are pyinfra's
(`repo.py:deploy_argv()`). `run_task()` is the direct script run behind `run`,
`--interactive` and `models sync`; it applies what `orchestrator.Task` describes and nothing
else — no `apt`, no `docker`, no `/srv` writes (R-SAFE-003: only the task scripts change the
machine). Both go through the same `_execute`, so streaming, log mode and the process-group
timeout cannot differ between them.

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
from .orchestrator import Task


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
    """Direct execution of one task script — `kwisatz run`, and `apply --interactive`.

    Everything else that runs a task goes through `run_deploy()`: pyinfra executes the
    command, and this function only hands the child the environment the contract says
    (`child_env`: ambient, venv stripped, `INTERACTIVE` then config `env:`, then `--env`).
    """
    env = child_env(task, interactive=interactive, extra=extra_env)
    # R-APP-013: interactive means the operator gets the script's own prompts, live, on
    # this terminal, so nothing is captured and stdin is not /dev/null. `run` uses the
    # same fd inheritance (R-JSON-001's exception) without forcing INTERACTIVE=true.
    capture = not (interactive or inherit_stdio)
    stdin = subprocess.DEVNULL if capture and task.stdin == orchestrator.STDIN_NULL else None
    return _execute(
        task.argv,
        cwd=root,
        env=env,
        stdin=stdin,
        capture=capture,
        log_path=log_path,
        timeout=timeout,
        echo_stdout=echo_stdout,
        heartbeat=heartbeat,
        on_heartbeat=on_heartbeat,
    )


def run_deploy(
    *,
    argv: list[str],
    root: Path,
    env: dict[str, str],
    log_path: Path | None = None,
    timeout: float = 3600.0,
    echo_stdout: bool = True,
    heartbeat: float = 3.0,
    on_heartbeat=None,
) -> RunResult:
    """One pyinfra deploy of one or more targets (`deploy.py -y -vvv --data select=…`).

    This is how `kwisatz apply` runs a task: the same deploy `run-setup.sh apply` runs,
    so the command, the environment and the `/dev/null` stdin are pyinfra's, not the
    CLI's. pyinfra writes its whole report — including what the task script printed — to
    *stderr*, which is what `run-setup.sh` does today: a piped `kwisatz apply` gets no
    task output on stdout. The log copy under `log_path` is what makes that recoverable
    (R-OUT-004), and `kwisatz logs <target>` reads it.
    """
    return _execute(
        argv,
        cwd=root,
        env=env,
        stdin=None,
        capture=True,
        log_path=log_path,
        timeout=timeout,
        echo_stdout=echo_stdout,
        heartbeat=heartbeat,
        on_heartbeat=on_heartbeat,
    )


def deploy_env(repo_path: Path) -> dict[str, str]:
    """The environment of the pyinfra process itself.

    `strip_venv_from_environ` keeps `deploy.py` from handing its own venv to the tasks;
    `<repo>/src` goes onto `PYTHONPATH` so `deploy.py` can import `kwisatz.orchestrator`
    in a checkout that has not been `uv sync`-ed. Task scripts never see either: the
    adapter strips both again before it builds their environment.
    """
    env = dict(os.environ)
    orchestrator.strip_venv_from_environ(env)
    src = repo_path / "src"
    if src.is_dir():
        env["PYTHONPATH"] = os.pathsep.join(filter(None, [str(src), env.get("PYTHONPATH", "")]))
    return env


def _execute(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    stdin,
    capture: bool,
    log_path: Path | None,
    timeout: float,
    echo_stdout: bool,
    heartbeat: float,
    on_heartbeat,
) -> RunResult:
    """Spawn, stream, and bound one child process. Both runners above come through here."""
    started = time.monotonic()
    tail: deque[str] = deque(maxlen=TAIL_LINES * 2)
    tail_bytes = 0
    handle = _open_log(log_path)
    stdout = subprocess.PIPE if capture else None
    # pyinfra writes its whole report — the task script's own output included — to *stderr*, so a
    # log copied from stdout alone is an empty file: `kwisatz logs <target>` then says nothing
    # exactly when a run failed. stderr is piped only when there is a log to copy it into, so a
    # run without a log keeps inheriting it instead of losing output.
    stderr = subprocess.PIPE if (stdout is not None and handle) else None
    try:
        proc = subprocess.Popen(
            argv,
            cwd=str(cwd),
            env=env,
            stdin=stdin,
            stdout=stdout,
            stderr=stderr,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
    except OSError:  # tasks/<name>.sh not executable, bash missing, …
        if handle:
            handle.close()
        return RunResult(returncode=127, duration_ms=_ms(started), stdout_tail=[], log_path=_name(log_path))

    timed_out = False
    try:
        if stdout is None:
            _reap(proc, timeout)
        else:
            streams = [(proc.stdout, _OUT)] + ([(proc.stderr, _ERR)] if proc.stderr is not None else [])
            _drain(proc, streams, handle, echo_stdout, tail, started, timeout, heartbeat, on_heartbeat)
            # EOF is not the same instant as the exit. Draining stops when the pipe closes, which
            # can be milliseconds before bash finishes exit processing — reading poll() there
            # answers None, and the old `else 1` reported "script exited 1" for a script that
            # exited 0 (reproduced on a VM: ~1 in 6 `apply setup-traefik` runs failed this way).
            _reap(proc, max(0.0, timeout - (time.monotonic() - started)))
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


# where a child pipe belongs: its own terminal stream, never the other one
_OUT = "stdout"
_ERR = "stderr"


def _drain(proc, streams, handle, echo: bool, tail: deque[str], started: float, timeout: float,
           heartbeat: float, on_heartbeat) -> None:
    """Read every open child pipe without deadlocking, and copy each line into the log.

    A line goes to the terminal stream it arrived on — stdout to stdout (only when `echo`
    says the run is interactive enough to want it, R-JSON-001's stdout belongs to the
    document otherwise), stderr to stderr, which is where `run-setup.sh` always put progress
    (R-OUT-002). The log gets both, which is what lets `kwisatz logs <target>` answer a failed
    deploy instead of printing nothing.
    """
    last_seen = time.monotonic()
    open_streams = dict(streams)
    while open_streams:
        remaining = timeout - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutExpired
        try:
            ready, _, _ = select.select(list(open_streams), [], [], min(0.5, remaining))
        except (OSError, ValueError):  # closed / redirected pipe
            break
        for stream in ready:
            line = stream.readline()
            if not line:
                open_streams.pop(stream)  # this pipe reached EOF
                continue
            _forward(line, open_streams[stream], handle, echo, tail)
            last_seen = time.monotonic()
        if ready:
            continue
        if proc.poll() is not None:
            break
        if heartbeat and time.monotonic() - last_seen >= heartbeat:
            last_seen = time.monotonic()
            if on_heartbeat:
                on_heartbeat(int(time.monotonic() - started), proc.pid)
    # flush whatever the wrapper already pulled off the pipe
    for stream, dest in streams:
        if stream.closed:
            continue
        try:
            for line in stream:
                _forward(line, dest, handle, echo, tail)
        except (OSError, ValueError):  # the pipe went away mid-flush
            break


def _forward(line: str, dest: str, handle, echo: bool, tail: deque[str]) -> None:
    if dest is _OUT and echo:
        sys.stdout.write(line)
        sys.stdout.flush()
    elif dest is _ERR:
        sys.stderr.write(line)
        sys.stderr.flush()
    if handle:
        handle.write(line)
        handle.flush()
    if dest is _OUT:
        tail.append(line.rstrip("\n"))


def _reap(proc, timeout: float) -> None:
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        raise TimeoutExpired from None


def _returncode(proc) -> int | None:
    """The child's own status, or None when it never one.

    Never a made-up number: an exit status we could not observe has to look like exactly that,
    not like a script that failed. A signal reports 128+n, the shell convention, because -9
    would otherwise be read as exit code 9, which this CLI reserves for a held lock.
    """
    code = proc.returncode
    if code is None:
        return None
    return 128 + abs(code) if code < 0 else code


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
