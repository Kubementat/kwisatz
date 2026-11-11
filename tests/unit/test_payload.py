"""Phase 1: the wheel carries the read-only payload and never the user-owned files."""

from __future__ import annotations

import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.skipif(shutil.which("uv") is None, reason="needs uv to build the wheel")


@pytest.fixture(scope="module")
def wheel_names(tmp_path_factory) -> list[str]:
    out = tmp_path_factory.mktemp("dist")
    subprocess.run(["uv", "build", "--wheel", "-o", str(out)], cwd=REPO, check=True, capture_output=True)
    (wheel,) = out.glob("kwisatz-*.whl")
    with zipfile.ZipFile(wheel) as z:
        return z.namelist()


def test_payload_files_are_present(wheel_names):
    for needed in (
        "kwisatz/payload/deploy.py",
        "kwisatz/payload/versions.yml",
        "kwisatz/payload/lib/helpers.sh",
        "kwisatz/payload/tasks/configure-firewall.sh",
        "kwisatz/payload/templates/agent-sandbox",
        "kwisatz/payload/machine-config.yml.example",
        "kwisatz/payload/models.yml.default",
        "kwisatz/payload/utilities/check-versions.sh",
    ):
        assert any(n == needed or n.startswith(needed + "/") for n in wheel_names), needed


def test_user_owned_files_never_ship(wheel_names):
    banned = ("machine-config.yml", "models.yml", "gateway.yml")
    for name in wheel_names:
        assert Path(name).name not in banned, name
        assert ".kwisatz/" not in name and "/logs/" not in name, name
        assert "__pycache__" not in name, name
