"""`apply` runs its targets through `deploy.py`, not through a bare script run.

That is the whole point of routing the CLI through pyinfra (§11.3, as revised): there is
one execution engine, so `kwisatz apply traefik` and `run-setup.sh apply` cannot install
something subtly different. The assertions are evidence-shaped — the *task script* records
its own ancestor chain, so the test reads who ran it instead of trusting what the CLI
printed — plus the `--data select=` contract `deploy.py` now has to honour.
"""

from __future__ import annotations

import sys

import pytest
from conftest import REPO_ROOT, run_cli, run_pyinfra, stub

import kwisatz.repo as repoio
from kwisatz.errors import CliError, Exit

CONFIG = """version: 1
scripts:
  stub-a:
    enabled: true
    description: A
  stub-b:
    enabled: false
  stub-c:
    enabled: true
"""

# walks up the process tree and records the command line of every ancestor, so the
# evidence is "who ran me", not "what was printed about me"
TRACING_STUB = """#!/usr/bin/env bash
rec="$(cd "$(dirname "$0")/.." && pwd)/records/{name}.txt"
mkdir -p "$(dirname "$rec")"
: > "$rec"
p=$PPID
for _ in 1 2 3 4 5 6; do
  ps -o args= -p "$p" >> "$rec" 2>/dev/null || break
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  [ -n "$p" ] && [ "$p" != 1 ] || break
done
"""


def tracing_stub(repo, name: str) -> None:
    path = repo / "tasks" / f"{name}.sh"
    path.write_text(TRACING_STUB.format(name=name))
    path.chmod(0o755)


def ran_by(root, name: str) -> tuple[str, str]:
    """(the script's nearest ancestor, every ancestor above it joined) — who ran me."""
    chain = [" ".join(line.split()) for line in (root / "records" / f"{name}.txt").read_text().splitlines() if line.strip()]
    return chain[0], " ".join(chain[1:])


def test_apply_hands_each_target_to_deploy_py(repo):
    """A run of `apply` is a pyinfra deploy of this checkout, not a `bash tasks/x.sh`."""
    tracing_stub(repo.path, "stub-a")
    repo.write_config("version: 1\nscripts:\n  stub-a:\n    enabled: true\n")

    result = run_cli("apply", "stub-a", "--repo", str(repo.path), repo=repo.path)
    assert result.returncode == 0, result.stderr

    parent, above = ran_by(repo.path, "stub-a")
    assert parent.startswith(("sh -c", "/bin/sh -c")), parent  # pyinfra's connector shell
    assert "pyinfra" in above and "deploy.py" in above, above
    assert "select=stub-a" in above, above


def test_full_apply_also_goes_through_the_deploy(repo):
    """§6.1: 'all configured automations' is the same code path, one deploy per target."""
    tracing_stub(repo.path, "stub-a")
    tracing_stub(repo.path, "stub-c")
    repo.write_config(CONFIG)

    assert run_cli("apply", "--repo", str(repo.path), repo=repo.path).returncode == 0
    for name in ("stub-a", "stub-c"):
        _, above = ran_by(repo.path, name)
        assert "deploy.py" in above, (name, above)


def test_deploy_select_runs_exactly_the_named_targets(repo):
    """The contract the CLI depends on: `select` is a filter, in the order given."""
    stub(repo.path, "stub-a")
    stub(repo.path, "stub-c")
    config = repo.write_config(CONFIG)

    result = run_pyinfra(repo.path, config, "-y", "--data", "select=stub-c")
    assert result.returncode == 0, result.stderr
    assert repo.read("stub-c") != {}
    assert not (repo.records / "stub-a.txt").exists()


def test_deploy_select_runs_a_disabled_entry_when_named(repo):
    """R-APP-010/A3: naming a disabled target runs it; `select` must not re-filter."""
    stub(repo.path, "stub-b")
    config = repo.write_config(CONFIG)

    assert run_pyinfra(repo.path, config, "-y", "--data", "select=stub-b").returncode == 0
    assert repo.read("stub-b")["stdin"] == "/dev/null"


def test_deploy_select_keeps_the_config_env_and_args(repo):
    stub(repo.path, "stub-a")
    config = repo.write_config(
        'version: 1\nscripts:\n  stub-a:\n    enabled: false\n    args: ["--one"]\n'
        "    env:\n      KEY: value\n"
    )

    run_pyinfra(repo.path, config, "-y", "--data", "select=stub-a")
    assert repo.read("stub-a")["argv"] == ["--one"]
    assert repo.read("stub-a")["KEY"] == "value"
    assert repo.read("stub-a")["INTERACTIVE"] == "false"


def test_deploy_select_names_a_target_it_cannot_run(repo):
    stub(repo.path, "stub-a")
    config = repo.write_config(CONFIG)

    result = run_pyinfra(repo.path, config, "-y", "--data", "select=stub-a,nope")
    assert result.returncode != 0
    assert "no tasks/nope.sh or tasks/nope.py" in result.stdout + result.stderr


def test_deploy_env_data_wins_over_the_config(repo):
    """`kwisatz apply --env` travels as `--data env=`, because deploy.py owns the env."""
    stub(repo.path, "stub-a")
    config = repo.write_config('version: 1\nscripts:\n  stub-a:\n    enabled: true\n    env:\n      KEY: from-config\n')

    result = run_pyinfra(repo.path, config, "-y", "--data", 'env={"KEY":"from-cli"}')
    assert result.returncode == 0, result.stderr
    assert repo.read("stub-a")["KEY"] == "from-cli"


# ── which pyinfra runs a deploy (repo.py) ─────────────────────────────────────────


def test_the_deploy_prefers_the_interpreter_it_is_running_in(repo):
    """Same interpreter ⇒ same pyinfra ⇒ `apply` and a hand-run deploy cannot diverge."""
    assert repoio.pyinfra_command(repo) == [sys.executable, "-m", "pyinfra"]


def test_the_deploy_falls_back_to_the_checkout_venv(repo, monkeypatch):
    (repo.path / ".venv" / "bin").mkdir(parents=True)
    venv = repo.path / ".venv" / "bin" / "pyinfra"
    venv.write_text("#!/bin/sh\ntrue\n")
    venv.chmod(0o755)
    monkeypatch.setattr(repoio.importlib.util, "find_spec", lambda _m: None)

    assert repoio.pyinfra_command(repo) == [str(venv)]


def test_the_deploy_needs_pyinfra_and_says_so(repo, monkeypatch, tmp_path):
    """Exit 4, not a traceback: `apply` cannot substitute a bare script run."""
    monkeypatch.setattr(repoio.importlib.util, "find_spec", lambda _m: None)
    monkeypatch.setattr(repoio.shutil, "which", lambda _c: None)

    with pytest.raises(CliError) as excinfo:
        repoio.pyinfra_command(repo)

    assert excinfo.value.code == Exit.PREREQUISITE
    assert "uv sync" in (excinfo.value.hint or "")


def test_the_repo_carries_deploy_py_into_the_deploy(repo):
    """deploy.py is read from the checkout the CLI resolved, never from the installed one."""
    argv = repoio.deploy_argv(repo, repo.path / "machine-config.yml", ["stub-a"])
    assert str(repo.path / "deploy.py") in argv
    assert "--data" in argv and "select=stub-a" in argv
    assert "-y" in argv and "-vvv" in argv
    assert (REPO_ROOT / "deploy.py").is_file()
