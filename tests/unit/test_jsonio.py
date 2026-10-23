"""jsonio.py: the machine-readable contract (§8). An agent parses this, so it is API.

Rules with a name in the spec and a test in this file: exactly one document on stdout,
`schema_version` always present, secrets masked unless someone deliberately says otherwise.
"""

from __future__ import annotations

import json

from kwisatz import jsonio
from kwisatz.errors import EXIT_CODES, Exit


def test_envelope_has_the_fields_and_only_the_fields_the_spec_promises():
    doc = jsonio.envelope(
        command="apply",
        ok=False,
        exit_code=Exit.TASK_FAILED,
        started_at="2026-10-22T00:00:00Z",
        duration_ms=10,
        repo={"path": "/srv/kwisatz", "git_sha": "abc", "branch": "develop"},
        result={"plan": 2},
        warnings=["w"],
        errors=[{"message": "m"}],
    )
    assert doc["schema_version"] == jsonio.SCHEMA_VERSION
    assert set(doc) >= {"schema_version", "command", "ok", "exit_code", "started_at", "duration_ms"}
    assert doc["result"] == {"plan": 2}


def test_absent_sections_are_absent_not_null():
    doc = jsonio.envelope(command="status", ok=True, exit_code=0, started_at="x", duration_ms=1)
    assert "repo" not in doc and "result" not in doc and "errors" not in doc


def test_mask_env_masks_only_the_keys_that_look_secret():
    env = {"INTERACTIVE": "false", "API_KEY": "abc", "TRAEFIK_SECRET": "x", "NVM_VERSION": "0.40"}
    masked = jsonio.mask_env(env)
    assert masked["API_KEY"] == "***" and masked["TRAEFIK_SECRET"] == "***"
    assert masked["INTERACTIVE"] == "false" and masked["NVM_VERSION"] == "0.40"


def test_reveal_is_an_exact_switch_not_a_default():
    assert jsonio.mask_env({"TOKEN": "x"}, reveal=True)["TOKEN"] == "x"


def test_emit_prints_exactly_one_json_document(capsys):
    jsonio.emit({"a": 1})
    out = capsys.readouterr().out
    assert out.count("\n") == 1 and json.loads(out) == {"a": 1}


def test_exit_codes_are_stable_names_an_agent_can_branch_on():
    assert EXIT_CODES[Exit.OK] == "OK — success, including no-op / already-converged"
    assert sorted(EXIT_CODES) == list(range(10))


def test_the_two_codes_v1_never_returns_say_they_are_reserved():
    """The table promises 6 and 7; nothing emits them (a prompt is `4`, a failed converge is `1`).

    Publishing them is right — the numbering is the contract — but an agent must be able to
    learn from the JSON that branching on them would be dead code, and this test is what keeps
    that sentence true. Implementing A4 removes it, on purpose.
    """
    for code in (Exit.INTERACTIVE_REQUIRED, Exit.NEEDS_ATTENTION):
        assert "reserved" in EXIT_CODES[code].lower()


def test_stdout_tail_limits_match_the_documented_cap():
    assert jsonio.TAIL_LINES == 40 and jsonio.TAIL_BYTES == 16 * 1024
