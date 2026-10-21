"""The CLI's error type and the exit-code table.

Exit codes are part of the contract (spec §9): agents branch on these, not on message
text, so they are asserted in tests and published by `kwisatz commands --json`.
"""

from __future__ import annotations


class Exit:
    OK = 0
    TASK_FAILED = 1
    USAGE = 2
    CONFIG = 3
    PREREQUISITE = 4
    HEALTH = 5
    INTERACTIVE_REQUIRED = 6
    NEEDS_ATTENTION = 7
    PARTIAL = 8
    LOCKED = 9


EXIT_CODES: dict[int, str] = {
    Exit.OK: "OK — success, including no-op / already-converged",
    Exit.TASK_FAILED: "TASK_FAILED — a task script exited non-zero",
    Exit.USAGE: "USAGE — bad flag/command, ambiguous target, mutually exclusive flags",
    Exit.CONFIG: "CONFIG — config missing/unparsable/malformed, or unknown target",
    Exit.PREREQUISITE: "PREREQUISITE — uv/sudo/docker/OS/TTY requirement not met",
    Exit.HEALTH: "HEALTH — run completed but health verification failed, or timed out",
    Exit.INTERACTIVE_REQUIRED: "INTERACTIVE_REQUIRED — the step needs a human/--interactive",
    Exit.NEEDS_ATTENTION: "NEEDS_ATTENTION — converge impossible; operator action required",
    Exit.PARTIAL: "PARTIAL — --keep-going finished with at least one failure",
    Exit.LOCKED: "LOCKED — another kwisatz run holds the lock",
}


class CliError(Exception):
    """An error that is already fully described: code, one-line message, next command."""

    def __init__(
        self, code: int, message: str, *, hint: str | None = None, target: str | None = None
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.hint = hint
        self.target = target

    def error(self) -> dict:
        entry = {"message": self.message}
        if self.target:
            entry["target"] = self.target
        if self.hint:
            entry["hint"] = self.hint
        entry["exit_code"] = self.code
        return entry


def usage(message: str, *, hint: str | None = None, command: str | None = None) -> CliError:
    return CliError(Exit.USAGE, message, hint=hint, target=command)


def config_error(message: str, *, hint: str | None = None, target: str | None = None) -> CliError:
    return CliError(Exit.CONFIG, message, hint=hint, target=target)
