"""exec.py: what a task script actually gets, and what kwisatz does with what comes back.

The runner is the half of the CLI that touches a running machine, so every test asserts an
observable: a recorded environment, a real timeout that kills a real process group, a real
log file with a real mode.
"""

from __future__ import annotations

import stat
import sys

from kwisatz import exec as runner
from kwisatz.orchestrator import Task


def task(argv, **kwargs):
    env = kwargs.pop("env", {"INTERACTIVE": "false"})
    return Task(name="t", argv=argv, env=env, **kwargs)


def test_child_env_strips_the_venv_and_applies_the_task_env(monkeypatch):
    monkeypatch.setenv("VIRTUAL_ENV", "/some/project/.venv")
    monkeypatch.setenv("PATH", f"{sys.prefix}/bin:/usr/bin:/bin")
    env = runner.child_env(task([], env={"INTERACTIVE": "false", "KEY": "value"}))
    assert "VIRTUAL_ENV" not in env
    assert f"{sys.prefix}/bin" not in env["PATH"]
    assert env["KEY"] == "value"
    assert env["INTERACTIVE"] == "false"


def test_extra_env_wins_and_interactive_asks_for_a_terminal():
    env = runner.child_env(task([], env={"INTERACTIVE": "false"}), extra={"KEY": "cli"}, interactive=True)
    assert env["KEY"] == "cli"
    assert env["INTERACTIVE"] == "true"


def test_run_streams_stdout_and_writes_a_0600_log(tmp_path):
    log = tmp_path / "logs" / "run.log"
    result = runner.run_task(
        task([sys.executable, "-c", "print('one'); print('two')"]),
        root=tmp_path,
        log_path=log,
        timeout=30,
    )
    assert result.returncode == 0
    assert result.stdout_tail == ["one", "two"]
    assert stat.S_IMODE(log.stat().st_mode) == 0o600
    assert log.read_text() == "one\ntwo\n"


def test_a_script_sees_devnull_on_stdin_and_the_env_it_was_given(tmp_path):
    marker = tmp_path / "out.txt"
    script = tmp_path / "probe.sh"
    script.write_text(
        f"#!/bin/bash\nprintf 'stdin=%s key=%s\\n' \"$(readlink /proc/self/fd/0)\" \"$KEY\" > {marker}\n"
    )
    script.chmod(0o755)
    runner.run_task(
        task(["bash", str(script)], env={"INTERACTIVE": "false", "KEY": "abc"}),
        root=tmp_path,
        timeout=30,
        echo_stdout=False,
    )
    assert marker.read_text().strip() == "stdin=/dev/null key=abc"


def test_echo_stdout_false_keeps_the_output_out_of_stdout(capsys, tmp_path):
    runner.run_task(
        task([sys.executable, "-c", "print('quietly')"]), root=tmp_path, echo_stdout=False, timeout=30
    )
    assert "quietly" not in capsys.readouterr().out


def test_timeout_kills_the_whole_process_group(tmp_path):
    script = tmp_path / "slow.sh"
    script.write_text("#!/bin/bash\nsleep 30 & wait\n")
    script.chmod(0o755)
    result = runner.run_task(
        task(["bash", str(script)]), root=tmp_path, timeout=1.0, echo_stdout=False, heartbeat=0.0
    )
    assert result.timed_out is True
    assert result.returncode is None


def test_a_missing_interpreter_is_127_not_a_traceback(tmp_path):
    result = runner.run_task(task(["definitely-not-a-binary"]), root=tmp_path, timeout=10)
    assert result.returncode == 127


def test_stdout_tail_is_capped_to_the_last_lines(tmp_path):
    result = runner.run_task(
        task([sys.executable, "-c", "for i in range(200): print(i)"]), root=tmp_path, timeout=30
    )
    assert len(result.stdout_tail) <= 80
    assert result.stdout_tail[-1] == "199"


def test_inherit_stdio_lets_the_script_own_the_terminal(tmp_path):
    """`run` must not swallow the script's stdout into a pipe it never reads (R-JSON-001)."""
    result = runner.run_task(
        task([sys.executable, "-c", "print('through')"]), root=tmp_path, timeout=10, inherit_stdio=True
    )
    assert result.returncode == 0
    assert result.stdout_tail == []
