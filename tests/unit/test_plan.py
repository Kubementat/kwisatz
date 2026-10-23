"""plan.py: what a user's word means, and in what order it runs (§4, §6.2, §6.3).

Target resolution is the part of the CLI an agent depends on most and can most easily get
wrong, so it is tested on the failure modes, not the happy paths: two spellings of one
script must be one target, two different scripts must not be one target, and a typo must
come back with candidates instead of silence.
"""

from __future__ import annotations

import pytest

from kwisatz import orchestrator
from kwisatz import plan as planner
from kwisatz.errors import CliError, Exit


@pytest.fixture
def checkout(tmp_path):
    """A checkout with two scripts and a config that mentions one of them."""
    (tmp_path / "tasks").mkdir()
    (tmp_path / "tasks" / "setup-traefik.sh").write_text("#!/bin/bash\n")
    (tmp_path / "tasks" / "configure-firewall.sh").write_text("#!/bin/bash\n")
    config_path = tmp_path / "machine-config.yml"
    config_path.write_text(
        "version: 1\nscripts:\n  setup-traefik:\n    enabled: true\n    description: proxy\n"
    )
    config = orchestrator.load_config(config_path, tmp_path)
    return tmp_path, config, orchestrator.build_plan(config, warn=lambda _m: None)


def test_canonical_name_drops_the_prefix_only_at_the_front():
    assert planner.canonical("setup-traefik") == "traefik"
    assert planner.canonical("configure-firewall") == "firewall"
    assert planner.canonical("traefik") == "traefik"
    assert planner.canonical("setup-setup-traefik") == "setup-traefik"


def test_all_three_spellings_are_the_same_target(checkout):
    _, config, plan = checkout
    for name in ("traefik", "setup-traefik"):
        assert planner.resolve_target(name, config, plan).name == "setup-traefik"


def test_a_script_with_no_config_entry_is_still_a_target(checkout):
    root, config, plan = checkout
    target = planner.resolve_target("configure-firewall", config, plan)
    assert target.configured is False
    assert target.kind == "sh"
    assert target.task.argv == ["bash", str(root / "tasks" / "configure-firewall.sh")]


def test_an_unknown_name_is_config_error_with_candidates(checkout):
    _, config, plan = checkout
    with pytest.raises(CliError) as excinfo:
        planner.resolve_target("traefiks", config, plan)
    assert excinfo.value.code == Exit.CONFIG
    assert "traefik" in (excinfo.value.hint or "")


def test_a_prefix_that_matches_two_different_scripts_is_ambiguous(checkout):
    """R-TGT-001: `setup-docker.sh` and `configure-docker.sh` are two things, so `docker` is not a name."""
    root, config, plan = checkout
    (root / "tasks" / "setup-docker.sh").write_text("#!/bin/bash\n")
    (root / "tasks" / "configure-docker.sh").write_text("#!/bin/bash\n")
    with pytest.raises(CliError) as excinfo:
        planner.resolve_target("docker", config, plan)
    assert excinfo.value.code == Exit.USAGE
    assert "ambiguous" in excinfo.value.message
    assert "setup-docker" in excinfo.value.hint and "configure-docker" in excinfo.value.hint


def test_order_is_config_order_then_the_unconfigured_in_order_given(checkout):
    root, config, plan = checkout
    (root / "tasks" / "setup-unsloth.sh").write_text("#!/bin/bash\n")
    targets = [
        planner.resolve_target(name, config, plan) for name in ("unsloth", "traefik")
    ]
    ordered = planner.order_targets(targets, config)
    assert [t.name for t in ordered] == ["setup-traefik", "setup-unsloth"]


def test_the_prerequisite_table_warns_and_never_aborts(checkout):
    root, config, plan = checkout
    (root / "tasks" / "setup-docker.sh").write_text("#!/bin/bash\n")
    messages = planner.check_prerequisite_order(
        [planner.resolve_target("firewall", config, plan)],
        config,
        {"configure-firewall": ["setup-docker"]},
    )
    assert messages, "the whole point of the table is that it says something"
    assert "setup-docker" in messages[0]


def test_sh_wins_over_py_when_both_exist(checkout, capsys):
    root, config, _ = checkout
    (root / "tasks" / "setup-traefik.py").write_text("#!/usr/bin/env python3\n")
    argv = orchestrator.task_command("setup-traefik", config)
    assert argv[0] == "bash"
    assert "running the .sh" in capsys.readouterr().err


def test_plan_items_carry_the_masked_echo_the_operator_sees(checkout):
    config_path = checkout[0] / "machine-config.yml"
    config_path.write_text(
        "version: 1\nscripts:\n  setup-traefik:\n    enabled: true\n    env:\n      TRAEFIK_SECRET: abc\n"
    )
    config = orchestrator.load_config(config_path, checkout[0])
    plan = orchestrator.build_plan(config, warn=lambda _m: None)
    items = planner.plan_items(list(planner.targets_from_plan(config, plan).values()))
    assert items[0]["env"]["TRAEFIK_SECRET"] == "***"
    assert "abc" not in items[0]["echo"]


def test_task_files_prefers_sh_and_is_stable(checkout):
    root = checkout[0]
    files = planner.task_files(root)
    assert set(files) == {"setup-traefik", "configure-firewall"}
    assert files["setup-traefik"].suffix == ".sh"


def test_similarity_suggestions_are_gated_by_distance():
    """R-CMD-002: `did you mean` answers a typo, not a name that happens to be nearby.

    The gate belongs on the public name, not on `_distance` — reaching into it from the caller is
    how `apply` and the command table ended up with two different rules for one spec clause.
    """
    assert planner.similar("aply", ["apply", "status"], 1) == ["apply"]
    assert planner.similar("tragik", ["traefik"], 5) == ["traefik"], "two edits is still a typo"
    assert planner.similar("zzzzz", ["setup-pi", "setup-zed"], 5) == [], "not a typo at all"
    assert planner.similar("stub-ax", ["stub-a", "stub-c"], 5) == ["stub-a", "stub-c"]
