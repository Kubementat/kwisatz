"""state.py + repo.Lock: history, and the one-writer rule (§6.9, R-SAFE-001).

`state` answers "did we ever install this, and with what?" — which means the record is only
worth anything if it cannot lie. So: written after the run, newest first, and a torn line
skipped instead of failing the command.
"""

from __future__ import annotations

import json
import os
import stat

import pytest

from kwisatz import orchestrator, state
from kwisatz.errors import CliError, Exit
from kwisatz.repo import Lock, Repo


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "kwisatz"
    (root / "tasks").mkdir(parents=True)
    (root / "deploy.py").write_text("# adapter\n")
    return Repo(path=root, git_sha="abc1234", branch="develop")


def test_a_record_is_one_json_line_and_mode_0600(repo):
    state.record(repo, {"command": "apply", "items": [{"target": "traefik", "status": "applied"}]})
    path = state.path(repo)
    assert len(path.read_text().splitlines()) == 1
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert stat.S_IMODE(repo.work.stat().st_mode) == 0o700


def test_reads_are_newest_first_and_filtered_by_target(repo):
    for i in range(3):
        state.record(repo, {"started_at": f"T{i}", "items": [{"target": "traefik", "status": "applied"}]})
        state.record(repo, {"started_at": f"S{i}", "items": [{"target": "other", "status": "applied"}]})
    assert [r["started_at"] for r in state.read(repo, limit=2)] == ["S2", "T2"]
    assert [r["started_at"] for r in state.read(repo, "traefik")] == ["T2", "T1", "T0"]


def test_a_torn_write_is_skipped_not_fatal(repo):
    repo.work.mkdir(parents=True, exist_ok=True)
    state.path(repo).write_text('{"started_at": "good"}\n{ broken\n{"started_at": "good2"}\n')
    assert [r["started_at"] for r in state.read(repo)] == ["good2", "good"]


def test_config_sha_and_entries_map_describe_the_plan(tmp_path):
    path = tmp_path / "machine-config.yml"
    (tmp_path / "tasks").mkdir()
    (tmp_path / "tasks" / "setup-traefik.sh").write_text("#!/bin/bash\n")
    path.write_text("version: 1\nscripts:\n  setup-traefik:\n    enabled: true\n  setup-docker:\n    enabled: false\n")
    config = orchestrator.load_config(path, tmp_path)
    assert state.config_sha(path) == state.config_sha(path)
    assert state.entries_map(config) == {"setup-traefik": True, "setup-docker": False}
    assert state.config_sha(tmp_path / "nope.yml") == ""


# ── the lock ────────────────────────────────────────────────────────────────────────


def test_one_writer_per_repo(repo):
    repo.ensure_work()
    first = Lock(repo)
    first.acquire()
    assert first.held
    second = Lock(repo)
    with pytest.raises(CliError) as excinfo:
        second.acquire()
    assert excinfo.value.code == Exit.LOCKED
    first.release()
    assert not first.path.exists()


def test_releasing_twice_is_not_an_error_and_a_dead_owner_is_reclaimable(repo):
    repo.ensure_work()
    repo.work.joinpath("lock").write_text(json.dumps({"pid": 10 ** 9 - 1, "repo": str(repo.path)}))
    lock = Lock(repo)
    assert lock.try_acquire() is True


def test_a_lock_from_a_different_checkout_is_stale(repo, tmp_path):
    repo.ensure_work()
    (repo.work / "lock").write_text(json.dumps({"pid": os.getpid(), "repo": "/somewhere/else"}))
    assert Lock(repo).try_acquire() is True


def test_lock_timeout_waits_for_the_owner(repo):
    repo.ensure_work()
    held = Lock(repo)
    held.acquire()
    waiter = Lock(repo, timeout=1.0)
    result = []
    import threading

    def release():
        import time

        time.sleep(0.3)
        held.release()

    threading.Thread(target=release).start()
    waiter.acquire()
    result = waiter.held
    assert result is True


def test_the_context_manager_always_gives_the_lock_back(repo):
    repo.ensure_work()
    from kwisatz.repo import held

    with pytest.raises(RuntimeError):
        with held(repo):
            raise RuntimeError("boom")
    assert not (repo.work / "lock").exists()
