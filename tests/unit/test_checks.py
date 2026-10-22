"""checks.py — the host facts `doctor` branches on, and the exit code they imply.

The OS case is the one that matters: a release our own VM suite boots by default must not
read as "this box cannot run kwisatz yet" (exit 4), because that tells an agent to stop on a
box where every script installs cleanly.
"""

from __future__ import annotations

from kwisatz import checks


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
