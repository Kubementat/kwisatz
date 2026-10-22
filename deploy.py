"""kwisatz orchestrator (pyinfra adapter): run every enabled task script, in config order.

Usage: uv run pyinfra @local deploy.py [--dry | -y -vvv] [--data config=<file>]
                                       [--data select=<name>[,<name>…]]
(`./run-setup.sh apply|status` wraps exactly this, and `kwisatz apply` runs the same
contract directly — see `kwisatz/orchestrator.py`. `select` runs exactly the named
targets, in the order given, whether or not they are enabled — `kwisatz apply <target>`
passes it, and it is the only way to reach a single script through pyinfra.)

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

config_path = Path(host.data.get("config") or ROOT / "machine-config.yml")
# `--data select=<name>[,<name>…]` is how `kwisatz apply <target>` runs exactly those
# targets through this deploy instead of the whole enabled list; the CLI resolves the
# names, this file only runs them. Without it, the full config in config order.
raw_select = str(host.data.get("select") or "")
select = [name.strip() for name in raw_select.split(",") if name.strip()]
# `--data env='{"KEY":"value"}'` is `kwisatz apply --env KEY=value`: it wins over the
# config's `env:` (R-APP-012) and stays masked in the echo, exactly like a config value.
raw_env = host.data.get("env") or {}
if not isinstance(raw_env, dict) or any(not isinstance(k, str) for k in raw_env):
    raise DeployError(f"{config_path}: --data env must be a mapping of strings, got {raw_env!r}")
overrides = {k: str(v) for k, v in raw_env.items()}

try:
    loaded = orchestrator.load_config(config_path, ROOT)
    tasks = (
        orchestrator.select_tasks(loaded, select, overrides=overrides)
        if select
        else list(orchestrator.iter_enabled(loaded, overrides=overrides))
    )
except orchestrator.ConfigError as e:
    raise DeployError(str(e)) from None

for task in tasks:
    server.shell(
        name=task.name,
        commands=[task.command],
        _env=orchestrator.pyinfra_env(task, HiddenValue),
    )
