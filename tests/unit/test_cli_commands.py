"""The commands that had no test of their own: `install`, `models`, `info`, `doctor`.

They are all reachable from the tmp-repo fixture, `install` included — `run_cli` points `HOME`
at the checkout, so `~/.local/bin/kwisatz` and `~/.config/kwisatz/config.json` land *inside* the
fixture and can be asserted to exist, or (for `--dry-run`) not to (R-SAFE-002).

Nothing here asserts an internal. `checks.port_conflicts()` and `host_checks()` are what
`doctor` is worth, and they are asserted in `test_checks.py`, on synthetic configs and
services rather than a live docker daemon.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from conftest import run_cli, stub

CONFIG = """version: 1
scripts:
  stub-a:
    enabled: true
    description: first
    env:
      SECRET: hunter2
  stub-c:
    enabled: true
"""

#: what `run_cli` puts on PATH includes this user's `~/.local/bin`, where the real `uv` lives
NO_UV = "/usr/bin:/bin"


@pytest.fixture
def work(repo):
    for name in ("stub-a", "stub-c"):
        stub(repo.path, name)
    repo.write_config(CONFIG)
    return repo


def doc(result):
    """R-JSON-001: one document on stdout, and nothing else.

    A command that prints its document *and* a `next:` line fails here, which is the whole
    point of repeating the assertion per module rather than trusting one helper.
    """
    body = json.loads(result.stdout)
    assert result.stdout.count("\n") == 1, "no stray lines around the document"
    return body


def with_uv(work) -> str:
    """A `uv` that answers, first on PATH, so `install` does not depend on this box."""
    bin_ = work.path / "bin"
    bin_.mkdir(exist_ok=True)
    uv = bin_ / "uv"
    uv.write_text("#!/bin/sh\nexit 0\n")
    uv.chmod(0o755)
    return f"{bin_}:/usr/bin:/bin"


# ── install: R-INS-001 ──────────────────────────────────────────────────────────────────────


def test_install_dry_run_says_where_it_would_write_and_writes_nothing(work):
    """R-SAFE-002 / R-INS-001: the launcher is the whole command, so its dry run is verifiable."""
    result = run_cli(
        "install", "--dry-run", "--json", "--repo", str(work.path),
        repo=work.path, env={"PATH": with_uv(work)},
    )
    assert result.returncode == 0, result.stderr
    body = doc(result)
    assert body["result"]["dry_run"] is True
    assert body["result"]["repo"] == str(work.path)
    assert not (work.path / ".local" / "bin" / "kwisatz").exists()
    assert not (work.path / ".config" / "kwisatz" / "config.json").exists()


def test_install_without_uv_is_a_prerequisite_and_never_a_download(work):
    """The design decision the spec records: kwisatz does not run an installer behind you."""
    result = run_cli("install", "--json", "--repo", str(work.path), repo=work.path, env={"PATH": NO_UV})
    assert result.returncode == 4, result.stderr
    body = doc(result)
    assert "uv" in body["errors"][0]["message"]
    assert "install.sh" in body["errors"][0]["hint"]
    assert not (work.path / ".local" / "bin" / "kwisatz").exists()


def test_a_pinned_installer_needs_yes_before_it_needs_the_network(work):
    """`--with-uv` executes upstream code, so it cannot be a typo away."""
    result = run_cli(
        "install", "--with-uv", "0.9.9", "--json", "--repo", str(work.path),
        repo=work.path, env={"PATH": NO_UV},
    )
    assert result.returncode == 2, result.stderr
    assert "--yes" in doc(result)["errors"][0]["hint"]


def test_install_writes_the_launcher_into_the_home_it_was_run_with(work):
    """The other half of the dry-run claim: `--dry-run` says it, this one does it.

    `uv sync` is stubbed, not run: what matters for the CLI is where the launcher and the
    repo-pointer file land, and that they are the checkout the operator named.
    """
    result = run_cli(
        "install", "--json", "--repo", str(work.path), repo=work.path, env={"PATH": with_uv(work)}
    )
    assert result.returncode == 0, result.stderr
    body = doc(result)
    launcher = Path(body["result"]["launcher"])
    assert launcher == work.path / ".local" / "bin" / "kwisatz"
    assert "--project" in launcher.read_text() and str(work.path) in launcher.read_text()
    assert json.loads((work.path / ".config" / "kwisatz" / "config.json").read_text())["repo"] == str(work.path)
    assert launcher.stat().st_mode & 0o111, "an executable bit, or nothing else about it matters"


# ── models: R-MOD-001 ───────────────────────────────────────────────────────────────────────

CATALOG = """providers:
  - name: local
    models:
      - name: qwen38-27b
      - name: qwen38-flash
  - name: openai
    models:
      - name: gpt-5
"""


def test_models_status_reads_the_catalog_that_wins_and_the_swap_it_found(work):
    (work.path / "models.yml").write_text(CATALOG)
    result = run_cli("models", "status", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0, result.stderr
    catalog = doc(result)["result"]["catalog"]
    assert catalog["path"] == str(work.path / "models.yml")
    assert (catalog["providers"], catalog["models"]) == (2, 3)
    assert "qwen38-27b" in catalog["names"]
    # a smoke check on the human line, not a contract: the swap value used to be a nested
    # ternary inside the f-string, so an interpolated `None`/`True` is the regression to watch for
    human = run_cli("models", "status", "--repo", str(work.path), repo=work.path)
    assert human.returncode == 0, human.stderr
    swap = next(line for line in human.stdout.splitlines() if line.startswith("swap     "))
    stated = swap.removeprefix("swap     ")
    assert stated.strip() and stated not in ("True", "None"), swap


def test_models_status_reports_a_catalog_it_cannot_parse_without_lying(work):
    """A file that does not parse is not "0 models", it is "I could not read it"."""
    (work.path / "models.yml").write_text("providers: [\n")
    result = run_cli("models", "status", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0, result.stderr
    catalog = doc(result)["result"]["catalog"]
    assert catalog["unparsable"] is True
    assert catalog["models"] == 0


def test_models_show_adds_the_command_that_applies_it(work):
    result = run_cli("models", "show", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0
    assert doc(result)["result"]["sync_command"] == "tasks/sync-models.py"


def test_models_sync_dry_run_prints_the_command_it_cannot_half_run(work):
    """sync-models.py has no --dry-run, so the honest answer is the argv and nothing executed."""
    script = work.path / "tasks" / "sync-models.py"
    script.write_text("import sys\nsys.exit(0)\n")
    script.chmod(0o755)
    result = run_cli("models", "sync", "--dry-run", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0, result.stderr
    body = doc(result)
    assert body["result"]["dry_run"] is True
    assert str(script) in " ".join(body["result"]["command"])
    assert not (work.path / "logs").exists()


def test_models_sync_without_the_script_is_a_config_error(work):
    result = run_cli("models", "sync", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 3
    assert "sync-models" in doc(result)["errors"][0]["message"]


@pytest.mark.parametrize("script_code,cli_code", [(1, 4), (2, 1), (0, 0)])
def test_models_sync_maps_the_preflight_code_onto_the_work_codes(work, script_code, cli_code):
    """R-EXIT-001: 1 is sync-models.py's own "preflight failed, nothing mutated" (→ 4), and any
    other non-zero code is a script failure (→ 1). Its code survives under `result`."""
    script = work.path / "tasks" / "sync-models.py"
    script.write_text(f"import sys\nsys.exit({script_code})\n")
    script.chmod(0o755)
    result = run_cli("models", "sync", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == cli_code, result.stderr
    body = doc(result)
    assert body["result"]["exit_code"] == script_code
    assert body["result"]["script_exit_code"] == script_code


def test_models_sync_reports_a_spent_timeout_as_health(work):
    """R-AGE-002 / §9: the same verdict `apply` gives, on the command that never got it.

    `_map_models_exit(None)` answered `Exit.OK` — "no code, no failure" — so `models sync
    --timeout` exited 0 with `ok: true` about a child the CLI had just killed, and (without
    `--json`) said nothing at all, because `if outcome.returncode:` was false for the missing code.
    """
    script = work.path / "tasks" / "sync-models.py"
    script.write_text("import time\ntime.sleep(30)\n")
    script.chmod(0o755)
    result = run_cli("models", "sync", "--timeout", "2", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 5, (result.stdout, result.stderr)
    body = doc(result)
    assert body["ok"] is False, body
    assert body["result"]["script_exit_code"] is None, "nothing was observed, so nothing is quoted"
    assert "timed out" in body["errors"][0]["message"], body["errors"]
    plain = run_cli("models", "sync", "--timeout", "2", "--repo", str(work.path), repo=work.path)
    assert plain.returncode == 5, plain.stderr
    assert "timed out" in plain.stderr, plain.stderr


# ── info: R-AGE-003, the one round trip ─────────────────────────────────────────────────────


def test_info_json_is_the_whole_answer_about_one_target(work):
    result = run_cli("info", "stub-a", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0, result.stderr
    body = doc(result)["result"]
    assert body["target"] == "stub-a"
    assert body["script"] == str(work.path / "tasks" / "stub-a.sh")
    assert (body["in_config"], body["enabled"]) == (True, True)
    assert body["env"]["SECRET"] == "***", "info masks, like the plan does"
    assert isinstance(body["prerequisites"], list)
    assert body["last_apply"] == {}, "nothing has run yet, and `info` says so instead of guessing"


def test_a_disabled_target_still_names_the_script_it_was_found_from(work):
    """A switched-off entry was still located on disk, and `kind` is the proof of that.

    `script` was derived from the task, and a disabled config entry has no task, so `info
    --json` answered `"script": null` on the same line it answered `"kind": "sh"`, and the
    human view printed the literal `script  None`. The path belongs with the `kind` that had
    to find the file to know it, so it is reported whether or not the entry is enabled.
    """
    stub(work.path, "stub-b")
    work.write_config(
        "version: 1\nscripts:\n  stub-a:\n    enabled: true\n  stub-b:\n    enabled: false\n  stub-z:\n"
    )

    body = doc(run_cli("info", "stub-b", "--json", "--repo", str(work.path), repo=work.path))["result"]
    assert (body["enabled"], body["kind"]) == (False, "sh")
    assert body["script"] == str(work.path / "tasks" / "stub-b.sh")

    plain = run_cli("info", "stub-b", "--repo", str(work.path), repo=work.path)
    assert plain.returncode == 0, plain.stderr
    assert "None" not in plain.stdout, "a human-facing line never prints a bare None"

    listed = doc(run_cli("list", "--all", "--json", "--repo", str(work.path), repo=work.path))["result"]
    blank = sorted(i["target"] for i in listed["items"] if not i["script"])
    assert blank == ["stub-z"], "only a name with no file at all reports no script"


def test_info_shows_the_last_apply_that_touched_the_target(work):
    run_cli("apply", "stub-a", "--json", "--repo", str(work.path), repo=work.path)
    body = doc(run_cli("info", "stub-a", "--json", "--repo", str(work.path), repo=work.path))["result"]
    assert body["last_apply"]["command"] == "apply"
    assert body["last_apply"]["exit_code"] == 0
    assert body["last_apply"]["items"][0]["target"] == "stub-a"


def test_info_warns_about_a_predecessor_the_config_does_not_have(work):
    """§6.5's ordering advisory is `info`'s business too, and it needs no host facts to fire."""
    stub(work.path, "configure-firewall")
    work.write_config("version: 1\nscripts:\n  configure-firewall:\n    enabled: true\n")
    result = run_cli("info", "configure-firewall", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0
    prereq = doc(result)["result"]["prerequisites"]
    assert any("setup-sshd" in line for line in prereq), prereq


# ── doctor: the checks are the output (R-OPS-003) ───────────────────────────────────────────


def test_doctor_reports_every_host_check_by_name(repo):
    """The item list is what an agent branches on, so the names must be there and be honest."""
    body = doc(run_cli("doctor", "--json", repo=repo.path))
    names = {item["name"] for item in body["result"]["items"]}
    assert {"os", "sudo", "python", "uv", "docker", "gpu", "disk", "srv-disk"} <= names
    assert all(item["kind"] == "prerequisite" for item in body["result"]["items"])
    assert body["result"]["doctor_exit_code"] == body["exit_code"]


def test_doctor_turns_a_shared_port_into_a_to_fix_item(repo):
    """Port collisions are `doctor`'s value before twenty minutes of install work.

    The exit code is whatever the box's prerequisites already are, so the assertion is about
    the item: `kind: port`, `ok: false`, and both names in the detail.
    """
    stub(repo.path, "setup-a")
    stub(repo.path, "setup-b")
    repo.write_config(
        "version: 1\nscripts:\n"
        "  setup-a:\n    enabled: true\n    env:\n      A_PORT: 8080\n"
        "  setup-b:\n    enabled: true\n    env:\n      B_PORT: 8080\n"
    )
    body = doc(run_cli("doctor", "--json", repo=repo.path))
    ports = [item for item in body["result"]["items"] if item["kind"] == "port"]
    assert ports, body["result"]["items"]
    assert ports[0]["ok"] is False
    assert ports[0]["name"] == "port:8080"
    assert "setup-a" in ports[0]["detail"] and "setup-b" in ports[0]["detail"]
    assert len(body["result"]["ports"]) == 1
