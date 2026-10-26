"""The CLI as an operator runs it: real process, real exit code, real side effects (§12.1.3).

Every assertion here is about an observable a human or agent depends on — stdout/stderr
split, the exit code, what ended up on disk — because the unit tests already cover the
internals. Where the spec names an acceptance criterion (A2…A7) the test says so.
"""

from __future__ import annotations

import ast
import difflib
import inspect
import json
import os
import stat
from pathlib import Path

import pytest
from conftest import run_cli, stub

from kwisatz import cli as cli_module

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
    work.write_config(
        "version: 1\nscripts:\n  stub-a:\n    enabled: true\n  stub-b:\n    enabled: true\n  stub-c:\n    enabled: true\n"
    )
    result = run_cli("apply", "--repo", str(work.path), "--json", repo=work.path)
    body = doc(result)
    assert result.returncode == 1
    assert body["result"]["items"][1]["status"] == "failed"
    assert body["errors"][0]["target"] == "stub-b"
    # the stop is said out loud, with the real count, for the targets that really did not run
    assert "remaining 1 script(s) did not run" in result.stderr, result.stderr
    assert not (work.records / "stub-c.txt").exists()


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


def test_a_name_that_is_not_a_typo_gets_no_suggestion_at_all(work):
    """R-CMD-002's other half: `closest:` for a typo, nothing for a name from another tool.

    `similar()` used to have no cutoff, so `zzzzz` was advised five names that were merely the
    first ones sorted — and the command table, which *did* gate on distance, answered differently
    for the same spec clause.
    """
    target = run_cli("apply", "zzzzz", "--repo", str(work.path), repo=work.path)
    assert target.returncode == 3
    assert "closest:" not in target.stderr, target.stderr
    assert "unknown target" in target.stderr

    verb = run_cli("zzzzz", repo=work.path)
    assert verb.returncode == 2
    assert "did you mean" not in verb.stderr, verb.stderr


def test_a_two_edit_misspelling_still_gets_the_command_name():
    """The cutoff is two, so a transposition is not left without advice."""
    result = run_cli("aply")
    assert result.returncode == 2
    assert "did you mean: kwisatz apply" in result.stderr


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


def _state_lines(work, groups: list[list[str]]) -> None:
    """Apply history without running anything: one JSON line per run, oldest first (§6.9)."""
    (work.path / ".kwisatz").mkdir(exist_ok=True)
    (work.path / ".kwisatz" / "state.jsonl").write_text(
        "".join(
            json.dumps(
                {
                    "command": "apply",
                    "exit_code": 0,
                    "items": [{"target": name, "status": "applied"} for name in group],
                }
            )
            + "\n"
            for group in groups
        )
    )


def test_state_resolves_the_target_so_a_typo_is_not_no_history(work):
    """§6.9: `state <target>` must not answer a misspelling like a target that never ran.

    The same records read `count 0, exit 0` for a name that is not a target and for a target that
    really was never applied — indistinguishable, and the 0 invites the caller to move on. The fix
    is the existing `planner.resolve_target` seam (the one `info` and `run` use), so an unknown
    name is exit 3 with the `closest:` suggestion. An absent argument still means "every run".
    """
    _state_lines(work, [["stub-a", "stub-c"], ["stub-a"], ["stub-b"]])

    filtered = doc(run_cli("state", "stub-a", "--json", "--repo", str(work.path), repo=work.path))
    assert filtered["result"]["count"] == 2
    one = doc(run_cli("state", "stub-b", "--json", "--repo", str(work.path), repo=work.path))
    assert one["result"]["count"] == 1

    typo = run_cli("state", "stub-x", "--json", "--repo", str(work.path), repo=work.path)
    assert typo.returncode == 3, typo.stderr
    body = doc(typo)
    assert body["errors"][0]["target"] == "stub-x"
    assert "closest" in body["errors"][0]["hint"]

    everything = doc(run_cli("state", "--json", "--repo", str(work.path), repo=work.path))
    assert everything["result"]["count"] == 3, "no argument still means every record"


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


def test_logs_tells_an_unknown_target_apart_from_one_that_never_logged(work):
    """R-OPS-005: "no stack, no unit, no apply log" was also the answer to a typo.

    The sentence describing a target with nothing to read is byte-identical to the one a name that
    is not a target gets, so "never heard of it" looked exactly like "ran, produced nothing". The
    name is resolved before any source is chosen — the same seam `info` uses — so the typo gets
    exit 3 with `closest:`, while a valid target that logged nothing keeps its empty answer and
    its 3.
    """
    typo = run_cli("logs", "stub-x", "--json", "--repo", str(work.path), repo=work.path)
    assert typo.returncode == 3, typo.stderr
    body = doc(typo)
    assert body["errors"][0]["target"] == "stub-x"
    assert "closest" in body["errors"][0]["hint"]
    assert "no stack" not in typo.stdout, "the empty message must never describe an unknown name"

    quiet = run_cli("logs", "stub-b", "--json", "--repo", str(work.path), repo=work.path)
    assert quiet.returncode == 3, quiet.stderr
    assert "no stack, no unit, no apply log" in doc(quiet)["errors"][0]["message"]

    assert run_cli("logs", "--json", "--repo", str(work.path), repo=work.path).returncode == 2


def test_logs_follow_is_bounded_by_timeout_and_never_prints_a_traceback(work):
    """R-OPS-005: `-f` is bounded by `--timeout`. Bounded is not the same thing as crashed.

    `logsio.stream()` passed the follow to `subprocess.run(timeout=…)` and nobody caught the
    `TimeoutExpired`, so a follow that reached its deadline ended in a Python traceback and exit
    `1`. Only the non-JSON path was affected, because `capture()` swallows the same exception.

    The fake `docker` is what makes a compose source exist without a daemon: discovery asks for
    `info --format`, `compose ls` and `ps -a`, and every other call — the follow is one — sleeps,
    exactly as `compose logs --follow` does while a stack is quiet.
    """
    stack = work.path / "srv" / "stub-a"
    stack.mkdir(parents=True)
    compose = stack / "docker-compose.yml"
    compose.write_text("services: {}\n")
    shim = work.path / "bin"
    shim.mkdir()
    docker = shim / "docker"
    docker.write_text(
        "#!/usr/bin/env bash\n"
        'case "$1 $2" in\n'
        '  "info --format") echo 29.0 ;;\n'
        '  "compose ls") echo \'[{"Name":"stub-a","ConfigFiles":"__COMPOSE__"}]\' ;;\n'
        '  "ps -a") echo \'{}\' ;;\n'
        # exec, so the sleeping process *is* the child: subprocess.run kills it at the bound
        # instead of leaving an orphaned `sleep` behind in the test session
        "  *) exec sleep 30 ;;\n"
        "esac\n".replace("__COMPOSE__", str(compose))
    )
    docker.chmod(0o755)
    result = run_cli(
        "logs",
        "stub-a",
        "--follow",
        "--timeout",
        "2",
        "--repo",
        str(work.path),
        repo=work.path,
        env={"PATH": f"{shim}:/usr/bin:/bin"},
    )
    assert "Traceback" not in result.stderr, result.stderr[-500:]
    assert result.returncode == 0, result.stderr
    assert "--timeout" in result.stderr, "the human answer must say the bound ended the follow"


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


def test_the_timeout_budget_is_the_commands_not_each_targets(work):
    """§5.2 / ticket 1: `--timeout` bounded the whole command; the code handed every target the
    whole number, so two 40 s scripts under `--timeout 50` needed 80 s and the flag lied.

    With the budget shared the second target gets only the leftover, so it dies at the deadline
    instead of starting a fresh one. Asserted on the wall clock and not on a message: a
    per-target budget is *indistinguishable* in the document, only slower.
    """
    for name in ("slow-a", "slow-b"):
        script = work.path / "tasks" / f"{name}.sh"
        script.write_text("#!/usr/bin/env bash\nsleep 2\n")
        script.chmod(0o755)
    work.write_config("version: 1\nscripts:\n  slow-a:\n    enabled: true\n  slow-b:\n    enabled: true\n")
    result = run_cli("apply", "--timeout", "4", "--json", "--repo", str(work.path), repo=work.path)
    body = doc(result)
    assert result.returncode == 5, result.stderr
    assert body["result"]["items"][1]["status"] == "failed", body["result"]["items"]
    assert "timed out" in body["errors"][-1]["message"]
    # two per-target budgets would need ~2 × (2 s + deploy) ≥ 5 s; the command ends at 4 s
    assert body["duration_ms"] < 4500, body["duration_ms"]


def test_apply_needing_sudo_stops_at_four_instead_of_prompting(work):
    """§9: a missing prerequisite is `4`. Before this, the deploy asked getpass on /dev/null.

    The §6.5 table says `setup-docker` wants sudo, so the box either has passwordless sudo or the
    operator cached a ticket. Neither is true here — and the only honest answer is to stop before
    running anything, because pyinfra's stdin is /dev/null and `sudo` answers that with a getpass
    that dies inside gevent (exit 1, a traceback, and a "retry this target" hint).
    """
    script = work.path / "tasks" / "setup-docker.sh"
    script.write_text("#!/usr/bin/env bash\nsudo apt-get install -y docker.io\n")
    script.chmod(0o755)
    # a `sudo` that always asks for a password, first on PATH, so the verdict does not depend on
    # the sudoers of the machine running this test
    bindir = work.path / "bin"
    bindir.mkdir()
    fake = bindir / "sudo"
    fake.write_text("#!/bin/sh\necho 'sudo: a password is required' >&2\nexit 1\n")
    fake.chmod(0o755)
    result = run_cli(
        "apply", "setup-docker", "--json", "--repo", str(work.path), repo=work.path,
        env={"PATH": f"{bindir}:/usr/bin:/bin"},
    )
    assert result.returncode == 4, result.stderr
    body = doc(result)
    assert body["errors"][0]["target"] == "setup-docker"
    assert "--interactive" in body["errors"][0]["hint"]
    assert "Traceback" not in result.stderr and "gevent" not in result.stderr, result.stderr
    assert not list(work.records.glob("*.txt")), "nothing may run on a box that cannot sudo"
    assert not (work.path / ".kwisatz" / "state.jsonl").exists()


def test_a_spent_budget_leaves_the_rest_not_run_and_exits_five(work):
    """The deadline stops the run mid-way, which is exit `5` even with `--keep-going`.

    That flag promises *it finished*; a budget that ran out between two targets says exactly the
    opposite, so the untouched target is `not-run` rather than a skipped-but-finished run.
    """
    for name in ("slow-a", "slow-b"):
        script = work.path / "tasks" / f"{name}.sh"
        script.write_text("#!/usr/bin/env bash\nsleep 4\n")
        script.chmod(0o755)
    work.write_config("version: 1\nscripts:\n  slow-a:\n    enabled: true\n  slow-b:\n    enabled: true\n")
    result = run_cli("apply", "--keep-going", "--timeout", "3", "--json", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 5, result.stderr
    body = doc(result)
    assert [i["status"] for i in body["result"]["items"]] == ["failed", "not-run"]
    assert body["result"]["skipped"] == 1
    assert any("budget ran out" in e["message"] for e in body["errors"]), body["errors"]


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


def test_verbose_raises_the_output_level_quiet_lowers(work):
    """`-v` was advertised in `--help` and in `commands --json`, parsed, and read by nobody.

    `apply`, `apply -v` and `apply -vv` came out byte-identical because the count landed on the
    output policy and stopped there. It now says what is about to run, on stderr: the detail has
    to arrive somewhere an operator can see, and stdout already belongs to the result.
    """
    plain = run_cli("apply", "stub-a", "--repo", str(work.path), repo=work.path)
    assert plain.returncode == 0, plain.stderr
    verbose = run_cli("-v", "apply", "stub-a", "--repo", str(work.path), repo=work.path)
    assert verbose.returncode == 0, verbose.stderr
    assert verbose.stdout == plain.stdout, "verbosity is not a second result"
    assert verbose.stderr != plain.stderr, "-v changed nothing"
    assert "deploy.py" in verbose.stderr, verbose.stderr
    assert "-y -vvv -v --data" in verbose.stderr, verbose.stderr
    assert "-y -vvv" not in plain.stderr, "the deploy command line belongs to -v, not to every run"


def test_repeating_verbose_repeats_the_deploy_detail(work):
    """`-vv` is a count of two, so it asks for more than `-v` did: the deploy line says so."""
    loud = run_cli("-v", "apply", "stub-a", "--repo", str(work.path), repo=work.path)
    louder = run_cli("-vv", "apply", "stub-a", "--repo", str(work.path), repo=work.path)
    assert louder.returncode == 0, louder.stderr
    assert "-y -vvv -v -v --data" in louder.stderr, louder.stderr
    assert "-y -vvv -v -v --data" not in loud.stderr, "-v and -vv ran the same command"


def test_json_is_one_document_at_every_verbosity(work):
    """R-JSON-001: `-v` adds stderr detail, never a second line on stdout.

    A `-v` debug session that breaks the document is the bug that only shows up while debugging,
    so all three levels answer with exactly one JSON document.
    """
    for flags in ([], ["-v"], ["-vv"]):
        body = doc(
            run_cli(*flags, "apply", "stub-a", "--json", "--repo", str(work.path), repo=work.path)
        )
        assert body["ok"] is True, body


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


# ── `kwisatz run`: the pass-through contract (R-CMD-004 / R-EXIT-001 / R-SAFE-002) ──────────
# The command an operator reaches for when a script needs a flag the CLI has never heard of,
# so it is also the command whose parsing is most easily wrong. `run` had no test of its own
# until this file grew these.


def test_run_forwards_everything_after_the_double_dash(work):
    """R-CMD-004: the script's own flags are its business — `--` hands them over verbatim."""
    result = run_cli(
        "run", "--repo", str(work.path), "stub-a", "--", "--force", "--check", repo=work.path
    )
    assert result.returncode == 0, result.stderr
    assert work.read("stub-a")["argv"] == ["--force", "--check"]


def test_a_script_flag_without_a_double_dash_is_usage(work):
    """Guessing which side of `--` a flag was meant for is worse than refusing to guess."""
    result = run_cli("run", "--repo", str(work.path), "stub-a", "--force", repo=work.path)
    assert result.returncode == 2, result.stderr
    assert not list(work.records.glob("*.txt")), "usage must not have run the script"


def test_run_json_is_the_document_and_not_a_swallowed_flag(work):
    """`--json` after the target used to be forwarded to the script, leaving no document.

    A script that prints to stdout still writes onto that fd (R-JSON-001's documented
    exception), so this asserts the parsing half only: the flag is the CLI's, and the
    answer it asked for arrives.
    """
    result = run_cli("run", "--repo", str(work.path), "stub-a", "--json", repo=work.path)
    assert result.returncode == 0, result.stderr
    body = doc(result)
    assert body["command"] == "run"
    assert work.read("stub-a"), "the script ran, as it always does without --dry-run"


def test_run_dry_run_runs_nothing(work):
    """R-SAFE-002: `-n` is a global flag, and `run` was the command that quietly ignored it."""
    result = run_cli("run", "--dry-run", "--repo", str(work.path), "stub-a", repo=work.path)
    assert result.returncode == 0, result.stderr
    assert "dry run" in result.stderr
    assert not list(work.records.glob("*.txt")), "the script must not have been executed"
    assert not (work.path / "logs").exists()
    assert not (work.path / ".kwisatz" / "state.jsonl").exists()


def test_run_reports_exit_1_and_keeps_the_script_code(work):
    """R-EXIT-001: §9 owns the exit code; the script's own code survives under `result`."""
    stub(work.path, "stub-a", code=2)
    result = run_cli("run", "--repo", str(work.path), "stub-a", "--json", repo=work.path)
    assert result.returncode == 1, result.stderr
    assert doc(result)["result"]["script_exit_code"] == 2


def test_run_reports_a_spent_timeout_as_health(work):
    """R-AGE-002 / §5.2: `--timeout` killed the script, so `run` answers 5 exactly like `apply`.

    `run_task` returns `returncode=None` with `timed_out=True`, and `_map_task_exit` read the
    missing code as "no failure": `run slow --timeout 3` exited 0 with `ok: true` and a null
    `script_exit_code`, for a process group the CLI had just killed. `apply` got this verdict in
    4f33a43; the same check never reached this command.
    """
    script = work.path / "tasks" / "slow-run.sh"
    script.write_text("#!/usr/bin/env bash\nsleep 30\n")
    script.chmod(0o755)
    result = run_cli(
        "run", "slow-run", "--timeout", "2", "--json", "--repo", str(work.path), repo=work.path
    )
    assert result.returncode == 5, (result.stdout, result.stderr)
    body = doc(result)
    assert body["ok"] is False, body
    assert body["result"]["script_exit_code"] is None, "the script never got to report a code"
    assert "timed out" in body["errors"][0]["message"], body["errors"]
    # the same verdict without --json: `app.fail` is what keeps exit 5 from leaving a silence
    plain = run_cli("run", "slow-run", "--timeout", "2", "--repo", str(work.path), repo=work.path)
    assert plain.returncode == 5, plain.stderr
    assert "timed out" in plain.stderr, plain.stderr


def test_a_single_failing_target_says_nothing_about_remaining_scripts(work):
    """The last target in the run has nothing after it; "remaining 0" was pure noise."""
    stub(work.path, "stub-a", code=1)
    result = run_cli("apply", "stub-a", "--repo", str(work.path), repo=work.path)
    assert result.returncode == 1
    assert "script(s) did not run" not in result.stderr, result.stderr


def test_no_docstring_hides_behind_a_return():
    """`_add_flag` put its docstring after the early `return`, so it was a dead expression.

    `help(_add_flag)` answered "no docstring", which is the only symptom. Checked at AST level so
    the next helper with the same mistake is caught by the same test: a string statement that is
    not a function's *first* statement is a comment pretending to be documentation.
    """
    tree = ast.parse(Path(inspect.getsourcefile(cli_module)).read_text(encoding="utf-8"))
    dead = [
        f"{fn.name}:{stmt.lineno}"
        for fn in (n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef))
        for stmt in fn.body[1:]
        if isinstance(stmt, ast.Expr)
        and isinstance(stmt.value, ast.Constant)
        and isinstance(stmt.value.value, str)
    ]
    assert dead == [], "a string after the first statement is a comment, not a docstring"


def test_the_parser_helpers_are_documented():
    """The same bug, from the other side: `_add_flag.__doc__` used to be None."""
    assert cli_module._add_flag.__doc__ is not None
