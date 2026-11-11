"""Phase 3: tasks read user-owned files from $KWISATZ_CONFIG_DIR, else from the repo root."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from sync_models.catalog import resolve_catalog_path  # noqa: E402


def kw_config_file(name: str, config_dir: Path | None) -> str:
    env = {"PATH": "/usr/bin:/bin"}
    if config_dir is not None:
        env["KWISATZ_CONFIG_DIR"] = str(config_dir)
    out = subprocess.run(
        ["bash", "-c", f'source "{REPO}/lib/helpers.sh"; kw_config_file {name}'],
        capture_output=True, text=True, env=env, check=True,
    )
    return out.stdout.strip()


def test_kw_config_file_defaults_to_the_repo_root():
    assert kw_config_file("models.yml", None) == f"{REPO}/models.yml"


def test_kw_config_file_follows_the_config_dir(tmp_path):
    assert kw_config_file("gateway.yml", tmp_path) == f"{tmp_path}/gateway.yml"


def test_catalog_resolution_prefers_the_config_dir(tmp_path, monkeypatch):
    payload, cfg = tmp_path / "payload", tmp_path / "cfg"
    payload.mkdir()
    cfg.mkdir()
    (payload / "models.yml.default").write_text("x: 1\n")
    monkeypatch.delenv("KWISATZ_CONFIG_DIR", raising=False)
    assert resolve_catalog_path(payload, None) == payload / "models.yml.default"
    (payload / "models.yml").write_text("x: 2\n")
    assert resolve_catalog_path(payload, None) == payload / "models.yml"
    monkeypatch.setenv("KWISATZ_CONFIG_DIR", str(cfg))
    assert resolve_catalog_path(payload, None) == payload / "models.yml.default"
    (cfg / "models.yml").write_text("x: 3\n")
    assert resolve_catalog_path(payload, None) == cfg / "models.yml"


def test_merge_model_entry_seeds_into_a_missing_config_dir(tmp_path):
    fragment = (REPO / "templates" / "tensorfold-spark-qwen38-flash" / "models-entry.yml").read_text()
    entry = tmp_path / "entry.yml"
    entry.write_text(re.sub(r"\$\{[A-Z_]+\}", "1234", fragment))
    catalog = tmp_path / "new" / "dir" / "models.yml"
    proc = subprocess.run(
        [sys.executable, str(REPO / "tasks" / "merge-model-entry.py"), "--catalog", str(catalog),
         "--default", str(REPO / "models.yml.default"), "--entry", str(entry), "--name", "qwen3.8-flash-next"],
        capture_output=True, text=True, cwd=REPO,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "qwen3.8-flash-next" in catalog.read_text()
