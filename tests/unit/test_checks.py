"""checks.py — the host facts `doctor` branches on, and the exit code they imply.

The OS case is the one that matters: a release our own VM suite boots by default must not
read as "this box cannot run kwisatz yet" (exit 4), because that tells an agent to stop on a
box where every script installs cleanly.

Port collisions are the other half, and the only half `doctor` has to offer before twenty
minutes of install work — so they are asserted here, on synthetic configs and services, not
through a live docker daemon.
"""

from __future__ import annotations

import subprocess
from types import SimpleNamespace

from kwisatz import checks
from kwisatz import exec as runner


def os_release(tmp_path, pretty: str, id_: str = "ubuntu", version: str = "26.04"):
    path = tmp_path / "os-release"
    path.write_text(f'ID={id_}\nVERSION_ID="{version}"\nPRETTY_NAME="{pretty}"\n')
    return path


def test_the_release_the_vm_suite_boots_is_not_a_failure(tmp_path):
    check = checks.os_check(os_release(tmp_path, "Ubuntu 26.04.1 LTS", version="26.04"))
    assert check.ok is True
    assert check.required is True  # supported, so it counts


def test_an_untested_ubuntu_release_warns_but_never_stops_the_run(tmp_path):
    check = checks.os_check(os_release(tmp_path, "Ubuntu 27.04", version="27.04"))
    assert check.ok is False
    assert check.required is False, "an untested release must not raise the exit code to 4"
    assert "tested set" in check.hint


def test_a_non_ubuntu_box_is_a_real_stop(tmp_path):
    check = checks.os_check(os_release(tmp_path, "Fedora 44", id_="fedora", version="44"))
    assert check.ok is False
    assert check.required is True, "the task scripts are apt-based; this box genuinely cannot run them"


def test_a_missing_os_release_is_reported_not_raised(tmp_path):
    check = checks.os_check(tmp_path / "absent")
    assert check.ok is False and check.required is True


# ── port collisions: `doctor`'s main value, asserted nowhere until now ─────────────────────


class Service:
    """Just enough of `services.Service` for `port_conflicts`: a name and what it publishes."""

    def __init__(self, name: str, ports: list[int]) -> None:
        self.name = name
        self._ports = ports

    def as_dict(self) -> dict:
        return {"name": self.name, "ports": list(self._ports)}


def config_of(tmp_path, text: str):
    from kwisatz import orchestrator

    path = tmp_path / "machine-config.yml"
    path.write_text(text)
    return orchestrator.load_config(path, tmp_path)


def test_two_targets_want_the_same_port_is_a_conflict(tmp_path):
    """Both values live in different entries, so a config review cannot see it coming."""
    config = config_of(
        tmp_path,
        "version: 1\nscripts:\n"
        "  setup-a:\n    enabled: true\n    env:\n      A_PORT: 8080\n"
        "  setup-b:\n    enabled: true\n    env:\n      B_PORT: 8080\n",
    )
    found = checks.port_conflicts(config, [])
    assert [c.ok for c in found] == [False]
    assert "8080/tcp" in found[0].detail
    assert "setup-a" in found[0].detail and "setup-b" in found[0].detail
    assert found[0].required is False, "a port clash is a `5`, never a `4`"


def test_a_port_something_else_already_has_is_a_conflict_even_in_one_entry(tmp_path):
    config = config_of(tmp_path, "version: 1\nscripts:\n  setup-a:\n    enabled: true\n    env:\n      A_PORT: 9000\n")
    found = checks.port_conflicts(config, [Service("ollama", [9000])])
    assert [c.detail for c in found] == ["9000/tcp is already published by ollama"]
    assert "change *_PORT for setup-a" in found[0].hint, "the fix is on the config's side, not the running stack's"


def test_re_applying_the_target_that_owns_the_port_is_not_a_conflict(tmp_path):
    """The converge case: the stack is about to be brought back by its own target."""
    config = config_of(tmp_path, "version: 1\nscripts:\n  setup-a:\n    enabled: true\n    env:\n      A_PORT: 9000\n")
    assert checks.port_conflicts(config, [Service("setup-a", [9000])]) == []


def test_a_disabled_entry_cannot_conflict_and_a_non_port_env_cannot_either(tmp_path):
    config = config_of(
        tmp_path,
        "version: 1\nscripts:\n"
        "  setup-a:\n    enabled: false\n    env:\n      A_PORT: 8080\n"
        "  setup-b:\n    enabled: true\n    env:\n      PLAIN: 8080\n      NOT_A_PORT: x\n",
    )
    assert checks.port_conflicts(config, [Service("whatever", [8080])]) == []


def test_the_child_probe_copies_the_conditions_a_task_script_runs_under(monkeypatch):
    """A ticket that reads valid here can be worthless there, so the probe must not be the same.

    The assertion is written against `exec.OWN_PGID` rather than against a flag of its own, so the
    probe cannot drift from how a deploy is actually spawned: that drift is what used to let the
    check report a usable sudo that the scripts then could not use.
    """
    seen = {}

    def run(argv, **kwargs):  # noqa: ANN001
        seen["argv"] = list(argv)
        seen.update(kwargs)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(checks.subprocess, "run", run)
    assert checks.child_sudo_works() is True
    assert seen["argv"] == ["sudo", "-n", "true"]
    assert seen["stdin"] == subprocess.DEVNULL, seen
    assert "start_new_session" not in seen, "a new session throws the primed ticket away"
    assert {k: v for k, v in seen.items() if k not in ("argv", "timeout", "capture_output", "check")} == {
        "stdin": subprocess.DEVNULL,
        **runner.OWN_PGID,
    }, seen


def test_a_ticket_that_only_this_terminal_can_use_is_no_ticket_for_an_apply(monkeypatch):
    """Ticket keyed to this session, and sudo still asks there: the doctor must not call that usable."""
    monkeypatch.setattr(checks, "has_sudo", lambda: True)
    monkeypatch.setattr(checks, "child_sudo_works", lambda: False)
    assert checks.sudo_ticket_for_scripts() is False
    sudo = next(c for c in checks.host_checks() if c.name == "sudo")
    assert sudo.ok is False, "doctor must not call this a usable sudo"
    assert "session" in sudo.detail

