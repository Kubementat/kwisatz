"""Fixtures: a throwaway kwisatz checkout whose scripts only *record* what they got.

The point is that the CLI's contract is asserted by what the script observed — argv,
environment, stdin — not by what the CLI printed about it (R-TEST-003). Every stub
writes `<repo>/records/<name>.txt`, so the same fixture drives both the CLI path and
the pyinfra path.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]

RECORD_KEYS = ("INTERACTIVE", "KEY", "SECRET", "PLAIN", "EXTRA", "VIRTUAL_ENV")

STUB_SH = """#!/usr/bin/env bash
# records its argv / env / stdin instead of installing anything
rec="$(cd "$(dirname "$0")/.." && pwd)/records/{name}.txt"
mkdir -p "$(dirname "$rec")"
{{
  printf 'argv:'
  for a in "$@"; do printf ' %s' "$a"; done
  echo
  echo "stdin=$(readlink /proc/self/fd/0)"
  env | grep -E '^({keys})=' | sort
}} > "$rec"
exit {code}
"""

STUB_PY = """#!/usr/bin/env python3
import os, sys
rec = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "records", "{name}.txt")
os.makedirs(os.path.dirname(rec), exist_ok=True)
lines = ["argv: " + " ".join(sys.argv[1:]), "stdin=" + os.readlink("/proc/self/fd/0")]
lines += [f"{{k}}={{os.environ[k]}}" for k in {keys!r} if k in os.environ]
with open(rec, "w") as handle:
    handle.write("\\n".join(lines) + "\\n")
sys.exit({code})
"""


class RepoFixture:
    def __init__(self, path: Path) -> None:
        self.path = path

    @property
    def records(self) -> Path:
        return self.path / "records"

    def read(self, name: str) -> dict:
        """The recorded run as a dict: {argv, stdin, <env keys>}."""
        text = (self.records / f"{name}.txt").read_text()
        out: dict = {}
        for line in text.splitlines():
            if line.startswith("argv:"):
                out["argv"] = line[len("argv:"):].split()
            elif "=" in line:
                key, _, value = line.partition("=")
                out[key] = value
        return out

    def write_config(self, text: str) -> Path:
        path = self.path / "machine-config.yml"
        path.write_text(text)
        return path


@pytest.fixture
def repo(tmp_path, monkeypatch) -> RepoFixture:
    """A fake checkout: deploy.py, tasks/, example config, and a git-free tree."""
    root = tmp_path / "repo"
    (root / "tasks").mkdir(parents=True)
    (root / "machine-config.yml.example").write_text(
        "version: 1\nscripts:\n  stub-a:\n    enabled: true\n    description: A\n"
    )
    # deploy.py lives in the checkout, exactly as in the real repo
    (root / "deploy.py").write_text((REPO_ROOT / "deploy.py").read_text())
    monkeypatch.setenv("KWISATZ_REPO", str(root))
    fixture = RepoFixture(root)
    return fixture


def stub(repo: Path, name: str, *, kind: str = "sh", code: int = 0) -> Path:
    """Write a recording task script into tasks/."""
    body = STUB_SH.format(name=name, code=code, keys="|".join(RECORD_KEYS)) if kind == "sh" else \
        STUB_PY.format(name=name, code=code, keys=list(RECORD_KEYS))
    path = repo / "tasks" / f"{name}.{kind}"
    path.write_text(body)
    path.chmod(0o755)
    return path


def run_cli(*args: str, repo: Path | None = None, env: dict | None = None, timeout: int = 60) -> subprocess.CompletedProcess:
    """The CLI, as an operator runs it: real process, real exit code."""
    environ = {
        "PATH": f"/usr/bin:/bin:/usr/sbin:/sbin:{Path.home() / '.local' / 'bin'}",
        "HOME": str(repo or Path.cwd()),
        "PYTHONPATH": str(REPO_ROOT / "src"),
        "PYTHONUTF8": "1",
        "NO_COLOR": "1",
    }
    environ.update(env or {})
    return subprocess.run(
        [sys.executable, "-m", "kwisatz", *args],
        capture_output=True,
        text=True,
        env=environ,
        timeout=timeout,
        cwd=str(repo),
        check=False,
    )


def run_pyinfra(repo: Path, config: Path, *flags: str) -> subprocess.CompletedProcess:
    """The pyinfra path: `python -m pyinfra @local deploy.py`, same interpreter as the CLI."""
    return subprocess.run(
        [sys.executable, "-m", "pyinfra", "@local", str(repo / "deploy.py"), *flags,
         "--data", f"config={config}"],
        capture_output=True,
        text=True,
        cwd=str(repo),
        timeout=180,
        check=False,
    )


def json_doc(result: subprocess.CompletedProcess) -> dict:
    """`--json` must be exactly one document on stdout (R-JSON-001)."""
    assert result.stdout.count("}") >= 1, result.stdout
    return json.loads(result.stdout)
