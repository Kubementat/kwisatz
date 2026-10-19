"""kwisatz orchestrator: run every enabled task script of machine-config.yml, in config order.

Usage: uv run pyinfra @local deploy.py [--dry | -y -vvv] [--data config=<file>]
"""

import os
import shlex
import sys
from pathlib import Path

import yaml
from pyinfra import host
from pyinfra.api.exceptions import DeployError
from pyinfra.operations import server

ROOT = Path(__file__).resolve().parent

# `uv run` activates the project venv; task scripts must see the system python3/pip
# (the @local connector's subprocesses inherit this environment)
os.environ.pop("VIRTUAL_ENV", None)
os.environ["PATH"] = os.pathsep.join(
    p for p in os.environ["PATH"].split(os.pathsep) if p != f"{sys.prefix}/bin"
)

config = Path(host.data.get("config") or ROOT / "machine-config.yml")
try:
    raw = config.read_text()
except OSError as e:
    # missing file: point at the example / --data override instead of a generic error
    hint = ""
    if config == ROOT / "machine-config.yml" and (ROOT / "machine-config.yml.example").is_file():
        hint = " (copy machine-config.yml.example to machine-config.yml, or pass --data config=<file>)"
    msg = " ".join(f"{type(e).__name__}: {e}".split())
    raise DeployError(f"{config}: cannot read config{hint} ({msg})")
try:
    # BaseLoader keeps every scalar a string, exactly as written (true stays "true")
    doc = yaml.load(raw, Loader=yaml.BaseLoader)
    scripts = doc["scripts"].items()
except (yaml.YAMLError, TypeError, KeyError, AttributeError) as e:
    # unparsable / wrong shape: one line instead of a traceback
    msg = " ".join(f"{type(e).__name__}: {e}".split())
    raise DeployError(f"{config}: cannot read a '.scripts' mapping ({msg})")

for name, s in scripts:
    if (s or {}).get("enabled") != "true":
        continue
    cmd = shlex.join(["bash", f"{ROOT}/tasks/{name}.sh", *(s.get("args") or [])])
    server.shell(
        name=name,
        commands=[cmd + " </dev/null"],
        # config env after INTERACTIVE so a per-script entry wins
        _env={"INTERACTIVE": "false", **(s.get("env") or {})},
    )
