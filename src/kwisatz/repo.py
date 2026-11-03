"""Checkout, config-file and lock resolution (§6.10, R-SAFE-001).

kwisatz *operates on a checkout*; it does not ship one. Everything below answers one
of three questions: which repo am I running against, which config file does that mean,
and may I touch the machine right now.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
from collections.abc import Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .errors import CliError, Exit

CONFIG_JSON = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "kwisatz" / "config.json"


def payload_dir() -> Path:
    """The read-only tree shipped inside the wheel (tasks/, lib/, deploy.py, …); absent in a checkout."""
    return Path(__file__).resolve().parent / "payload"


def config_home() -> Path:
    """Where an installed-mode user keeps machine-config.yml and friends."""
    if os.environ.get("KWISATZ_HOME"):
        return Path(os.environ["KWISATZ_HOME"]).expanduser().resolve()
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "kwisatz"


def state_home() -> Path:
    """Lock, run state, config backups and logs of installed mode; also home of the machine-wide lock."""
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "kwisatz"


@dataclass
class Repo:
    path: Path
    git_sha: str = ""
    branch: str = ""
    #: `.kwisatz/` — lock, state; mode 0700, gitignored
    work: Path | None = None
    #: "checkout" (path is a git checkout, config lives in it) or "installed" (path is the wheel's payload)
    mode: str = "checkout"
    #: where machine-config.yml, models.yml, gateway.yml and the sparse versions.yml live
    config_dir: Path | None = None
    logs_dir: Path | None = None

    def __post_init__(self) -> None:
        if self.work is None:
            self.work = self.path / ".kwisatz"
        if self.config_dir is None:
            self.config_dir = self.path

    @property
    def payload(self) -> Path:
        """The read-only tree: tasks/, lib/, templates/, deploy.py, versions.yml, the examples."""
        return self.path

    @property
    def logs(self) -> Path:
        return self.logs_dir or self.path / "logs"

    def ensure_work(self) -> None:
        self.work.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.logs.mkdir(mode=0o700, exist_ok=True)


def _git(repo: Path, *args: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def _looks_like_repo(path: Path) -> bool:
    return (path / "deploy.py").is_file() and (path / "tasks").is_dir()


def find_repo(start: Path) -> Path | None:
    for candidate in [start, *start.parents]:
        if _looks_like_repo(candidate):
            return candidate
    return None


def saved_repo_path() -> Path | None:
    """The repo recorded by `kwisatz install` (last resort; the CLI works without it)."""
    try:
        data = json.loads(CONFIG_JSON.read_text())
    except (OSError, ValueError):
        return None
    if isinstance(data, dict) and isinstance(data.get("repo"), str):
        path = Path(data["repo"]).expanduser()
        return path if _looks_like_repo(path) else None
    return None


def resolve_repo(cli_arg: str | None = None, *, start: Path | None = None) -> Repo:
    """--repo → $KWISATZ_REPO → nearest ancestor checkout → saved config.json → the installed payload."""
    candidates: list[tuple[str, Path]] = []
    if cli_arg:
        candidates.append(("--repo", Path(cli_arg).expanduser().resolve()))
    if os.environ.get("KWISATZ_REPO"):
        candidates.append(("KWISATZ_REPO", Path(os.environ["KWISATZ_REPO"]).expanduser().resolve()))
    found = find_repo((start or Path.cwd()).resolve())
    if found:
        candidates.append(("current directory", found))
    saved = saved_repo_path()
    if saved:
        candidates.append(("kwisatz config.json", saved))

    for source, path in candidates:
        if _looks_like_repo(path):
            return Repo(
                path=path,
                git_sha=_git(path, "rev-parse", "--short", "HEAD"),
                branch=_git(path, "branch", "--show-current"),
            )
        if cli_arg or os.environ.get("KWISATZ_REPO"):
            raise CliError(
                Exit.CONFIG,
                f"{source}: {path} is not a kwisatz checkout (needs deploy.py and tasks/)",
                hint="point --repo at the checkout root, or run kwisatz install --repo <path>",
            )
    payload = payload_dir()
    if _looks_like_repo(payload):
        # installed mode: the payload is the wheel's, user files and state live outside it. The
        # payload path is never persisted anywhere — the uvx cache dir is ephemeral.
        state = state_home()
        return Repo(path=payload, work=state, mode="installed", config_dir=config_home(), logs_dir=state / "logs")
    raise CliError(
        Exit.PREREQUISITE,
        "no kwisatz checkout found from " + str((start or Path.cwd()).resolve()),
        hint="git clone the repo, or kwisatz install --repo <path>",
    )


def resolve_config(repo: Repo, cli_arg: str | None = None) -> Path:
    """-c/--config → $KWISATZ_CONFIG → <config dir>/machine-config.yml (the checkout root, or ~/.config/kwisatz)."""
    if cli_arg:
        return Path(cli_arg).expanduser().resolve()
    if os.environ.get("KWISATZ_CONFIG"):
        return Path(os.environ["KWISATZ_CONFIG"]).expanduser().resolve()
    return repo.config_dir / "machine-config.yml"


def pyinfra_command(repo: Repo) -> list[str]:
    """How to start a pyinfra deploy against this checkout.

    Order matters for determinism, not just convenience:

    1. the *current* interpreter, when `pyinfra` is importable from it — the CLI and the
       deploy then provably run on the same interpreter and the same pyinfra, which is
       what `apply` means; `./kwisatz` and a `uv sync`-ed checkout both land here.
    2. `<repo>/.venv/bin/pyinfra`, when the checkout has a venv the CLI is not running in.
    3. `uv run --project <repo>`, which resolves and syncs the checkout's own pins.
    4. neither available → exit 4 with the command that fixes it, because `apply` runs
       its targets *through* a deploy and cannot substitute a bare script run.
    """
    if importlib.util.find_spec("pyinfra") is not None:
        return [sys.executable, "-m", "pyinfra"]
    venv = repo.path / ".venv" / "bin" / "pyinfra"
    if venv.is_file() and os.access(venv, os.X_OK):
        return [str(venv)]
    if shutil.which("uv"):
        return ["uv", "run", "--project", str(repo.path), "pyinfra"]
    raise CliError(
        Exit.PREREQUISITE,
        f"no pyinfra in this interpreter, in {repo.path / '.venv'}, or in uv — apply runs its targets through a deploy",
        hint="uv sync --project " + str(repo.path) + "   ·   curl -LsSf https://astral.sh/uv/install.sh | sh",
    )


def deploy_argv(
    repo: Repo, config_path: Path, names: Sequence[str] | None = None, *, verbosity: int = 0
) -> list[str]:
    """The command line of one deploy of `names` (all enabled entries when None).

    `-y -vvv` is what every deploy needs, and `--data config=` is passed every
    time so a config outside the checkout is honoured; `--data select=` is what narrows
    the deploy to exactly the named targets. Keep it one place — the VM suite and every
    agent read this command out of the logs.

    `verbosity` is the operator's `-v` count, added as that many more `-v`s. pyinfra reads
    `-v` as a count too, so the two flags add up instead of fighting; the base `-vvv` is
    what every deploy already needs, so a `-v` lands on top of it.
    """
    argv = [
        *pyinfra_command(repo),
        "@local",
        str(repo.path / "deploy.py"),
        "-y",
        "-vvv",
        *["-v" for _ in range(max(0, verbosity))],
    ]
    argv += ["--data", f"config={config_path}"]
    if names is not None:
        argv += ["--data", f"select={','.join(names)}"]
    return argv


# ── the single-writer lock (R-SAFE-001) ──────────────────────────────────────────


class Lock:
    """`<repo>/.kwisatz/lock` holding PID + start time; stale once the owner is gone."""

    def __init__(self, repo: Repo, timeout: float = 0.0, *, machine: bool = False) -> None:
        # `machine` is the one lock per user shared by every checkout and the installed mode, so
        # a checkout run and a uvx run cannot deploy at once; it names no repo, so none is "other"
        self.path = (state_home() if machine else repo.work) / "lock"
        self.timeout = timeout
        self.held = False
        #: the checkout this lock belongs to, so a stray lock in a reused directory is stale
        self.owner_path = "" if machine else str(repo.path)

    def _owner(self) -> dict | None:
        """The recorded owner; None when the file exists but says nothing (see try_acquire)."""
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def _stale(self, owner: dict) -> bool:
        if owner.get("repo") and str(owner["repo"]) != self.owner_path:
            # a lock written by a run of a *different* checkout — same filename, different
            # machine-state, and the usual reason a reused tmp directory reports LOCKED
            return True
        pid = owner.get("pid")
        if not isinstance(pid, int):
            return True
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:  # alive, just not ours
            return False
        return False

    def try_acquire(self) -> bool:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        owner = self._owner()
        if owner and not self._stale(owner):
            return False
        if owner:  # an aborted run: reclaim the lock
            self.path.unlink(missing_ok=True)
        elif self.path.exists():
            # The file names nobody: a crashed run's truncated write, `flock`'s own empty file,
            # or a stray touch. Reclaim it only after a grace period — a live run's file exists
            # empty for a moment between O_EXCL and the write, and deleting that would let two
            # writers in, which is the one thing this class exists to prevent.
            if time.time() - self.path.stat().st_mtime < 1.0:
                return False
            self.path.unlink(missing_ok=True)
        try:
            fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            return False  # we were raced by a run that is alive
        with os.fdopen(fd, "w") as handle:
            json.dump({"pid": os.getpid(), "repo": self.owner_path, "started_at": _utcnow()}, handle)
        self.held = True
        return True

    def release(self) -> None:
        if self.held:
            self.path.unlink(missing_ok=True)
            self.held = False

    def acquire(self) -> None:
        deadline = time.monotonic() + self.timeout
        while True:
            if self.try_acquire():
                return
            if time.monotonic() >= deadline:
                owner = self._owner() or {}
                raise CliError(
                    Exit.LOCKED,
                    f"another kwisatz run holds {self.path}"
                    + (
                        f" (pid {owner.get('pid')} since {owner.get('started_at')})"
                        if owner
                        else " (the file exists but names no owner — remove it only if you know no run is live)"
                    ),
                    hint="wait for it, or pass --lock-timeout <seconds> to queue",
                )
            time.sleep(0.2)


@contextmanager
def held(repo: Repo, timeout: float = 0.0):
    """Hold the repo lock (and the machine-wide one, when it is another file) for the duration;
    never taken for read-only commands."""
    locks = [Lock(repo, timeout, machine=True), Lock(repo, timeout)]
    if locks[0].path == locks[1].path:  # installed mode: the repo lock *is* the machine lock
        locks = locks[1:]
    taken: list[Lock] = []
    try:
        for lock in locks:
            lock.acquire()
            taken.append(lock)
        yield taken[-1]
    finally:
        for lock in reversed(taken):
            lock.release()


def _utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def repo_dict(repo: Repo) -> dict:
    return {"path": str(repo.path), "git_sha": repo.git_sha, "branch": repo.branch}
