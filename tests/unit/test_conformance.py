"""R-ARCH-102 — the release gate: the CLI path and the pyinfra path must agree.

Two entry points, one contract. The assertion is made where it matters: on what the
*task script* receives in each path (argv, environment, stdin), plus the masked echo
each path shows the operator. If a future change makes `kwisatz apply` install
something subtly different from `run-setup.sh apply`, this file fails.
"""

from __future__ import annotations

import json

import pytest

from conftest import REPO_ROOT, run_cli, run_pyinfra, stub

from kwisatz import orchestrator

CONFIG = """version: 1
scripts:
  stub-a:
    enabled: true
    description: A
    args: ["--one", "--two"]
    env:
      KEY: value
      SECRET: hunter2
  stub-p:
    enabled: true
    args: ["--py"]
    env:
      PLAIN: ok
"""


def _run_both(repo, config) -> tuple[dict, dict]:
    """Run the same config through both entry points; return what each script recorded."""
    cli = run_cli("apply", "--repo", str(repo.path), "--json", repo=repo.path)
    assert cli.returncode == 0, (cli.stdout, cli.stderr)
    cli_records = {name: _Repo(repo.path).read(name) for name in ("stub-a", "stub-p")}
    for path in (repo.path / "records").glob("*.txt"):
        path.unlink()

    infra = run_pyinfra(repo.path, config, "-y")
    assert infra.returncode == 0, (infra.stdout, infra.stderr)
    infra_records = {name: _Repo(repo.path).read(name) for name in ("stub-a", "stub-p")}
    return cli_records, infra_records


class _Repo:
    def __init__(self, root):
        self.root = root

    def read(self, name: str) -> dict:
        text = (self.root / "records" / f"{name}.txt").read_text()
        out: dict = {}
        for line in text.splitlines():
            if line.startswith("argv:"):
                out["argv"] = line[len("argv:"):].split()
            elif "=" in line:
                key, _, value = line.partition("=")
                out[key] = value
        return out


def test_cli_and_pyinfra_hand_the_scripts_the_same_thing(repo):
    """Every enabled script: identical argv, identical env, identical stdin."""
    config = repo.write_config(CONFIG)
    stub(repo.path, "stub-a", kind="sh")
    stub(repo.path, "stub-p", kind="py")

    cli, infra = _run_both(repo, config)

    for name in ("stub-a", "stub-p"):
        assert cli[name] == infra[name], f"{name} diverged between the CLI and pyinfra"
    # spelled out, because "equal dicts" hiding a real divergence is the failure mode here
    assert cli["stub-a"]["argv"] == ["--one", "--two"]
    assert cli["stub-a"]["stdin"] == "/dev/null"
    assert cli["stub-a"]["INTERACTIVE"] == "false"
    assert cli["stub-a"]["KEY"] == "value"
    assert cli["stub-a"]["SECRET"] == "hunter2"
    assert cli["stub-p"]["argv"] == ["--py"]
    assert cli["stub-p"]["INTERACTIVE"] == "false"
    assert "VIRTUAL_ENV" not in cli["stub-a"], "task scripts must not inherit the venv"
    assert "VIRTUAL_ENV" not in infra["stub-a"]


def test_plan_and_pyinfra_agree_on_the_command_and_masked_env(repo):
    """The echo the operator sees is the masked form of what pyinfra would run."""
    from pyinfra.api import HiddenValue
    from pyinfra.api.command import StringCommand
    from pyinfra.connectors.util import make_unix_command

    config = repo.write_config(CONFIG)
    stub(repo.path, "stub-a", kind="sh")
    stub(repo.path, "stub-p", kind="py")
    loaded = orchestrator.load_config(config, repo.path)

    for task in orchestrator.iter_enabled(loaded):
        generated = str(make_unix_command(StringCommand(task.command), _env=orchestrator.pyinfra_env(task, HiddenValue)))
        # the same three facts, read out of both renderings
        assert task.command in generated
        assert "INTERACTIVE=false" in generated
        assert "SECRET=*MASKED*" in generated or "SECRET" not in task.secrets
        assert "*MASKED*" not in generated.split("INTERACTIVE=false")[0], "INTERACTIVE is not a secret"
        assert task.echo().endswith(task.command)
        if "SECRET" in task.secrets:
            assert "SECRET=*MASKED*" in task.echo()
            assert "hunter2" not in task.echo()
            assert task.env["SECRET"] == "hunter2"


def test_status_and_pyinfra_status_agree(repo):
    """A9: the CLI plan is the same commands, in the same order, as the orchestrator's."""
    config = repo.write_config(CONFIG)
    stub(repo.path, "stub-a", kind="sh")
    stub(repo.path, "stub-p", kind="py")

    plan = run_cli("status", "--repo", str(repo.path), "--json", repo=repo.path)
    assert plan.returncode == 0, plan.stderr
    items = json.loads(plan.stdout)["result"]["items"]
    assert [i["target"] for i in items] == ["stub-a", "stub-p"]
    assert all(i["command"].endswith("</dev/null") for i in items), "the plan says /dev/null, pyinfra runs /dev/null"
    assert "SECRET=*MASKED*" in items[0]["echo"]

    dry = run_pyinfra(repo.path, config, "--dry")
    assert dry.returncode == 0, dry.stderr
    # pyinfra writes its operation report to stderr, not stdout, when stdout is not a TTY
    report = dry.stdout + dry.stderr
    for name in ("stub-a", "stub-p"):
        assert name in report


def test_the_shared_module_is_the_only_source(repo, monkeypatch):
    """deploy.py must contain no contract of its own — it is the adapter, nothing more."""
    deploy_text = (REPO_ROOT / "deploy.py").read_text()
    assert "orchestrator." in deploy_text
    assert "BaseLoader" not in deploy_text, "config parsing belongs in kwisatz.orchestrator"
    assert "is_enabled" not in deploy_text
    assert "sys.executable" not in deploy_text
