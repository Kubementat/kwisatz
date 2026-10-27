"""kwisatz — the CLI over the orchestrator that already installs this machine.

`kwisatz.orchestrator` holds the single execution contract (config, enabled evaluation,
script resolution, command + env construction); `kwisatz.exec` runs it. Everything else
in here is argument parsing, output, and the questions a human or agent asks about the
result.
"""

from __future__ import annotations

__version__ = "1.1.0"
__all__ = ["__version__"]
