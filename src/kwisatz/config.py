"""`machine-config.yml` read the careful way: round-trip, atomic write, validate.

The file is the operator's contract with a machine, and its comments carry real warnings
(ordering, lockout risks — `specification/project/conventions.md`). So a `kwisatz config`
edit must change one line and leave the rest byte-identical (R-CFG-002 / R-ARCH-200). Three
rules follow from that and are the whole point of this module:

  * ruamel round-trip (`preserve_quotes=True`, `indent=2`) is the *only* writer — never a
    regex, never `yaml.safe_dump`;
  * writes go to a temp file in the same directory, `chmod 0600`, then `os.replace` — the
    file is plain text sitting next to nothing that is encrypted, and it is the input to
    privileged scripts (R-CFG-003);
  * validation reads the file the way the *runner* reads it (`yaml.BaseLoader`), so
    "validate passed" means exactly what `apply` will do (R-CFG-007).

The ruamel import is lazy on purpose: `status`/`list`/`apply` must keep working on an
interpreter that only has pyyaml (R-ARCH-101), and it is better to name the missing
dependency when the writer is actually used.
"""

from __future__ import annotations

import difflib
import os
import re
import tempfile
from datetime import datetime, timezone
from io import StringIO
from pathlib import Path

from . import orchestrator
from .errors import CliError, Exit, usage

CANONICAL_TRUE = "true"
CANONICAL_FALSE = "false"
# a key/value pair as written, flow-style mappings included; the value is masked when the
# key looks like a secret, so `KEY: abc` in a diff keeps telling the operator something real
_PAIR = re.compile(r"([A-Za-z0-9_]+)\s*:\s*([^,{}]+)")
_SECRET_KEYS = ("KEY", "SECRET", "TOKEN", "PASSWORD", "PASS", "CRED")


def _is_secret(key: str) -> bool:
    return any(t in key.upper() for t in _SECRET_KEYS)


def _yml():
    """One configured YAML object per call; a missing ruamel is a PREREQUISITE, not a traceback."""
    try:
        from ruamel.yaml import YAML
    except ImportError as e:
        raise CliError(
            Exit.PREREQUISITE,
            "editing machine-config.yml needs ruamel.yaml, which this interpreter does not have",
            hint=f"uv sync --project {Path(__file__).resolve().parents[2]}   (or use ./kwisatz)",
        ) from e
    yml = YAML()
    yml.preserve_quotes = True
    yml.indent(mapping=2, sequence=2, offset=2)
    return yml


def _map():
    """A ruamel ordered mapping, used where a plain dict would throw away comments."""
    from ruamel.yaml.comments import CommentedMap

    return CommentedMap()


def _mapping(value) -> bool:
    """True for "this is a mapping" in either representation (dict or CommentedMap)."""
    return isinstance(value, dict)


def _quoted(value: str):
    from ruamel.yaml.scalarstring import SingleQuotedScalarString

    return SingleQuotedScalarString(value)


# ── read / write ────────────────────────────────────────────────────────────────────


def load(path: Path):
    """Read the file as round-trip data; a broken file is one clean CONFIG error naming it."""
    try:
        text = path.read_text()
    except OSError as e:
        detail = "the file does not exist" if isinstance(e, FileNotFoundError) else f"{type(e).__name__}: {e}"
        raise CliError(
            Exit.CONFIG,
            f"{path}: cannot read config ({detail})",
            hint="kwisatz init writes machine-config.yml from the shipped example",
        ) from e
    try:
        doc = _yml().load(StringIO(text))
    except Exception as e:  # ruamel raises several kinds; the operator needs one line
        raise CliError(
            Exit.CONFIG,
            f"{path}: cannot parse the config ({type(e).__name__}: {e})",
            hint="kwisatz config validate --json",
        ) from e
    if doc is None:
        raise CliError(Exit.CONFIG, f"{path}: the file is empty", hint="copy the .example over it")
    if not _mapping(doc) or "scripts" not in doc:
        raise CliError(
            Exit.CONFIG,
            f"{path}: expected a `.scripts:` mapping at the top level",
            hint="kwisatz config validate --json",
        )
    if not _mapping(doc["scripts"]):
        raise CliError(Exit.CONFIG, f"{path}: `.scripts:` is not a mapping", hint="kwisatz config validate")
    return doc


def dumps(doc) -> str:
    """The text `dump()` would write, produced without touching the file (`--dry-run`)."""
    buffer = StringIO()
    _yml().dump(doc, buffer)
    return buffer.getvalue()


def dump(doc, path: Path, *, backup: Path | None = None) -> str:
    """Write `doc` atomically and return the new text; `backup` keeps the old bytes."""
    new = dumps(doc)
    old = path.read_text() if path.exists() else ""
    if new == old:
        return new
    if backup is not None and old:
        backup.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        backup.write_text(old)
        _rotate_backups(backup.parent, backup.name)
    atomic_write(path, new)
    return new


def atomic_write(path: Path, text: str) -> None:
    """Temp file in the same directory, mode 0600, then `os.replace` (R-CFG-003)."""
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def restore(path: Path, text: str) -> None:
    """Undo a write — the only correct answer to a config that just validated badly."""
    atomic_write(path, text)


def backup_path(repo_work: Path | None, target: Path, when: datetime | None = None) -> Path:
    """`.kwisatz/config-backups/<name>.<utc-ts>` — kept next to the run state, not in git."""
    # microseconds, not seconds: a scripted loop can write the file twice in one second, and
    # two writes that collide on a name silently lose one of the two backups
    stamp = (when or datetime.now(timezone.utc)).strftime("%Y%m%dT%H%M%S%fZ")
    base = repo_work or target.parent
    return base / "config-backups" / f"{target.name}.{stamp}"


def _rotate_backups(directory: Path, keep: str) -> None:
    """R-ARCH-202: the last 5 copies of a file the repo deliberately does not track."""
    prefix = keep.rsplit(".", 1)[0]
    copies = sorted(p for p in directory.glob(f"{prefix}.*Z") if p.is_file())
    for stale in copies[:-5]:
        stale.unlink(missing_ok=True)


# ── the entry accessors (one place, so a mutation cannot miss a shape check) ────────


def scripts(doc):
    return doc["scripts"]


def entry_of(doc, name: str):
    """The entry for `name`, creating the key when the script has no entry yet.

    `kwisatz config enable unsloth` must work for a script that is not in
    `machine-config.yml` (R-APP-020 says it is runnable anyway), so appending a key — at the
    end, in the file's own style — is a supported mutation.
    """
    entries = scripts(doc)
    entry = entries.get(name)
    if entry is None or orchestrator.is_null(entry):
        entries[name] = _map()
        entry = entries[name]
    if not _mapping(entry):
        raise CliError(
            Exit.CONFIG,
            f"{name}: expected a mapping of enabled/env/args, got {entry!r}",
            hint="kwisatz config validate",
        )
    return entry


def set_enabled(doc, name: str, want: bool) -> None:
    """Flip `.enabled` with the spelling the runner accepts without warning (R-CFG-004).

    A Python `bool` round-trips as the plain scalar `true`, which is what every shipped
    example uses; the string `"true"` would come back quoted and change the line's character
    for no reason.
    """
    entry_of(doc, name)["enabled"] = bool(want)


def set_env(doc, name: str, key: str, value: str) -> None:
    """`config set TARGET KEY=VALUE`, quoted only where a plain scalar would read back wrong."""
    if key == "enabled":
        raise usage(
            "config set cannot edit `enabled` — enable/disable is that command",
            hint=f"kwisatz config {'enable' if value == CANONICAL_TRUE else 'disable'} {name}",
        )
    if key == "description":
        raise usage("config set cannot edit `description`", hint="edit it in machine-config.yml")
    entry = entry_of(doc, name)
    env = entry.get("env")
    if env is None or orchestrator.is_null(env):
        entry["env"] = _map()
        env = entry["env"]
    if not _mapping(env):
        raise CliError(Exit.CONFIG, f"{name}: `env:` is not a mapping", hint="kwisatz config validate")
    env[key] = _scalar(value)


def _scalar(value: str):
    """Quote a string that would otherwise re-read as a bool/null (R-CFG-004).

    Everything else is plain: `'8080'` and `8080` both reach a task script as `8080` (the
    config is parsed with `yaml.BaseLoader`), so quoting numbers only churns the diff.
    """
    if value.strip().lower() in ("true", "false", "yes", "on", "off", "null", "~", "none"):
        return _quoted(value)
    return value


def unset_env(doc, name: str, key: str) -> bool:
    """`config unset TARGET KEY`; True when a key actually went away."""
    entry = entry_of(doc, name)
    env = entry.get("env")
    if _mapping(env) and key in env:
        del env[key]
        return True
    return False


def unset_key(doc, name: str, key: str) -> bool:
    """Drop a structural key (`description`, `args`, `env`) of one entry."""
    entry = entry_of(doc, name)
    if key in entry:
        del entry[key]
        return True
    return False


def set_args(doc, name: str, args: list[str]) -> None:
    entry_of(doc, name)["args"] = [str(a) for a in args]


# ── validation and diff ─────────────────────────────────────────────────────────────


def problems(path: Path, root: Path) -> list[str]:
    """Every complaint at once (R-CFG-007), read the way `apply` reads it.

    Shape and value checks are `orchestrator`'s own functions, so there is no second
    implementation that could disagree with the run path.
    """
    try:
        config = orchestrator.load_config(path, root)
    except orchestrator.ConfigError as e:
        return [str(e)]
    messages: list[str] = []
    warned: list[str] = []
    for name, raw in config.scripts:
        try:
            entry = orchestrator.check_shape(name, raw, config)
        except orchestrator.ConfigError as e:
            messages.append(str(e))
            continue
        enabled = orchestrator.is_enabled(name, entry, warn=warned.append)
        try:
            orchestrator.check_values(name, entry, strict=enabled, config=config, warn=warned.append)
        except orchestrator.ConfigError as e:
            messages.append(str(e))
        messages.extend(warned)
        warned.clear()
        if enabled and not _has_task_file(root, name):
            messages.append(f"{name}: enabled, but there is no tasks/{name}.sh or tasks/{name}.py to run")
    return messages


def _has_task_file(root: Path, name: str) -> bool:
    tasks = root / "tasks"
    return (tasks / f"{name}.sh").is_file() or (tasks / f"{name}.py").is_file()


def diff(old: str, new: str, *, mask: bool = True) -> list[str]:
    """The `-`/`+` lines of a write, with secret-looking values masked (R-CFG-005)."""

    def scrub(line: str) -> str:
        if not mask:
            return line
        return _PAIR.sub(lambda m: f"{m.group(1)}: ***" if _is_secret(m.group(1)) else m.group(0), line)

    return [
        scrub(line)
        for line in difflib.unified_diff(
            old.splitlines(), new.splitlines(), lineterm="", n=1, fromfile="a", tofile="b"
        )
    ]
