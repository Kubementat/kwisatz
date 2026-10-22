"""What is running right now (§6.7, R-OPS-001).

Discovery is by convention, never by a registry kwisatz would have to keep in sync:

  * `/srv/<name>/docker-compose.yml` — the layout every task script follows;
  * the `com.docker.compose.project` / `…project.config_files` labels compose puts on every
    container, which is how a stack that lives *outside* `/srv` (traefik runs from
    `/opt/traefik on some boxes) is still found;
  * systemd units whose name matches a task script (`setup-llama-swap.sh` ↔
    `llama-swap.service`), plus the overrides in `data/services.yml`.

The unhealthy rule is the one `lib/helpers.sh:wait_for_healthy` implements — running plus
`healthy`/`none` is up, `unhealthy` is unhealthy, `restarting` is restarting, anything else
is down — so the CLI and the task script cannot disagree about "is it up" (R-OPS-002).

Read-only by construction, and tolerant of a box with no docker, no systemd, or a daemon
that is up but unresponsive: every probe is a bounded subprocess call, never a wait.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

SERVICES_YML = Path(__file__).resolve().parent / "data" / "services.yml"
#: the layout every task script writes; a test may point this at a directory of its own
SRV_ROOT = Path("/srv")

RUNNING = "running"
UNHEALTHY = "unhealthy"
RESTARTING = "restarting"
STOPPED = "stopped"
UNKNOWN = "unknown"

# `docker ps` Ports entries look like "0.0.0.0:9292->9292/tcp, :::9292->9292/tcp"
_PORT_RE = re.compile(r"(?:^|\s|,)(?:\d+\.\d+\.\d+\.\d+|\[?:[^\]]+\]|::):(?P<port>\d+)->")

_COMPOSE_LABELS = (
    "com.docker.compose.project",
    "com.docker.compose.project.config_files",
)


@dataclass
class Container:
    name: str
    state: str
    health: str
    status: str = ""
    image: str = ""
    ports: list[int] = field(default_factory=list)


@dataclass
class Service:
    """One thing that is (or was) running on this box, and how kwisatz knows about it."""

    name: str
    manager: str = "docker"  # docker | systemd | process
    state: str = UNKNOWN
    source: str = ""
    srv: str = ""
    ports: list[int] = field(default_factory=list)
    containers: list[Container] = field(default_factory=list)
    unit: str = ""
    started_at: str = ""

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "manager": self.manager,
            "state": self.state,
            "source": self.source,
            "srv": self.srv,
            "ports": sorted(set(self.ports)),
            "unit": self.unit,
            "started_at": self.started_at,
            "containers": [
                {"name": c.name, "state": c.state, "health": c.health, "ports": sorted(set(c.ports))}
                for c in self.containers
            ],
        }

    def annotation(self) -> str:
        """The `docker · running` that `status`/`list` append (R-STA-002)."""
        return f"{self.manager} · {self.state}"

    def is_down(self) -> bool:
        return self.state in (STOPPED, UNKNOWN)


def canonical(name: str) -> str:
    return name.removeprefix("setup-").removeprefix("configure-")


def load_hints(path: Path | None = None) -> dict[str, dict]:
    """`data/services.yml` → `{name: {manager, unit}}`; an absent file means no hints."""
    try:
        import yaml

        table = yaml.safe_load((path or SERVICES_YML).read_text())
    except (OSError, ImportError):
        return {}
    if not isinstance(table, dict):
        return {}
    services = table.get("services")
    return {str(k): v for k, v in services.items()} if isinstance(services, dict) else {}


# ── the probes ────────────────────────────────────────────────────────────────────


def _run(tool: str, args: list[str], timeout: float) -> str:
    path = shutil.which(tool)
    if not path:
        return ""
    try:
        done = subprocess.run(
            [path, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout if done.returncode == 0 else ""


def docker_running() -> bool:
    """True only when a `docker info` answers — an installed CLI is not a daemon."""
    return bool(_run("docker", ["info", "--format", "{{.Server.Version}}"], 10.0))


def systemd_running() -> bool:
    return shutil.which("systemctl") is not None


def _json_rows(out: str) -> list[dict]:
    rows = []
    for line in out.splitlines():
        line = line.strip().rstrip(",")
        if not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def _json_list(out: str) -> list:
    try:
        data = json.loads(out or "[]")
    except ValueError:
        return []
    return data if isinstance(data, list) else []


def _labels(row: dict) -> dict[str, str]:
    raw = row.get("Labels") or ""
    if isinstance(raw, dict):
        return {str(k): str(v) for k, v in raw.items()}
    return {kv.split("=", 1)[0]: kv.split("=", 1)[1] for kv in str(raw).split(",") if "=" in kv}


def _ports(text: str) -> list[int]:
    return sorted({int(m.group("port")) for m in _PORT_RE.finditer(text or "")})


def health_of(containers: list[Container]) -> str:
    """The `wait_for_healthy` verdict for a set of containers, as one word (R-OPS-002)."""
    if not containers:
        return UNKNOWN
    saw_restarting = False
    for container in containers:
        if container.health == "unhealthy":
            return UNHEALTHY
        if container.state == "running" and container.health in ("healthy", "none"):
            continue
        if "restarting" in container.state or "restarting" in container.status:
            saw_restarting = True
    if saw_restarting:
        return RESTARTING
    states = {c.state for c in containers}
    if states == {"running"}:
        return RUNNING
    if states <= {"exited", "created", "dead"}:
        return STOPPED
    return UNKNOWN


# ── discovery ─────────────────────────────────────────────────────────────────────


def docker_services() -> dict[str, Service]:
    """Every stack the daemon knows, from `compose ls` (projects) and `ps -a` (containers)."""
    if not docker_running():
        return {}
    projects: dict[str, str] = {}
    for item in _json_list(_run("docker", ["compose", "ls", "--format", "json"], 20.0)):
        if isinstance(item, dict) and item.get("Name"):
            projects[str(item["Name"])] = str(item.get("ConfigFiles") or "").split(",")[0].strip()

    grouped: dict[str, list[Container]] = {}
    loose: dict[str, list[Container]] = {}
    for row in _json_rows(_run("docker", ["ps", "-a", "--format", "json"], 20.0)):
        labels = _labels(row)
        container = Container(
            name=str(row.get("Names") or ""),
            state=str(row.get("State") or "unknown"),
            health=str(row.get("HealthStatus") or "none"),
            status=str(row.get("Status") or ""),
            image=str(row.get("Image") or ""),
            ports=_ports(str(row.get("Ports") or "")),
        )
        project = str(labels.get("com.docker.compose.project") or "")
        if project:
            grouped.setdefault(project, []).append(container)
            projects.setdefault(project, str(labels.get(_COMPOSE_LABELS[1]) or "").split(",")[0].strip())
        else:
            loose[container.name] = [container]

    services: dict[str, Service] = {}
    for name in set(projects) | set(grouped):
        containers = grouped.get(name, [])
        source = projects.get(name, "")
        stack = Path(source).parent if source else None
        services[name] = Service(
            name=name,
            manager="docker",
            state=health_of(containers),
            source=source,
            srv=str(stack) if stack else "",
            containers=containers,
            ports=sorted({p for c in containers for p in c.ports}),
            started_at=containers[0].status if containers else "",
        )
    # a lone `docker run` is its own "service" — report it rather than hide it
    for name, containers in loose.items():
        services.setdefault(name, Service(name=name, manager="process", state=health_of(containers), containers=containers,
                                          ports=sorted({p for c in containers for p in c.ports})))
    return services


def srv_stacks() -> dict[str, Service]:
    """`/srv/<name>/docker-compose.yml` that the daemon does not know about (i.e. stopped)."""
    found: dict[str, Service] = {}
    try:
        entries = sorted(SRV_ROOT.iterdir())
    except OSError:  # no /srv, or no permission to look
        return found
    for directory in entries:
        compose = directory / "docker-compose.yml"
        if not directory.is_dir() or not compose.is_file():
            continue
        found[directory.name] = Service(
            name=directory.name, manager="docker", state=STOPPED, source=str(compose), srv=str(directory)
        )
    return found


def systemd_services(names: list[str]) -> list[Service]:
    """Units matching a target name, plus the units `data/services.yml` declares."""
    found: list[Service] = []
    wanted: dict[str, str] = {}
    for name in names:
        stem = canonical(name)
        wanted.setdefault(stem, f"{stem}.service")
    for name, hint in load_hints().items():
        if isinstance(hint, dict) and hint.get("unit"):
            wanted.setdefault(canonical(name), str(hint["unit"]))
    for stem, unit in wanted.items():
        loaded, active, sub = _unit_state(unit)
        if loaded != "loaded":
            # `systemctl show ghost.service` answers happily (`not-found`/`inactive`), so a
            # unit that does not exist must be judged by LoadState, never by ActiveState
            continue
        if active != "active":
            state = RESTARTING if active == "activating" else STOPPED
        else:
            state = RUNNING if sub in ("running", "exited") else UNKNOWN
        found.append(Service(name=stem, manager="systemd", state=state, unit=unit, source=unit))
    return found


def _unit_state(unit: str) -> tuple[str, str, str]:
    """(LoadState, ActiveState, SubState); LoadState is what proves the unit exists."""
    out = _run(
        "systemctl",
        ["show", unit, "--property=LoadState,ActiveState,SubState", "--no-pager"],
        10.0,
    )
    fields = {line.split("=", 1)[0]: line.split("=", 1)[1] for line in out.splitlines() if "=" in line}
    return fields.get("LoadState", ""), fields.get("ActiveState", ""), fields.get("SubState", "")


def discover(targets: list[str] | None = None) -> list[Service]:
    """Everything installed and running, deduplicated, sorted by name.

    `targets` (the enabled/known target names) decides which systemd units are worth
    asking about; without them kwisatz would be guessing at unit names.
    """
    services = srv_stacks()
    services.update(docker_services())
    names = list(targets or [])
    for name in services:
        names.append(name)
    for service in systemd_services(names):
        # a stack that runs as both a container and a unit is the container's story
        services.setdefault(service.name, service)
    return sorted(services.values(), key=lambda s: s.name)


def find(services: list[Service], target: str) -> Service | None:
    """The service a target manages, matched on the canonical name."""
    want = canonical(target)
    for service in services:
        if canonical(service.name) == want:
            return service
    return None


def unhealthy(services: list[Service]) -> list[Service]:
    return [s for s in services if s.state == UNHEALTHY]
