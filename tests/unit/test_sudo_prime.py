"""kwisatz needs sudo, so `apply` gets the ticket before the first script runs.

§9 / R-SAFE-006: no task script can ask for the password (`exec.py` runs the deploy in a new session
with `/dev/null` on stdin), so the ticket has to exist first and be valid *for the scripts*, not
just for this shell. These tests assert the decisions — asked once, never in `--json`, and what each
failure says — which is why they run in-process against the helper rather than through a child CLI.
"""

from __future__ import annotations

import argparse
from types import SimpleNamespace

import pytest

from kwisatz import cli
from kwisatz.errors import Exit
from kwisatz.output import Out


def app(*, json: bool = False, warmup: bool = True) -> cli.App:
    return cli.App(args=argparse.Namespace(no_sudo_warmup=not warmup), out=Out(json=json, color=False))


@pytest.fixture
def box(monkeypatch):
    """A box whose `sudo` wants a password: no ticket anywhere, `sudo` is a recorder.

    `held_here` is what `sudo -n true` answers in this process and `visible` what it answers the way
    a task script runs — they come apart on a box that keys tickets on the terminal.
    """
    state = {"held_here": False, "visible": False, "prompt_rc": 0, "keepalive": 0, "tty": True}
    calls: list[list[str]] = []

    def run(argv, **kwargs):  # noqa: ANN001
        argv = list(argv)
        calls.append(argv)
        if "-v" not in argv:  # nothing here probes sudo; only the prompt reaches a subprocess
            return SimpleNamespace(returncode=1, stdout="", stderr="")
        if state["prompt_rc"]:
            return SimpleNamespace(returncode=state["prompt_rc"], stdout="", stderr="")
        state["held_here"] = state["visible"] = True
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.shutil, "which", lambda name: "/usr/bin/sudo" if name == "sudo" else None)
    monkeypatch.setattr(cli.subprocess, "run", run)
    monkeypatch.setattr(cli.sys.stdin, "isatty", lambda: state["tty"], raising=False)
    monkeypatch.delenv("SUDO_ASKPASS", raising=False)
    monkeypatch.setattr(cli.checks, "has_sudo", lambda: state["held_here"])
    monkeypatch.setattr(cli.checks, "sudo_ticket_for_scripts", lambda: state["visible"])
    monkeypatch.setattr(cli, "_keep_sudo_alive", lambda: state.__setitem__("keepalive", state["keepalive"] + 1))
    return SimpleNamespace(state=state, calls=calls, monkeypatch=monkeypatch)


def prompted(calls: list[list[str]]) -> list[list[str]]:
    return [c for c in calls if "-v" in c]


def test_a_stale_ticket_gets_exactly_one_prompt(box):
    cli._prepare_sudo(app())
    assert prompted(box.calls) == [["sudo", "-v"]]
    assert box.state["keepalive"] == 1


def test_an_already_usable_ticket_means_no_prompt(box):
    box.state["held_here"] = box.state["visible"] = True
    cli._prepare_sudo(app())
    assert box.calls == []
    assert box.state["keepalive"] == 1


def test_json_never_blocks_on_a_human(box):
    with pytest.raises(cli.CliError) as exc:
        cli._prepare_sudo(app(json=True))
    assert exc.value.code == Exit.PREREQUISITE
    assert prompted(box.calls) == [], "a machine consumer gets exit 4 and the hint, not a prompt"
    assert "sudo -v" in exc.value.hint


def test_no_terminal_says_so(box):
    box.state["tty"] = False
    with pytest.raises(cli.CliError) as exc:
        cli._prepare_sudo(app())
    assert prompted(box.calls) == []
    assert "no terminal is attached" in str(exc.value)


def test_a_refused_password_says_so(box):
    box.state["prompt_rc"] = 1
    with pytest.raises(cli.CliError) as exc:
        cli._prepare_sudo(app())
    assert "sudo rejected the password" in str(exc.value)
    assert box.state["keepalive"] == 0


def test_a_ticket_cached_for_this_session_only_gets_no_useless_prompt(box):
    """The failure the operator cannot see: valid in this shell, invisible to the scripts."""
    box.state["held_here"] = True
    with pytest.raises(cli.CliError) as exc:
        cli._prepare_sudo(app())
    assert prompted(box.calls) == [], "asking again cannot fix where the ticket is keyed"
    assert "session" in str(exc.value)


def test_a_successful_prime_that_the_scripts_cannot_use_names_the_failure(box):
    """The prime succeeded, the scripts still cannot sudo: say that, do not print `None`."""
    box.monkeypatch.setattr(cli, "_sudo_prime", lambda _app: None)
    with pytest.raises(cli.CliError) as exc:
        cli._prepare_sudo(app())
    assert "None" not in str(exc.value), exc.value
    assert "sudo accepted the password" in str(exc.value)


def test_no_sudo_warmup_leaves_sudo_alone_but_still_stops_the_run(box):
    with pytest.raises(cli.CliError) as exc:
        cli._prepare_sudo(app(warmup=False))
    assert box.calls == []
    assert "--no-sudo-warmup" in str(exc.value)


def test_a_missing_sudo_is_named(box):
    box.monkeypatch.setattr(cli.shutil, "which", lambda _name: None)
    with pytest.raises(cli.CliError) as exc:
        cli._prepare_sudo(app())
    assert "sudo is not installed" in str(exc.value)
    assert box.calls == []


def test_an_exported_askpass_answers_for_a_run_without_a_tty(box):
    box.monkeypatch.setenv("SUDO_ASKPASS", "/usr/local/bin/askpass")
    box.state["tty"] = False
    cli._prepare_sudo(app(json=True))
    assert prompted(box.calls) == [["sudo", "-A", "-v"]]
    assert box.state["keepalive"] == 1
