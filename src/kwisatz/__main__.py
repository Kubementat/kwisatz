"""`python -m kwisatz …` — what the ./kwisatz shim runs inside a venv."""

from __future__ import annotations

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
