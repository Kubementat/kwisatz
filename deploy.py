"""kwisatz orchestrator (pyinfra adapter): run every enabled task script, in config order.

Usage: uv run pyinfra @local deploy.py [--dry | -y -vvv] [--data config=<file>]
(`./run-setup.sh apply|status` wraps exactly this, and `kwisatz apply` runs the same
contract directly — see `kwisatz/orchestrator.py`.)

Everything that decides *what* runs and *how* lives in `kwisatz.orchestrator`, which
both entry points read: the config contract (`.scripts.<name>` = `enabled` / `env` /
`args`, `description` informational), the `enabled` spellings, `tasks/<name>.sh` vs
`tasks/<name>.py`, and the environment of a task (`INTERACTIVE=false` first, then the
config `env:`, stdin `/dev/null`, `env:` values masked in echoes). Read that module
before changing anything here — a change made to this file alone breaks parity.

This file is only the pyinfra half:
  * `host.data['config']` for the `--data config=<file>` override,
  * one `server.shell` operation per enabled script, in config order, with the command
    string and `_env` the shared module produced,
  * `ConfigError` → `DeployError`, so the operator sees pyinfra's own error line,
  * the venv `PATH` strip, because `uv run` activates this project's venv and task
    scripts must see the system python3/pip (the @local connector's subprocesses
    inherit this environment).

Environment values that came from a script's `env:` block are wrapped in
`pyinfra.api.HiddenValue`, so at `-vvv` — the only level that streams task output —
the echoed command line reads `export KEY=*MASKED*` while the script receives the real
value (`api/command.py` masks in `__str__`, `connectors/local.py` executes
`get_raw_value()`; same mechanism as `docker.login`).
"""

import os
from pathlib import Path

from pyinfra import host
from pyinfra.api import HiddenValue
from pyinfra.api.exceptions import DeployError
from pyinfra.operations import server

from kwisatz import orchestrator

ROOT = Path(__file__).resolve().parent

# `uv run` activates the project venv; task scripts must see the system python3/pip
orchestrator.strip_venv_from_environ(os.environ)

try:
    config_path = Path(host.data.get("config") or ROOT / "machine-config.yml")
    plan = orchestrator.build_plan(orchestrator.load_config(config_path, ROOT))
except orchestrator.ConfigError as e:
    raise DeployError(str(e)) from None

for item in plan.enabled:
    task = item.task
    assert task is not None  # build_plan() resolved every enabled entry
    server.shell(
        name=task.name,
        commands=[task.command],
        _env=orchestrator.pyinfra_env(task, HiddenValue),
    )
