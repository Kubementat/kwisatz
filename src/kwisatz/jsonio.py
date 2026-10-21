"""The machine-readable envelope (§8). One JSON document on stdout, no exceptions.

Additive fields only within `schema_version`; a removal is a version bump plus a
release note. Env values are masked everywhere unless `--reveal` was passed.
"""

from __future__ import annotations

import sys
from typing import Any

SCHEMA_VERSION = 1

TAIL_LINES = 40
TAIL_BYTES = 16 * 1024


def mask_env(env: dict[str, str], *, reveal: bool = False) -> dict[str, str]:
    if reveal:
        return dict(env)
    return {k: ("***" if _secretish(k) else v) for k, v in env.items()}


def _secretish(key: str) -> bool:
    upper = key.upper()
    return any(t in upper for t in ("KEY", "SECRET", "TOKEN", "PASSWORD", "PASS", "CRED"))


def envelope(
    *,
    command: str,
    ok: bool,
    exit_code: int,
    started_at: str,
    duration_ms: int,
    repo: dict[str, Any] | None = None,
    config: dict[str, Any] | None = None,
    result: Any = None,
    warnings: list[str] | None = None,
    errors: list[dict] | None = None,
) -> dict[str, Any]:
    doc: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "command": command,
        "ok": ok,
        "exit_code": exit_code,
        "started_at": started_at,
        "duration_ms": duration_ms,
    }
    if repo is not None:
        doc["repo"] = repo
    if config is not None:
        doc["config"] = config
    if result is not None:
        doc["result"] = result
    if warnings:
        doc["warnings"] = warnings
    if errors:
        doc["errors"] = errors
    return doc


def emit(doc: dict[str, Any]) -> None:
    """Print the document as the only thing on stdout."""
    import json

    json.dump(doc, sys.stdout)
    sys.stdout.write("\n")
