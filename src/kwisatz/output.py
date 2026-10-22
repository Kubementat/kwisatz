"""Output levels and colour. The prefixes are the contract; grep-ability must survive.

Progress goes to **stderr**, results to **stdout** (R-OUT-002), so `kwisatz apply x |
tee out` keeps the result and loses the noise. Colour only when the stream is a TTY and
`NO_COLOR`/`--no-color` do not forbid it.
"""

from __future__ import annotations

import os
import sys

RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
GREEN = "\033[32m"
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"


class Out:
    def __init__(
        self,
        *,
        quiet: bool = False,
        verbose: bool = False,
        json: bool = False,
        color: bool | None = None,
    ) -> None:
        self.quiet = quiet
        self.verbose = verbose
        self.json = json
        self.color = self._default_color() if color is None else color

    @staticmethod
    def _default_color() -> bool:
        if os.environ.get("NO_COLOR"):
            return False
        return bool(sys.stderr.isatty())

    def paint(self, text: str, *codes: str) -> str:
        if not self.color or not codes:
            return text
        return "".join(codes) + text + RESET

    def _err(self, text: str) -> None:
        print(text, file=sys.stderr, flush=True)

    def result(self, text: str = "") -> None:
        """The stdout channel: what the user (or a pipe) asked for."""
        print(text, file=sys.stdout, flush=True)

    def progress(self, text: str) -> None:
        """stderr chatter: headers, heartbeats, per-step status. Silent when quiet."""
        if not (self.quiet or self.json):
            self._err(text)

    def error(self, message: str) -> None:
        self._err(self.paint(f"--> ERROR: {message}", RED))

    def warning(self, message: str) -> None:
        # The `--> WARNING:` text is orchestrator.orchestrator's; never reformat it here.
        self._err(self.paint(f"--> WARNING: {message}", YELLOW))

    def note(self, message: str) -> None:
        self._err(self.paint(f"--> note: {message}", CYAN))

    def action(self, message: str) -> None:
        self.progress(self.paint(f"→ {message}", BOLD))

    def ok(self, message: str) -> None:
        self.progress(self.paint(f"✓ {message}", GREEN))

    def verdict(self, glyph: str, text: str) -> None:
        """One line of a command whose whole output is its verdicts (`doctor`).

        stdout, not stderr: `kwisatz doctor | grep -i docker` has to answer, and
        `kwisatz -q doctor` still has to report what it found. Only --json mutes it, because
        that mode owns stdout. `ok()` is for apply's step lines, where stdout belongs to the
        task script — a different situation, so a different call.
        """
        if self.json:
            return
        color = {"✓": GREEN, "⚠": YELLOW, "✗": RED}.get(glyph, "")
        line = self.paint(f"{glyph} {text}", color)
        print(line, file=sys.stdout, flush=True)

    def step(self, message: str) -> None:
        self.progress(self.paint(f"  {message}", DIM))
