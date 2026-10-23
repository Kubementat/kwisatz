"""The CLI as an operator runs it: real process, real exit code, real side effects (§12.1.3).

Every assertion here is about an observable a human or agent depends on — stdout/stderr
split, the exit code, what ended up on disk — because the unit tests already cover the
internals. Where the spec names an acceptance criterion (A2…A7) the test says so.
"""

from __future__ import annotations

import difflib
import json
import os
import stat

import pytest
from conftest import run_cli, stub

CONFIG = """version: 1
scripts:
  stub-a:
    enabled: true
    description: first
    env:
      SECRET: hunter2
  stub-b:
    enabled: false
  stub-c:
    enabled: true
"""


@pytest.fixture
def work(repo):
    """A checkout with three recording stubs, two of them enabled."""
    for name, kind in (("stub-a", "sh"), ("stub-b", "sh"), ("stub-c", "sh")):
        stub(repo.path, name, kind=kind)
    repo.write_config(CONFIG)
    return repo


def doc(result):
    """R-JSON-001: stdout must be one document and nothing else — so `loads` must not complain."""
    body = json.loads(result.stdout)
    assert result.stdout.count("\n") == 1, "no stray lines around the document"
    return body


def test_apply_runs_every_enabled_target_in_config_order(work):
    """A2: two enabled scripts, config order, exit 0, summary on stdout."""
    result = run_cli("apply", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0, result.stderr
    assert [i["target"] for i in doc(run_cli("apply", "--repo", str(work.path), "--json", repo=work.path))["result"]["items"]] == [
        "stub-a",
        "stub-c",
    ]
    assert work.read("stub-a")["argv"] == []
    assert "Summary" in result.stdout
    assert "stub-b" not in result.stdout.split("Summary")[1]


def test_a_failing_script_stops_the_run_and_yields_exit_1(work):
    stub(work.path, "stub-b", code=1)
    work.write_config("version: 1\nscripts:\n  stub-a:\n    enabled: true\n  stub-b:\n    enabled: true\n")
    result = run_cli("apply", "--repo", str(work.path), "--json", repo=work.path)
    body = doc(result)
    assert result.returncode == 1
    assert body["result"]["items"][1]["status"] == "failed"
    assert body["errors"][0]["target"] == "stub-b"


def test_keep_going_runs_the_rest_and_exits_8(work):
    stub(work.path, "stub-a", code=1)
    stub(work.path, "stub-b", code=1)
    work.write_config("version: 1\nscripts:\n  stub-a:\n    enabled: true\n  stub-b:\n    enabled: true\n  stub-c:\n    enabled: true\n")
    result = run_cli("apply", "--keep-going", "--repo", str(work.path), "--json", repo=work.path)
    assert result.returncode == 8
    assert doc(result)["result"]["ok"] == 1


def test_single_target_apply_is_the_command_the_full_apply_would_run(work):
    """A2's other half, and R-APP-010: one target, same command, same env."""
    planned = doc(run_cli("status", "--repo", str(work.path), "--json", repo=work.path))
    applied = run_cli("apply", "stub-a", "--repo", str(work.path), "--json", repo=work.path)
    assert applied.returncode == 0
    assert work.read("stub-a")["stdin"] == "/dev/null"
    assert work.read("stub-a")["INTERACTIVE"] == "false"
    assert work.read("stub-a")["SECRET"] == "hunter2"
    assert planned["result"]["items"][0]["command"].startswith("bash ")


def test_config_env_reaches_a_single_target_apply(work):
    """R-APP-011 + R-JSON-012: the script gets its real env, the plan shows it masked."""
    run_cli("apply", "stub-a", "--repo", str(work.path), repo=work.path)
    assert work.read("stub-a")["SECRET"] == "hunter2"
    out = run_cli("status", "--repo", str(work.path), "--json", repo=work.path)
    assert doc(out)["result"]["items"][0]["env"]["SECRET"] == "***"


def test_an_env_flag_wins_over_the_config(work):
    run_cli("apply", "stub-a", "--env", "INTERACTIVE=true", "--repo", str(work.path), repo=work.path)
    assert work.read("stub-a")["INTERACTIVE"] == "true"


def test_a_target_that_is_not_in_the_config_runs_anyway(work):
    """A10: runnable, with a warning that names the fix."""
    stub(work.path, "setup-unsloth", code=0)
    result = run_cli("apply", "unsloth", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0
    assert "not in machine-config.yml" in result.stderr
    assert "kwisatz config enable" in result.stderr


def test_a_disabled_entry_still_runs_when_named(work):
    """A3: named means wanted; the config is not edited to do it."""
    stub(work.path, "stub-b")
    before = (work.path / "machine-config.yml").read_text()
    result = run_cli("apply", "stub-b", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0
    assert "disabled" in result.stderr
    assert (work.path / "machine-config.yml").read_text() == before


def test_a_typo_exits_three_and_shows_the_closest_names(work):
    """A5: the hint is the deliverable, not a nice-to-have."""
    result = run_cli("apply", "stub-ax", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 3
    assert "stub-a" in result.stderr


def test_an_unknown_command_gets_a_suggestion():
    result = run_cli("aply")
    assert result.returncode == 2
    assert "did you mean" in result.stderr


def test_a_bad_flag_is_usage(work):
    result = run_cli("apply", "--nope", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 2


def test_dry_run_mutates_nothing(work):
    """R-SAFE-002 / A7's quieter cousin: `--dry-run` may print, but may not touch."""
    result = run_cli("apply", "--dry-run", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0
    assert not (work.path / "logs").exists()
    assert not (work.path / ".kwisatz" / "state.jsonl").exists()
    assert not list(work.records.glob("*.txt"))


def test_json_mode_prompts_nothing_and_prints_one_document(work):
    """R-AGE-001: an agent gets a document and an exit code, never a question."""
    result = run_cli("services", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0
    body = doc(result)
    assert body["schema_version"] == 1
    assert "items" in body["result"]


def test_a_broken_config_is_exit_three_with_one_line(tmp_path):
    (tmp_path / "tasks").mkdir()
    (tmp_path / "deploy.py").write_text("# adapter\n")
    (tmp_path / "machine-config.yml").write_text("version: 1\nscripts: [\n")
    result = run_cli("status", "--repo", str(tmp_path), repo=tmp_path)
    assert result.returncode == 3
    assert "cannot parse" in result.stderr


def test_a_missing_config_says_how_to_fix_it(tmp_path):
    (tmp_path / "tasks").mkdir()
    (tmp_path / "deploy.py").write_text("# adapter\n")
    (tmp_path / "machine-config.yml.example").write_text("version: 1\nscripts: {}\n")
    result = run_cli("status", "--repo", str(tmp_path), repo=tmp_path)
    assert result.returncode == 3
    assert "machine-config.yml.example" in result.stderr or "kwisatz init" in result.stderr


def test_a_lock_held_by_another_run_exits_nine(work):
    work.path.joinpath(".kwisatz").mkdir(exist_ok=True)
    # the owner must be a live pid (the staleness rule is `kill(pid, 0)`), so this process
    # is the pretend owner of a concurrent run
    (work.path / ".kwisatz" / "lock").write_text(json.dumps({"pid": os.getpid(), "repo": str(work.path)}))
    result = run_cli("apply", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 9


def test_the_apply_history_is_written_after_the_run(work):
    run_cli("apply", "--repo", str(work.path), repo=work.path)
    shown = run_cli("state", "--repo", str(work.path), "--json", repo=work.path)
    body = doc(shown)
    assert body["result"]["count"] == 1
    assert body["result"]["records"][0]["items"][0]["status"] == "applied"
    path = work.path / ".kwisatz" / "state.jsonl"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_state_json_answers_under_items_like_every_other_command(work):
    run_cli("apply", "--repo", str(work.path), repo=work.path)
    body = doc(run_cli("state", "--repo", str(work.path), "--json", repo=work.path))
    assert body["result"]["items"][0]["items"][0]["status"] == "applied"
    assert body["result"]["records"] == body["result"]["items"], "the old key keeps working"


def test_a_failed_apply_leaves_the_output_in_the_log(work):
    """The recovery path for exit 1: `kwisatz logs <target>` must have something to say.

    pyinfra delivers the script's output on *stderr*, so the log copy used to be an empty file
    and the documented next step printed nothing — the one thing an agent does after exit 1.
    """
    script = work.path / "tasks" / "stub-d.sh"
    script.write_text(
        "#!/usr/bin/env bash\necho 'doing work'\necho 'port 9292 already in use' >&2\nexit 1\n"
    )
    script.chmod(0o755)
    failed = run_cli("apply", "stub-d", "--json", "--repo", str(work.path), repo=work.path)
    assert failed.returncode == 1, failed.stderr
    shown = run_cli("logs", "stub-d", "--json", "--repo", str(work.path), repo=work.path)
    assert shown.returncode == 0, shown.stderr
    assert "port 9292 already in use" in "\n".join(doc(shown)["result"]["lines"])


def test_a_timeout_exits_health_not_task_failed(work):
    """R-AGE-002: a killed run is 5, so a caller does not retry it as a script bug."""
    script = work.path / "tasks" / "stub-sleep.sh"
    script.write_text("#!/usr/bin/env bash\nsleep 30\n")
    script.chmod(0o755)
    result = run_cli(
        "apply", "stub-sleep", "--timeout", "2", "--json", "--repo", str(work.path), repo=work.path
    )
    assert result.returncode == 5, result.stderr
    body = doc(result)
    assert body["errors"][0]["exit_code"] == 5
    assert "timed out" in body["errors"][0]["message"]
    assert doc(run_cli("state", "--repo", str(work.path), "--json", repo=work.path))["result"]["items"][0][
        "exit_code"
    ] == 5, "the history records the verdict the run actually got"


def test_init_json_is_one_document_and_says_what_it_wrote(repo):
    """The bootstrap an agent runs first: `next: …` used to land in front of the document."""
    result = run_cli("init", "--from-example", "base", "--json", "--repo", str(repo.path), repo=repo.path)
    assert result.returncode == 0, result.stderr
    assert doc(result)["result"]["created"] is True
    assert (repo.path / "machine-config.yml").is_file()


def test_config_enable_changes_exactly_one_line(work):
    """A8 through the CLI: no editor, and not one comment lost."""
    before = (work.path / "machine-config.yml").read_text()
    (work.path / "machine-config.yml").write_text("# keep me\n" + before)
    result = run_cli("config", "enable", "stub-b", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0, (result.stdout, result.stderr)
    after = (work.path / "machine-config.yml").read_text()
    diff = [
        line
        for line in difflib.unified_diff(before.splitlines(), after.splitlines()[1:], lineterm="", n=0)
        if line[:1] in "+-" and not line.startswith(("+++", "---"))
    ]
    assert diff == ["-    enabled: false", "+    enabled: true"], diff
    assert "# keep me" in after


def test_config_validate_before_apply(work):
    work.write_config("version: 1\nscripts:\n  stub-a:\n    enabled: yes\n")
    result = run_cli("config", "validate", "--repo", str(work.path), "--json", repo=work.path)
    assert result.returncode == 3
    assert doc(result)["result"]["ok"] is False


def test_config_commands_accept_the_global_flags_after_the_verb(work):
    result = run_cli("config", "path", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0
    assert str(work.path) in result.stdout


def test_quiet_prints_a_single_line(work):
    result = run_cli("apply", "stub-a", "--quiet", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 0
    assert result.stdout.count("\n") == 1


def test_version_and_help_exit_zero(work):
    assert run_cli("--version", "--repo", str(work.path), repo=work.path).returncode == 0
    assert run_cli("--help", repo=work.path).returncode == 0


def test_no_command_is_the_help_and_exits_zero(work):
    """The epilog invites `kwisatz` with no command, so it must succeed and say what --help says.

    It used to print the command map and exit `2` — a usage answer for the one invocation that
    is not a mistake. Unknown verbs still exit `2` with the `did you mean` (R-CMD-002).
    """
    bare = run_cli(repo=work.path)
    assert bare.returncode == 0, bare.stderr
    assert bare.stdout == run_cli("--help", repo=work.path).stdout


def test_json_with_no_command_answers_with_the_command_table():
    """An agent running `kwisatz --json` alone gets the document, never help text on stdout."""
    result = run_cli("--json")
    assert result.returncode == 0, result.stderr
    body = doc(result)
    assert body["command"] == "commands"
    assert body["result"]["commands"]


def test_the_command_table_is_the_cli(work):
    """R-CMD-100: `commands --json` is the whole surface, so no flag may be undocumented."""
    body = doc(run_cli("commands", "--json", repo=work.path))
    names = {c["name"] for c in body["result"]["commands"]}
    assert {"apply", "status", "list", "info", "doctor", "config", "services", "logs", "state", "models", "run", "commands"} <= names
    verbs = {c["name"] for c in next(c for c in body["result"]["commands"] if c["name"] == "config")["subcommands"]}
    assert {"show", "validate", "enable", "disable", "set", "unset", "args", "path", "init"} == verbs
    assert set(body["result"]["exit_codes"]) == {str(i) for i in range(10)}


def test_doctor_prints_verdicts_on_stdout_and_lists_them_as_items(repo):
    """Everything else puts progress on stderr; `doctor`'s checks ARE its output (R-OPS-003)."""
    stub(repo.path, "stub-a")
    repo.write_config("version: 1\nscripts:\n  stub-a:\n    enabled: true\n    description: A\n")
    human = run_cli("doctor", repo=repo.path)
    assert human.returncode in (0, 4, 5)
    assert "✓" in human.stdout or "⚠" in human.stdout or "✗" in human.stdout, human.stdout

    record = doc(run_cli("doctor", "--json", repo=repo.path))
    items = record["result"]["items"]
    assert items and all(isinstance(item["ok"], bool) for item in items)
    assert record["result"]["doctor_exit_code"] == record["exit_code"]
