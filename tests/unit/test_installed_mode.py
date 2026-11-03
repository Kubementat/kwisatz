"""Phase 2: installed mode — payload inside the package, config and state outside it."""

from __future__ import annotations

import json
import os
import stat

import pytest
from conftest import REPO_ROOT

from kwisatz import cli
from kwisatz import repo as repoio
from kwisatz.errors import CliError


@pytest.fixture
def installed(tmp_path, monkeypatch):
    """A fake payload plus XDG dirs in tmp; cwd and HOME are outside any checkout."""
    payload = tmp_path / "payload"
    (payload / "tasks").mkdir(parents=True)
    (payload / "deploy.py").write_text((REPO_ROOT / "deploy.py").read_text())
    (payload / "machine-config.yml.example").write_text("version: 1\nscripts:\n  stub-a:\n    enabled: true\n")
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.delenv("KWISATZ_REPO", raising=False)
    monkeypatch.delenv("KWISATZ_CONFIG", raising=False)
    monkeypatch.delenv("KWISATZ_HOME", raising=False)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(home / "cfg"))
    monkeypatch.setenv("XDG_STATE_HOME", str(home / "state"))
    monkeypatch.setattr(repoio, "payload_dir", lambda: payload)
    monkeypatch.setattr(repoio, "CONFIG_JSON", home / "cfg" / "kwisatz" / "config.json")
    work = tmp_path / "elsewhere"
    work.mkdir()
    return payload, home, work


def test_no_checkout_falls_back_to_the_payload(installed):
    payload, home, work = installed
    repo = repoio.resolve_repo(start=work)
    assert repo.mode == "installed"
    assert repo.path == repo.payload == payload
    assert repo.config_dir == home / "cfg" / "kwisatz"
    assert repo.work == home / "state" / "kwisatz"
    assert repo.logs == home / "state" / "kwisatz" / "logs"
    assert repoio.resolve_config(repo) == home / "cfg" / "kwisatz" / "machine-config.yml"


def test_kwisatz_home_moves_the_config_dir_only(installed, monkeypatch, tmp_path):
    monkeypatch.setenv("KWISATZ_HOME", str(tmp_path / "kh"))
    repo = repoio.resolve_repo(start=tmp_path)
    assert repo.config_dir == (tmp_path / "kh").resolve()
    assert repo.work == installed[1] / "state" / "kwisatz"


def test_a_checkout_beats_the_payload_and_keeps_todays_layout(installed, repo):
    resolved = repoio.resolve_repo(start=repo.path)
    assert resolved.mode == "checkout"
    assert resolved.config_dir == resolved.path == repo.path
    assert resolved.work == repo.path / ".kwisatz"
    assert resolved.logs == repo.path / "logs"
    assert repoio.resolve_config(resolved) == repo.path / "machine-config.yml"


def test_an_explicit_bad_repo_still_fails_instead_of_using_the_payload(installed, tmp_path):
    with pytest.raises(CliError):
        repoio.resolve_repo(str(tmp_path / "nope"), start=tmp_path)


def test_without_a_payload_the_old_error_stays(installed, monkeypatch, tmp_path):
    monkeypatch.setattr(repoio, "payload_dir", lambda: tmp_path / "missing")
    with pytest.raises(CliError, match="no kwisatz checkout found"):
        repoio.resolve_repo(start=installed[2])


def test_machine_lock_spans_checkout_and_installed_runs(installed, repo):
    checkout = repoio.resolve_repo(start=repo.path)
    machine = repoio.state_home() / "lock"
    with repoio.held(checkout):
        assert machine.is_file()
        other = repoio.Lock(repoio.resolve_repo(start=installed[2]))
        assert other.try_acquire() is False  # an installed-mode run is shut out
    assert not machine.exists()


def test_installed_mode_takes_its_one_lock_once(installed):
    repo = repoio.resolve_repo(start=installed[2])
    with repoio.held(repo):  # would deadlock/raise if the same file were taken twice
        assert (repo.work / "lock").is_file()
    assert not (repo.work / "lock").exists()


def test_init_writes_into_the_config_dir_private(installed, monkeypatch):
    payload, home, work = installed
    monkeypatch.chdir(work)
    monkeypatch.setattr(cli, "cmd_doctor", lambda app: 0)
    assert cli.main(["init", "--json"]) == 0
    target = home / "cfg" / "kwisatz" / "machine-config.yml"
    assert "stub-a" in target.read_text()
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert stat.S_IMODE(target.parent.stat().st_mode) == 0o700
    target.write_text("keep: me\n")
    assert cli.main(["init", "--json"]) == 0
    assert target.read_text() == "keep: me\n"  # never overwritten without --force


def test_task_env_names_the_config_dir_in_installed_mode(installed, monkeypatch):
    monkeypatch.delenv("KWISATZ_CONFIG_DIR", raising=False)
    monkeypatch.chdir(installed[2])
    monkeypatch.setattr(cli, "cmd_doctor", lambda app: 0)
    assert cli.main(["init", "--json"]) == 0
    assert os.environ.pop("KWISATZ_CONFIG_DIR") == str(installed[1] / "cfg" / "kwisatz")


def test_install_is_a_noop_in_installed_mode(installed, monkeypatch, capsys):
    monkeypatch.chdir(installed[2])
    assert cli.main(["install", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["result"]["installed"] is True


def test_init_import_validates_then_copies(installed, monkeypatch, tmp_path):
    payload, home, work = installed
    monkeypatch.chdir(work)
    monkeypatch.setattr(cli, "cmd_doctor", lambda app: 0)
    (payload / "tasks" / "stub-a.sh").write_text("#!/bin/sh\n")
    bad = tmp_path / "bad.yml"
    bad.write_text("nothing: here\n")
    assert cli.main(["init", "--import", str(bad), "--json"]) == 3
    good = tmp_path / "good.yml"
    good.write_text("scripts:\n  stub-a:\n    enabled: true\n")
    assert cli.main(["init", "--import", str(good), "--json"]) == 0
    assert (home / "cfg" / "kwisatz" / "machine-config.yml").read_text() == good.read_text()


def test_envelope_reports_mode_and_locations(installed, monkeypatch, capsys):
    monkeypatch.chdir(installed[2])
    cli.main(["install", "--json"])
    repo = json.loads(capsys.readouterr().out)["repo"]
    assert repo["mode"] == "installed"
    assert repo["config_dir"] == str(installed[1] / "cfg" / "kwisatz")
    assert repo["state"] == str(installed[1] / "state" / "kwisatz")


def test_the_version_has_one_source():
    import re

    import tomllib

    project = tomllib.loads((REPO_ROOT / "pyproject.toml").read_text())
    assert "version" in project["project"]["dynamic"]
    assert project["tool"]["hatch"]["version"]["path"] == "src/kwisatz/__init__.py"
    assert re.search(r'^__version__ = "', (REPO_ROOT / "src/kwisatz/__init__.py").read_text(), re.M)
