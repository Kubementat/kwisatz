"""Apply history (§6.9). One JSON line per run, written **after** the run.

A crashed run must not look like a success, so nothing is recorded before the scripts
have exited. `kwisatz state` is M2; `apply` already writes the records so the answer to
"did we ever install this, and with what?" exists from M1 on.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

STATE_FILE = "state.jsonl"


def path(repo) -> Path:
    return repo.work / STATE_FILE


def record(repo, entry: dict) -> None:
    repo.work.mkdir(mode=0o700, exist_ok=True)
    target = path(repo)
    with target.open("a") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")
    target.chmod(0o600)


def read(repo, target: str | None = None, limit: int = 50) -> list[dict]:
    """Most recent first, filtered by target name when given."""
    try:
        lines = path(repo).read_text().splitlines()
    except OSError:
        return []
    entries = []
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:  # a torn write; skip, never fail the command
            continue
        if not isinstance(entry, dict):
            continue
        names = {i.get("target") for i in entry.get("items", [])}
        if target and target not in names:
            continue
        entries.append(entry)
        if len(entries) >= limit:
            break
    return entries


def config_sha(path: Path) -> str:
    """A short identity of the config file, so a later run can tell it changed (R-SAFE-005)."""
    try:
        data = Path(path).read_bytes()
    except OSError:
        return ""
    return hashlib.sha256(data).hexdigest()[:12]


def entries_map(config) -> dict[str, bool]:
    """`{name: enabled}` — the part of the config an operator would say they changed.

    The same rule the runner uses (`orchestrator.is_enabled`), read silently: this is a
    history record, not the place for the "write `enabled: true`" warnings.
    """
    from . import orchestrator

    out: dict[str, bool] = {}
    for name, raw in config.scripts:
        try:
            entry = orchestrator.check_shape(name, raw, config)
        except orchestrator.ConfigError:
            out[name] = False
            continue
        out[name] = orchestrator.is_enabled(name, entry, warn=lambda _m: None)
    return out
