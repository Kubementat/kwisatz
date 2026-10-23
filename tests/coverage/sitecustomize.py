"""Start `coverage` in every python process this run spawns (R-TEST-001's invisible half).

The CLI's tests are subprocess tests, so without this the CLI's own module reports 0 % and the
number neither proves nor refutes anything. `sitecustomize` is on `PYTHONPATH` only while the
coverage runner sets it (see `tests/coverage.sh`), and `process_startup()` does nothing unless
`COVERAGE_PROCESS_START` names a config file — so a normal `uv run pytest` is untouched.
"""

from __future__ import annotations

import os

if os.environ.get("COVERAGE_PROCESS_START"):
    import coverage

    coverage.process_startup()
