"""config.py: the one command that must not damage a config file (§6.6, §11.4).

The acceptance test is A8 — twenty comments, `enable`, exactly one line changes — and the
rest of the file protects the details that make that safe: atomic 0600 writes, a rollback
when the result validates badly, quoting that survives a re-read, and "all the problems at
once" instead of the first one.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from kwisatz import config as configio
from kwisatz import orchestrator
from kwisatz.errors import Exit

COMMENTED = """\
# kwisatz machine config — copied from the example, then edited by hand
# WARNING: setup-sshd must stay BEFORE configure-firewall or this box locks itself out
version: 1
scripts:
  # the box-level bits; safe to re-run
  setup-basics:
    enabled: true
    description: basics  # trailing comment that matters to a human
    env:
      NVM_VERSION: 0.40.4
      TRAEFIK_SECRET: hunter2  # keep in sync with /srv/traefik/.env
  # not installed here on purpose (disk)
  setup-docker:
    enabled: false
    args:
      - --skip-pull
  traefik:
    enabled: false
    # description intentionally missing
"""


@pytest.fixture
def checkout(tmp_path):
    (tmp_path / "tasks").mkdir()
    for name in ("setup-basics", "setup-docker", "traefik"):
        (tmp_path / "tasks" / f"{name}.sh").write_text("#!/bin/bash\n")
    path = tmp_path / "machine-config.yml"
    path.write_text(COMMENTED)
    return tmp_path, path


def read(path: Path) -> str:
    return path.read_text()


def test_enable_changes_one_line_and_nothing_else(checkout):
    """A8: the whole promise of `kwisatz config` is that the comments survive it byte-for-byte."""
    root, path = checkout
    doc = configio.load(path)
    configio.set_enabled(doc, "traefik", True)
    before = read(path)
    configio.dump(doc, path)
    after = read(path)
    changed = [(a, b) for a, b in zip(before.splitlines(), after.splitlines()) if a != b]
    assert changed == [("    enabled: false", "    enabled: true")], changed
    assert len(before.splitlines()) == len(after.splitlines())
    assert "# WARNING: setup-sshd" in after
    assert "trailing comment that matters" in after
    # and the runner agrees it is enabled now
    config = orchestrator.load_config(path, root)
    assert orchestrator.build_plan(config, warn=lambda _m: None).enabled


def test_a_file_with_many_comments_keeps_them_all(checkout):
    root, path = checkout
    doc = configio.load(path)
    configio.set_env(doc, "setup-docker", "EXTRA_FLAGS", "--no-proxy")
    configio.dump(doc, path)
    assert read(path).count("#") == COMMENTED.count("#")
    assert COMMENTED.splitlines()[1] in read(path)


def test_write_is_atomic_and_mode_0600(checkout):
    root, path = checkout
    doc = configio.load(path)
    configio.set_enabled(doc, "setup-docker", True)
    configio.dump(doc, path, backup=configio.backup_path(root / ".kwisatz", path))
    assert oct(path.stat().st_mode & 0o777) == "0o600"
    assert not list(root.glob("*.tmp")), "the temp file must not be left behind"


def test_backups_keep_the_last_five(checkout):
    root, path = checkout
    work = root / ".kwisatz"
    for i in range(7):
        doc = configio.load(path)
        configio.set_enabled(doc, "traefik", i % 2 == 0)
        configio.dump(doc, path, backup=configio.backup_path(work, path))
    copies = sorted((work / "config-backups").glob("machine-config.yml.*"))
    assert len(copies) == 5


def test_set_quotes_a_value_that_would_read_back_as_a_bool(checkout):
    root, path = checkout
    doc = configio.load(path)
    configio.set_env(doc, "setup-basics", "DOCKER_ENABLED", "true")
    configio.dump(doc, path)
    config = orchestrator.load_config(path, root)
    entry = config.entry("setup-basics")
    assert entry["env"]["DOCKER_ENABLED"] == "true"
    # a number is written plainly whenever it was plain before; either spelling of an
    # env value reaches the script as the same string, so the rule is "read back as text"
    configio.set_env(doc, "traefik", "TRAEFIK_PORT", "8443")
    configio.dump(doc, path)
    config = orchestrator.load_config(path, root)
    assert config.entry("traefik")["env"]["TRAEFIK_PORT"] == "8443"


def test_set_refuses_the_keys_that_other_commands_own(checkout):
    root, path = checkout
    doc = configio.load(path)
    from kwisatz.errors import CliError

    with pytest.raises(CliError):
        configio.set_env(doc, "traefik", "enabled", "true")
    with pytest.raises(CliError):
        configio.set_env(doc, "traefik", "description", "nope")


def test_unset_reports_whether_anything_changed(checkout):
    root, path = checkout
    doc = configio.load(path)
    assert configio.unset_env(doc, "setup-basics", "NVM_VERSION") is True
    assert configio.unset_env(doc, "setup-basics", "NVM_VERSION") is False
    assert configio.unset_key(doc, "setup-docker", "args") is True


def test_args_replace_verbatim(checkout):
    root, path = checkout
    doc = configio.load(path)
    configio.set_args(doc, "setup-docker", ["--pull", "--dry-run"])
    configio.dump(doc, path)
    config = orchestrator.load_config(path, root)
    assert config.entry("setup-docker")["args"] == ["--pull", "--dry-run"]


def test_enabling_a_script_that_is_not_in_the_config_appends_a_key(checkout):
    """R-APP-020 says the script is runnable anyway, so `config enable` must be able to say so."""
    root, path = checkout
    (root / "tasks" / "setup-unsloth.sh").write_text("#!/bin/bash\n")
    doc = configio.load(path)
    configio.set_enabled(doc, "setup-unsloth", True)
    configio.dump(doc, path)
    config = orchestrator.load_config(path, root)
    assert orchestrator.build_plan(config, warn=lambda _m: None).enabled[-1].name == "setup-unsloth"


def test_validate_finds_every_problem_at_once(tmp_path):
    (tmp_path / "tasks").mkdir()
    (tmp_path / "tasks" / "setup-docker.sh").write_text("#!/bin/bash\n")
    path = tmp_path / "machine-config.yml"
    path.write_text(
        "version: 1\n"
        "scripts:\n"
        "  setup-docker:\n"
        "    enabled: yes\n"
        "    env: [not, a, mapping]\n"
        "  setup-gone:\n"
        "    enabled: true\n"
    )
    problems = configio.problems(path, tmp_path)
    assert len(problems) >= 3, problems
    assert any("not a YAML boolean" in p for p in problems)
    assert any("setup-gone" in p for p in problems)


def test_validate_uses_the_runner_s_own_checks(tmp_path):
    """`validate` green ⇒ `apply` sane: same file, same parser, no second implementation."""
    (tmp_path / "tasks").mkdir()
    path = tmp_path / "machine-config.yml"
    path.write_text("version: 1\nscripts:\n  setup-docker: enabled\n")
    assert any("mapping of enabled/env/args" in p for p in configio.problems(path, tmp_path))


def test_diff_masks_secret_values_only(checkout):
    root, path = checkout
    doc = configio.load(path)
    configio.set_env(doc, "setup-basics", "TRAEFIK_SECRET", "new-value")
    lines = configio.diff(read(path), configio.dumps(doc))
    assert any("TRAEFIK_SECRET: ***" in line for line in lines)
    assert not any("new-value" in line for line in lines)


def test_restore_undoes_a_write(checkout):
    root, path = checkout
    before = read(path)
    doc = configio.load(path)
    configio.set_enabled(doc, "setup-docker", True)
    configio.dump(doc, path)
    assert read(path) != before
    configio.restore(path, before)
    assert read(path) == before


def test_dumps_is_a_preview_not_a_write(checkout):
    root, path = checkout
    before = read(path)
    doc = configio.load(path)
    configio.set_enabled(doc, "setup-docker", True)
    assert read(path) == before
    assert "enabled: true" not in [line for line in before.splitlines()]
    assert configio.dumps(doc) != before
    assert read(path) == before


def test_a_missing_config_is_a_clean_error(tmp_path):
    from kwisatz.errors import CliError

    with pytest.raises(CliError) as excinfo:
        configio.load(tmp_path / "machine-config.yml", )
    assert excinfo.value.code == Exit.CONFIG


def test_an_unparsable_config_names_the_file(tmp_path):
    from kwisatz.errors import CliError

    path = tmp_path / "machine-config.yml"
    path.write_text("version: 1\nscripts:\n  a: [1, 2\n  b: ]\n")
    with pytest.raises(CliError) as excinfo:
        configio.load(path)
    assert str(path) in excinfo.value.message


def test_a_top_level_that_is_not_a_config_is_rejected(tmp_path):
    from kwisatz.errors import CliError

    path = tmp_path / "machine-config.yml"
    path.write_text("# just a comment\nversion: 1\n")
    with pytest.raises(CliError):
        configio.load(path)


def test_write_mode_and_owner_of_a_new_file(tmp_path):
    path = tmp_path / "machine-config.yml"
    configio.atomic_write(path, "version: 1\nscripts: {}\n")
    assert oct(path.stat().st_mode & 0o777) == "0o600"
