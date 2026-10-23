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

from . import orchestrator

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


# The Ubuntu releases this repo's own VM suite boots, plus the one it used to run: a release
# we have not tested is a warning, never a stop, because refusing would call our own green
# matrix a failure (found on a `--release resolute` test VM, where `doctor` exited 4 while
# every script installed cleanly).
TESTED_UBUNTU = ("26.04", "24.04", "22.04")


def os_check(path: Path = Path("/etc/os-release")) -> Check:
    try:
        info = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
    except OSError:
        return Check("os", False, "no /etc/os-release", "kwisatz targets Ubuntu", True)
    name = info.get("ID", "").strip('"')
    version = info.get("VERSION_ID", "").strip('"')
    pretty = f"{info.get('PRETTY_NAME', name)} · {platform.machine()}"
    if name != "ubuntu":
        # the task scripts are apt/unit based, so a non-Ubuntu box genuinely cannot run them
        return Check("os", False, pretty, "kwisatz targets Ubuntu; this distro is best effort", True)
    if version.startswith(TESTED_UBUNTU):
        return Check("os", True, pretty, "", True)
    return Check(
        "os", False, pretty, f"Ubuntu {version} is outside the tested set ({', '.join(TESTED_UBUNTU)})", False
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


def requires_sudo(targets, table: dict) -> bool:
    """Whether the §6.5 `host:` map says these targets will call sudo on this machine.

    The map is the only place that declaration exists, so it is the only thing that may stop a
    run for it: a script that never touches `sudo` must not be held hostage by a box whose sudo
    needs a password.
    """
    return any(bool(facts_of(table, target.name).get("sudo")) for target in targets)


def host_checks() -> list[Check]:
    """The doctor's host set: OS, sudo, uv, python, docker, GPU, free disk, free `/srv`."""
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
    found.append(Check("disk", free > 20, f"{free:.0f} GB free on /", "more than 20 GB for images and caches", False))
    found.append(srv_disk_check())
    return found


def srv_disk_check() -> Check:
    """Every stack keeps its data in `/srv/<name>`, so that filesystem matters more than `/`."""
    where = "/srv" if Path("/srv").is_dir() else "/"
    free = shutil.disk_usage(where).free / 1e9
    return Check(
        "srv-disk",
        free > 20,
        f"{free:.0f} GB free on {where}",
        "model weights and container layers land here; free space is the usual cause of a stalled install",
        False,
    )


def port_conflicts(config, services) -> list[Check]:
    """The two ways a `*_PORT` fails, caught before 20 minutes of install work (R-OPS-003).

    1. two enabled targets that both want the port — a guaranteed failure for whichever runs
       second, and invisible in a config review because the values live in different entries;
    2. a port the config wants that something already running has published. The target's own
       stack is excluded, because re-applying it is exactly the converge case.
    """
    wanted: dict[int, list[str]] = {}
    for name, raw in config.scripts:
        try:
            entry = orchestrator.check_shape(name, raw, config)
        except orchestrator.ConfigError:
            continue
        if not orchestrator.is_enabled(name, entry, warn=lambda _m: None):
            continue
        for key, value in (entry.get("env") or {}).items():
            if key.endswith("_PORT") and str(value).isdigit():
                wanted.setdefault(int(value), []).append(name)

    published: dict[int, str] = {}
    for service in services:
        for port in service.as_dict()["ports"]:
            published[port] = service.name

    found: list[Check] = []
    for port, names in sorted(wanted.items()):
        if len(names) > 1:
            found.append(
                Check(
                    f"port:{port}",
                    False,
                    f"{port}/tcp wanted by {', '.join(names)}",
                    "give one of them another `*_PORT`, or disable the other",
                    False,
                )
            )
        holder = published.get(port)
        if holder and holder not in names:
            found.append(
                Check(
                    f"port:{port}",
                    False,
                    f"{port}/tcp is already published by {holder}",
                    f"kwisatz services --json   ·   change *_PORT for {', '.join(names)}",
                    False,
                )
            )
    return found


def _python_ok() -> bool:
    return sys.version_info >= (3, 10)
