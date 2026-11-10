"""versions.yml: the bundled default pins and the user's sparse override file.

The user file holds only what the user changed, merged per component and per field over the
default. `lib/helpers.sh:kw_pin` implements the same rule for the task scripts (a bash task
cannot import this module), so change both together; `tests/unit/test_versions_override.py`
runs them against each other.
"""

from __future__ import annotations

import os
from pathlib import Path

import yaml

from .errors import CliError, Exit

#: fields a user may override (`image` is the name `--field` accepts for `package`)
FIELDS = ("version", "package", "digest")
FIELD_ALIASES = {"image": "package"}


def user_file() -> Path | None:
    """The override file kw_pin would read: $KW_VERSIONS_OVERRIDE, else $KWISATZ_CONFIG_DIR/versions.yml."""
    if os.environ.get("KW_VERSIONS_OVERRIDE"):
        return Path(os.environ["KW_VERSIONS_OVERRIDE"])
    if os.environ.get("KWISATZ_CONFIG_DIR"):
        return Path(os.environ["KWISATZ_CONFIG_DIR"]) / "versions.yml"
    return None


def load(path: Path | None) -> dict:
    """The mapping in `path`; a missing file is empty, a broken one is a CONFIG error naming it."""
    if path is None or not path.is_file():
        return {}
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except (OSError, yaml.YAMLError) as e:
        raise CliError(Exit.CONFIG, f"{path}: cannot read versions ({e})") from e
    if not isinstance(data, dict):
        raise CliError(Exit.CONFIG, f"{path}: expected a mapping of component to pin")
    return data


def unknown(default: dict, user: dict) -> list[str]:
    """Override keys the default file does not have — a typo, or a component that was removed."""
    return sorted(str(k) for k in user if k not in default)


def merge_entry(default: dict, part: dict | None) -> dict:
    entry = {**default, **(part or {})}
    if part and "version" in part and "digest" not in part:
        entry.pop("digest", None)  # a digest belongs to the version it was pinned with
    return entry


def is_stale(user_version: str, default_version: str) -> bool:
    """The user's pin is older than the bundled one (or merely different when they do not compare)."""
    if user_version == default_version:
        return False
    try:
        from packaging.version import InvalidVersion, Version

        return Version(user_version.lstrip("v")) < Version(default_version.lstrip("v"))
    except (ImportError, InvalidVersion):
        return True


def rows(default: dict, user: dict) -> list[dict]:
    """One effective pin per component, with where it came from."""
    out = []
    for name in sorted(default):
        part = user.get(name) if isinstance(user.get(name), dict) else None
        entry = merge_entry(default[name], part)
        row = {
            "component": name,
            "version": str(entry.get("version", "")),
            "package": entry.get("package"),
            "digest": entry.get("digest"),
            "source": "user" if part else "default",
            "default_version": str(default[name].get("version", "")),
            "stale": False,
        }
        if part and "version" in part:
            row["stale"] = is_stale(row["version"], row["default_version"])
        out.append(row)
    return out


def effective(default: dict, user: dict) -> dict:
    """The full merged mapping, in the default's schema (what `versions check` looks up)."""
    return {k: merge_entry(v, user.get(k) if isinstance(user.get(k), dict) else None) for k, v in default.items()}
