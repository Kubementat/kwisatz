"""Host checks and the ordering advisory (§6.5, R-OPS-003).

Read-only by construction: everything here inspects, nothing mutates (R-SAFE-003).
"""

from __future__ import annotations

import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml

DATA = Path(__file__).resolve().parent / "data"

#: a doctor run that finds a missing prerequisite exits PREREQUISITE (4)
REQUIRED = ("os", "sudo", "python", "uv")


@dataclass
class Check:
    name: str
    ok: bool
    detail: str = ""
    hint: str = ""
    required: bool = True

    def as_dict(self) -> dict:
        out = {"name": self.name, "ok": self.ok, "required": self.required}
        if self.detail:
            out["detail"] = self.detail
        if self.hint:
            out["hint"] = self.hint
        return out


def load_prerequisites(path: Path | None = None) -> dict:
    """The §6.5 table; a missing/broken file degrades to no advice, never an error."""
    try:
        table = yaml.safe_load((path or DATA / "prerequisites.yml").read_text())
    except (OSError, yaml.YAMLError):
        return {"requires": {}, "host": {}}
    if not isinstance(table, dict):
        return {"requires": {}, "host": {}}
    return {"requires": table.get("requires") or {}, "host": table.get("host") or {}}


def facts_of(table: dict, target: str) -> dict:
    return (table.get("host") or {}).get(target) or {}


def has_gpu() -> bool:
    if Path("/proc/driver/nvidia/version").is_file():
        return True
    return shutil.which("nvidia-smi") is not None


def has_docker() -> bool:
    if shutil.which("docker") is None:
        return False
    try:
        done = subprocess.run(["docker", "info"], capture_output=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return done.returncode == 0


def has_sudo() -> bool:
    try:
        return subprocess.run(["sudo", "-n", "true"], capture_output=True, timeout=10, check=False).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def os_check() -> Check:
    try:
        info = dict(
            line.split("=", 1)
            for line in Path("/etc/os-release").read_text().splitlines()
            if "=" in line
        )
    except OSError:
        return Check("os", False, "no /etc/os-release", "kwisatz targets Ubuntu 22.04/24.04", True)
    name = info.get("ID", "").strip('"')
    version = info.get("VERSION_ID", "").strip('"')
    ubuntu = name == "ubuntu" and version.startswith(("22.04", "24.04"))
    return Check(
        "os",
        ubuntu,
        f"{info.get('PRETTY_NAME', name)} · {platform.machine()}",
        "target is Ubuntu 22.04/24.04; other distros are best effort" if not ubuntu else "",
        True,
    )


def host_fact(name: str) -> tuple[bool, str]:
    if name == "gpu":
        return has_gpu(), "nvidia driver / nvidia-smi"
    if name == "docker":
        return has_docker(), "docker daemon reachable"
    if name == "sudo":
        return has_sudo(), "passwordless sudo"
    if name == "disk":
        free = shutil.disk_usage("/").free / 1e9
        return free > 20, f"{free:.0f} GB free on /"
    return True, f"unknown fact {name!r}"


def fact_advisories(targets, table: dict) -> list[str]:
    """Host facts the §6.5 table says a target needs — warnings, never aborts."""
    messages: list[str] = []
    for target in targets:
        for fact, want in facts_of(table, target.name).items():
            if not want:
                continue
            ok, detail = host_fact(fact)
            if not ok:
                messages.append(
                    f"{target.name}: {detail} is expected by this target, and is missing here "
                    f"(kwisatz doctor --json lists the checks)"
                )
    return messages


def checks(config) -> list[Check]:
    """The M1 doctor set: OS, sudo, uv, python, docker, GPU, free disk."""
    found = [
        os_check(),
        Check("sudo", has_sudo(), "sudo -n true", "grant sudo, or run with a sudo-capable user", True),
        Check("python", _python_ok(), platform.python_version(), "kwisatz needs Python >= 3.10", True),
        Check("uv", shutil.which("uv") is not None, str(shutil.which("uv") or "not found"),
              "curl -LsSf https://astral.sh/uv/install.sh | sh", True),
        Check("docker", has_docker(), "docker info", "kwisatz apply setup-docker", False),
        Check("gpu", has_gpu(), "nvidia-smi", "only needed by GPU targets", False),
    ]
    free = shutil.disk_usage("/").free / 1e9
    found.append(Check("disk", free > 20, f"{free:.0f} GB free on /", "more than 20 GB for /srv and images", False))
    return found


def _python_ok() -> bool:
    return sys.version_info >= (3, 10)
