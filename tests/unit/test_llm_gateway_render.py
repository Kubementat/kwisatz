"""Renderer tests for tasks/render-llm-gateway-config.py (U1-U15).

The renderer is imported directly: no Docker, no network, no installed stack.
YAML documents are compared structurally, except the golden-file test.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
RENDERER_PATH = REPO_ROOT / "tasks" / "render-llm-gateway-config.py"
EXAMPLE = REPO_ROOT / "gateway.yml.example"
FIXTURES = Path(__file__).parent / "fixtures" / "llm-gateway"

DEFAULT_ENV = """\
LITELLM_MASTER_KEY=sk-1111111111111111111111111111111111111111111111111111111111111111
LLAMA_SWAP_KEY_DGX=sk-dgx-fixture
LLAMA_SWAP_KEY_EVOBOX=sk-evobox-fixture
LLAMA_SWAP_KEY_LAPTOP=sk-laptop-fixture
"""


def _load_renderer():
    spec = importlib.util.spec_from_file_location(
        "render_llm_gateway_config", RENDERER_PATH
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RENDERER = _load_renderer()


def base_config() -> dict:
    return yaml.safe_load(EXAMPLE.read_text(encoding="utf-8"))


def render(tmp_path: Path, config, *, env: str | None = None, extra=()):
    """Write the inputs, run main(), and return (rc, out_dir)."""
    tmp_path.mkdir(parents=True, exist_ok=True)
    config_path = tmp_path / "gateway.yml"
    if isinstance(config, str):
        config_path.write_text(config, encoding="utf-8")
    else:
        config_path.write_text(
            yaml.safe_dump(config, sort_keys=False), encoding="utf-8"
        )
    env_path = tmp_path / ".env"
    env_path.write_text(env if env is not None else DEFAULT_ENV, encoding="utf-8")
    out_dir = tmp_path / "out"
    out_dir.mkdir(exist_ok=True)
    rc = RENDERER.main(
        [
            "--config",
            str(config_path),
            "--env-file",
            str(env_path),
            "--out-dir",
            str(out_dir),
            *extra,
        ]
    )
    return rc, out_dir


def rendered_config(out_dir: Path) -> dict:
    return yaml.safe_load((out_dir / "config.yaml").read_text(encoding="utf-8"))


def params_for(config_doc: dict, deployment_id: str) -> dict:
    for entry in config_doc["model_list"]:
        if entry["model_info"]["id"] == deployment_id:
            return entry["litellm_params"]
    raise AssertionError(f"deployment {deployment_id!r} not rendered")


# ── U1: golden files ─────────────────────────────────────────────────────────
def test_u1_example_renders_to_golden_files(tmp_path, capsys):
    rc, out_dir = render(tmp_path, EXAMPLE.read_text(encoding="utf-8"))

    assert rc == 0
    assert (out_dir / "config.yaml").read_text(encoding="utf-8") == (
        FIXTURES / "config.yaml"
    ).read_text(encoding="utf-8")
    assert (out_dir / "compose.ports.yml").read_text(encoding="utf-8") == (
        FIXTURES / "compose.ports.yml"
    ).read_text(encoding="utf-8")
    assert rendered_config(out_dir) == yaml.safe_load(
        (FIXTURES / "config.yaml").read_text(encoding="utf-8")
    )
    assert (out_dir / "firewall.sh").stat().st_mode & 0o777 == 0o755


# ── U2: wildcards ────────────────────────────────────────────────────────────
def test_u2_wildcard_addresses_and_default_route_are_rejected(tmp_path, capsys):
    config = base_config()
    config["listen"]["addresses"] = ["0.0.0.0", "::"]
    config["listen"]["allow_from"] = ["0.0.0.0/0"]

    rc, out_dir = render(tmp_path, config)
    stderr = capsys.readouterr().err

    assert rc == 1
    assert "0.0.0.0" in stderr and "wildcard" in stderr
    assert "'::'" in stderr
    assert "default route" in stderr
    assert not (out_dir / "config.yaml").exists()


# ── U3: unknown backend ──────────────────────────────────────────────────────
def test_u3_unknown_backend_is_named(tmp_path, capsys):
    config = base_config()
    config["models"][0]["deployments"][0]["backend"] = "ghost"

    rc, _ = render(tmp_path, config)

    assert rc == 1
    assert "unknown backend 'ghost'" in capsys.readouterr().err


# ── U4: duplicate names / aliases / ids ──────────────────────────────────────
def test_u4_duplicate_public_name_alias_and_deployment_id(tmp_path, capsys):
    config = base_config()
    config["models"] = [
        {
            "name": "duplicate-model",
            "aliases": ["shared-alias"],
            "deployments": [
                {"backend": "dgx", "model": "m", "id": "same-id", "resident": True}
            ],
        },
        {
            "name": "duplicate-model",
            "aliases": ["shared-alias"],
            "deployments": [
                {"backend": "evobox", "model": "m", "id": "same-id", "resident": True}
            ],
        },
    ]

    rc, _ = render(tmp_path, config)
    stderr = capsys.readouterr().err

    assert rc == 1
    assert "duplicate public model name 'duplicate-model'" in stderr
    assert "duplicate alias 'shared-alias'" in stderr
    assert "duplicate deployment id 'same-id'" in stderr


# ── U5: numeric lower bounds ─────────────────────────────────────────────────
def test_u5_zero_limits_are_rejected_per_field(tmp_path, capsys):
    config = base_config()
    deployment = config["models"][0]["deployments"][0]
    deployment["max_parallel"] = 0
    deployment["weight"] = 0
    deployment["order"] = 0

    rc, _ = render(tmp_path, config)
    stderr = capsys.readouterr().err

    assert rc == 1
    assert ".max_parallel: must be an integer >= 1" in stderr
    assert ".weight: must be an integer >= 1" in stderr
    assert ".order: must be an integer >= 1" in stderr


# ── U6: missing env keys ─────────────────────────────────────────────────────
def test_u6_missing_env_keys_are_all_listed(tmp_path, capsys):
    config = base_config()
    env = (
        f"LITELLM_MASTER_KEY=sk-{'a' * 64}\n"
        "LLAMA_SWAP_KEY_DGX=\n"
    )

    rc, out_dir = render(tmp_path, config, env=env)
    stderr = capsys.readouterr().err

    assert rc == 1
    assert "LLAMA_SWAP_KEY_DGX" in stderr
    assert "LLAMA_SWAP_KEY_EVOBOX" in stderr
    assert "LLAMA_SWAP_KEY_LAPTOP" in stderr
    assert "sk-1111" not in stderr
    assert not (out_dir / "config.yaml").exists()


# ── U7: shared group needs resident models ───────────────────────────────────
def test_u7_shared_group_rejects_non_resident(tmp_path, capsys):
    config = base_config()
    config["models"][0]["deployments"][1]["resident"] = False

    rc, _ = render(tmp_path, config)

    assert rc == 1
    assert "shared group" in capsys.readouterr().err


# ── U8: best_effort / order semantics ───────────────────────────────────────
def test_u8_best_effort_with_explicit_order_one_is_an_error(tmp_path, capsys):
    config = base_config()
    config["backends"]["laptop"]["best_effort"] = True
    config["models"][0]["deployments"][2]["order"] = 1

    rc, _ = render(tmp_path, config)

    assert rc == 1
    assert "best_effort" in capsys.readouterr().err


def test_u8_order_above_one_with_weight_is_a_warning(tmp_path, capsys):
    config = base_config()
    config["models"][0]["deployments"][2]["weight"] = 2  # order is already 2

    rc, out_dir = render(tmp_path, config)
    stderr = capsys.readouterr().err

    assert rc == 0
    assert "weight is ignored above order 1" in stderr
    assert rendered_config(out_dir)["model_list"]


# ── U9: determinism ──────────────────────────────────────────────────────────
def test_u9_two_renders_are_byte_identical(tmp_path):
    first_dir = tmp_path / "first"
    second_dir = tmp_path / "second"
    first_dir.mkdir()
    second_dir.mkdir()

    assert render(tmp_path / "a", base_config())[0] == 0
    assert render(tmp_path / "b", base_config())[0] == 0

    for name in ("config.yaml", "compose.ports.yml", "firewall.sh"):
        first = (tmp_path / "a" / "out" / name).read_bytes()
        second = (tmp_path / "b" / "out" / name).read_bytes()
        assert first == second, name


# ── U10: secrets never reach the rendered config ────────────────────────────
def test_u10_rendered_config_holds_env_references_only(tmp_path):
    config = base_config()
    env = (
        f"LITELLM_MASTER_KEY=sk-{'f' * 64}\n"
        "LLAMA_SWAP_KEY_DGX=sk-secret-dgx-value\n"
        "LLAMA_SWAP_KEY_EVOBOX=sk-secret-evobox-value\n"
        "LLAMA_SWAP_KEY_LAPTOP=sk-secret-laptop-value\n"
    )

    rc, out_dir = render(tmp_path, config, env=env)
    text = (out_dir / "config.yaml").read_text(encoding="utf-8")

    assert rc == 0
    assert "os.environ/LLAMA_SWAP_KEY_DGX" in text
    assert "os.environ/LITELLM_MASTER_KEY" in text
    assert "sk-secret" not in text
    assert "f" * 64 not in text


# ── U11: strict loading and schema ──────────────────────────────────────────
def test_u11_duplicate_yaml_key_is_rejected(tmp_path, capsys):
    text = EXAMPLE.read_text(encoding="utf-8")
    text = text.replace("version: 1", "version: 1\nversion: 1", 1)

    rc, _ = render(tmp_path, text)

    assert rc == 1
    assert "duplicate key 'version'" in capsys.readouterr().err


def test_u11_unknown_key_is_rejected(tmp_path, capsys):
    config = base_config()
    config["bogus"] = True

    rc, _ = render(tmp_path, config)

    assert rc == 1
    assert "bogus: unknown key" in capsys.readouterr().err


def test_u11_version_two_is_rejected(tmp_path, capsys):
    config = base_config()
    config["version"] = 2

    rc, _ = render(tmp_path, config)

    assert rc == 1
    assert "version: must be 1" in capsys.readouterr().err


# ── U12: one binding per address, in document order ────────────────────────
def test_u12_three_addresses_render_in_order_without_wildcards(tmp_path):
    config = base_config()
    config["listen"]["addresses"] = ["192.168.178.57", "10.0.0.5", "127.0.0.1"]

    rc, out_dir = render(tmp_path, config)
    text = (out_dir / "compose.ports.yml").read_text(encoding="utf-8")

    assert rc == 0
    assert text.count(":4000:4000") == 3
    assert text.index("192.168.178.57") < text.index("10.0.0.5") < text.index("127.0.0.1")
    assert '"0.0.0.0:' not in text
    assert '"::' not in text


# ── U13: backend in a shared and a single model warns ──────────────────────
def test_u13_backend_in_shared_and_single_model_warns(tmp_path, capsys):
    rc, _ = render(tmp_path, base_config())
    stderr = capsys.readouterr().err

    assert rc == 0
    assert "backends.evobox" in stderr
    assert "single-deployment model" in stderr


# ── U14: api_key_env is optional ────────────────────────────────────────────
def test_u14_backend_without_api_key_env_sends_no_api_key(tmp_path):
    config = base_config()
    del config["backends"]["laptop"]["api_key_env"]

    rc, out_dir = render(tmp_path, config)
    params = params_for(rendered_config(out_dir), "laptop-qwen3.8-flash-next")

    assert rc == 0
    assert "api_key" not in params


# ── U15: --print-port is the single port source ────────────────────────────
def test_u15_print_port_prints_only_the_effective_port(tmp_path, capsys):
    config_path = tmp_path / "gateway.yml"
    config_path.write_text(EXAMPLE.read_text(encoding="utf-8"), encoding="utf-8")
    config = base_config()
    config["listen"]["port"] = 4123
    config_path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")

    rc = RENDERER.main(["--config", str(config_path), "--print-port"])
    captured = capsys.readouterr()

    assert rc == 0
    assert captured.out == "4123\n"


def test_explicit_port_mismatch_is_rejected(tmp_path, capsys):
    rc, _ = render(tmp_path, base_config(), extra=("--port", "4999"))

    assert rc == 1
    assert "does not match listen.port" in capsys.readouterr().err


def test_excluded_address_is_not_published(tmp_path):
    rc, out_dir = render(
        tmp_path, base_config(), extra=("--exclude-address", "192.168.122.1")
    )
    text = (out_dir / "compose.ports.yml").read_text(encoding="utf-8")

    assert rc == 0
    assert "192.168.122.1" not in text
    assert text.count(":4000:4000") == 2


def test_renderer_never_writes_on_validation_failure(tmp_path):
    config = base_config()
    config["models"][0]["deployments"][0]["max_parallel"] = 0
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    (out_dir / "config.yaml").write_text("previous: content\n", encoding="utf-8")

    rc, _ = render(tmp_path, config)

    assert rc == 1
    assert (out_dir / "config.yaml").read_text(encoding="utf-8") == "previous: content\n"


def test_the_plan_parser_keeps_empty_columns():
    """A backend without `api_key_env` must not shift `false` into the key name.

    `--print-plan` separates fields with tabs, and tab is IFS *whitespace*: a
    naive `IFS=$'\t' read` collapses the run of two tabs that marks an absent
    key, so the caller asks for a secret literally named "false".
    """
    script = (REPO_ROOT / "tasks" / "setup-llm-gateway.sh").read_text(encoding="utf-8")
    start = script.index("_parse_plan() {")
    parse_fn = script[start : script.index("\n}\n", start) + 2]

    plan = subprocess.run(
        [
            sys.executable,
            str(RENDERER_PATH),
            "--config",
            str(REPO_ROOT / "tests" / "fixtures" / "llm-gateway" / "gateway.test.yml"),
            "--print-plan",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    out = subprocess.run(
        [
            "bash",
            "-c",
            "set -euo pipefail\n"
            "declare -a BACKEND_NAMES BACKEND_URLS BACKEND_KEYS BACKEND_EFFORT\n"
            f"{parse_fn}\n_parse_plan \"$1\"\n"
            'printf "names=%s keys=%s effort=%s\\n" '
            '"${BACKEND_NAMES[*]-}" "${BACKEND_KEYS[*]-}" "${BACKEND_EFFORT[*]-}"\n',
            "_",
            plan,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()

    assert "names=testbox" in out
    assert "keys=false" not in out
    assert "effort=false" in out


def test_the_compose_wildcard_guard_ignores_comments(tmp_path):
    r"""The guard must read bindings, not the header that promises no wildcards.

    `compose.ports.yml` carries the comment “no 0.0.0.0 and no ::, ever”, and a
    plain `grep -E '0\.0\.0\.0'` over the file matches that line — so a correct
    render looked like a wildcard and the task refused to start. This is what the
    first VM run of the feature caught. The test drives the script's own guard
    line against a known-good render and against a wildcarded one.
    """
    script = (REPO_ROOT / "tasks" / "setup-llm-gateway.sh").read_text(encoding="utf-8")
    found = re.search(r'^\s*offenders="\$\((.+)\)"$', script, re.M)
    assert found, "the compose wildcard guard line is no longer where the test reads it"
    guard = found.group(1)

    good = (FIXTURES / "compose.ports.yml").read_text(encoding="utf-8")
    assert "no 0.0.0.0 and no" in good
    assert _compose_guard_offenders(guard, tmp_path / "good.yml", good) == ""

    wildcard = good.replace('      - "1', '      - "0.0.0.0:4000:0\n      - "1', 1)
    assert "0.0.0.0" in _compose_guard_offenders(guard, tmp_path / "wild.yml", wildcard)


def _compose_guard_offenders(guard: str, path: Path, text: str) -> str:
    path.write_text(text, encoding="utf-8")
    return subprocess.run(
        [
            "bash",
            "-c",
            f'set -uo pipefail\nPORTS_FILE="$1"\noffenders=$({guard})\nprintf %s "$offenders"',
            "_",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__, "-q"]))
