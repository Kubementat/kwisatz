"""Phase 4: bundled versions.yml under a sparse user override — bash kw_pin and the kwisatz module agree."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
import yaml
from conftest import REPO_ROOT, run_cli

from kwisatz import versions as versionio

DEFAULT = """\
alpha:
  datasource: docker
  package: ex/alpha
  version: "1.0"
  digest: "sha256:old"
beta:
  datasource: github-releases
  package: ex/beta
  version: "2.0"
"""


@pytest.fixture
def files(tmp_path):
    default = tmp_path / "versions.yml"
    default.write_text(DEFAULT)
    return default, tmp_path / "cfg" / "versions.yml"


def kw(snippet: str, default: Path, override: Path | None, **extra) -> subprocess.CompletedProcess:
    env = {"PATH": "/usr/bin:/bin", "KW_VERSIONS_FILE": str(default), **extra}
    if override is not None:
        env["KW_VERSIONS_OVERRIDE"] = str(override)
    return subprocess.run(
        ["bash", "-c", f'source "{REPO_ROOT}/lib/helpers.sh"; {snippet}'], capture_output=True, text=True, env=env
    )


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def test_no_override_file_is_todays_behaviour(files):
    default, override = files
    assert kw("kw_image alpha; kw_version beta", default, override).stdout == "ex/alpha:1.0@sha256:old\n2.0\n"


def test_partial_field_merge_and_digest_follows_the_version(files):
    default, override = files
    write(override, 'alpha:\n  version: "1.5"\n')
    out = kw("kw_image alpha; kw_pin alpha package; kw_version beta", default, override)
    assert out.stdout == "ex/alpha:1.5\nex/alpha\n2.0\n"  # the old digest is gone, other fields stay
    write(override, 'alpha:\n  version: "1.5"\n  digest: "sha256:new"\n')
    assert kw("kw_image alpha", default, override).stdout == "ex/alpha:1.5@sha256:new\n"


def test_config_dir_is_where_the_override_is_found(files):
    default, override = files
    write(override, 'beta:\n  version: "9"\n')
    out = kw("kw_version beta", default, None, KWISATZ_CONFIG_DIR=str(override.parent))
    assert out.stdout == "9\n"


def test_an_unknown_key_is_an_error_naming_the_file(files):
    default, override = files
    write(override, 'gamma:\n  version: "1"\n')
    out = kw("kw_version alpha", default, override)
    assert out.returncode != 0 and str(override) in out.stderr and "gamma" in out.stderr


def test_task_env_var_still_wins(files):
    default, override = files
    write(override, 'alpha:\n  version: "1.5"\n')
    out = kw('ALPHA_IMAGE="${ALPHA_IMAGE:-$(kw_image alpha)}"; echo $ALPHA_IMAGE', default, override, ALPHA_IMAGE="mine")
    assert out.stdout == "mine\n"


def test_python_merge_matches_bash(files):
    default, override = files
    write(override, 'alpha:\n  version: "1.5"\n')
    d, u = versionio.load(default), versionio.load(override)
    entry = versionio.effective(d, u)["alpha"]
    assert (entry["version"], entry.get("digest")) == ("1.5", None)
    by = {r["component"]: r for r in versionio.rows(d, u)}
    assert by["alpha"]["source"] == "user" and by["beta"]["source"] == "default"


def test_stale_detection():
    assert versionio.is_stale("1.0", "1.2")
    assert not versionio.is_stale("1.3", "1.2")
    assert not versionio.is_stale("1.2", "1.2")
    assert versionio.is_stale("rolling-a", "rolling-b")  # does not parse: differs


@pytest.fixture
def cli_env(files, repo, tmp_path):
    default, override = files
    (repo.path / "versions.yml").write_text(DEFAULT)
    return {"KWISATZ_CONFIG_DIR": str(override.parent), "KWISATZ_REPO": str(repo.path)}, override, repo


def test_set_unset_round_trip_with_backup(cli_env):
    env, override, repo = cli_env
    out = run_cli("versions", "set", "alpha", "1.5", "--json", repo=repo.path, env=env)
    assert out.returncode == 0, out.stdout + out.stderr
    assert yaml.safe_load(override.read_text()) == {"alpha": {"version": "1.5"}}
    assert override.stat().st_mode & 0o777 == 0o600
    listed = json.loads(run_cli("versions", "list", "--json", repo=repo.path, env=env).stdout)["result"]
    alpha = next(r for r in listed["versions"] if r["component"] == "alpha")
    assert (alpha["version"], alpha["source"], alpha["digest"], alpha["stale"]) == ("1.5", "user", None, False)
    run_cli("versions", "set", "alpha", "1.6", "--json", repo=repo.path, env=env)
    state = repo.path / ".kwisatz" / "config-backups"
    assert any(p.name.startswith("versions.yml.") for p in state.iterdir())
    out = run_cli("versions", "unset", "alpha", "--json", repo=repo.path, env=env)
    assert out.returncode == 0 and yaml.safe_load(override.read_text()) == {}
    again = run_cli("versions", "unset", "alpha", "--json", repo=repo.path, env=env)
    assert again.returncode == 2


def test_set_rejects_unknown_component_and_field(cli_env):
    env, override, repo = cli_env
    assert run_cli("versions", "set", "nope", "1", repo=repo.path, env=env).returncode == 2
    assert run_cli("versions", "set", "alpha", "1", "--field", "bogus", repo=repo.path, env=env).returncode == 2
    assert not override.exists()


def test_checkout_without_override_dir_refuses_set(repo):
    (repo.path / "versions.yml").write_text(DEFAULT)
    out = run_cli("versions", "set", "alpha", "1", repo=repo.path, env={"KWISATZ_REPO": str(repo.path)})
    assert out.returncode == 2 and "override" in out.stderr + out.stdout


def test_versions_is_in_commands_json(repo):
    out = run_cli("commands", "--json", repo=repo.path, env={"KWISATZ_REPO": str(repo.path)})
    names = [c["name"] for c in json.loads(out.stdout)["result"]["commands"]]
    assert "versions" in names


def test_doctor_warns_on_stale_and_unknown_overrides(cli_env):
    env, override, repo = cli_env
    write(override, 'alpha:\n  version: "0.5"\nghost:\n  version: "1"\n')
    (repo.path / "machine-config.yml").write_text("scripts: {}\n")
    out = run_cli("doctor", "--json", repo=repo.path, env=env)
    warnings = " ".join(json.loads(out.stdout).get("warnings", []))
    assert "alpha" in warnings and "older than the bundled" in warnings and "ghost" in warnings
