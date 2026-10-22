"""services.py: how kwisatz answers "is it running?" without being told (R-OPS-001/002).

The health rule is asserted directly because it is the rule `lib/helpers.sh`
waits_for_healthy uses — CLI and task script must agree, and everything the operator sees
(`status`, `services`, `doctor`'s exit 5) is a read of this one function.
"""

from __future__ import annotations

import json

from kwisatz import services


def c(state, health, name="x", status=""):
    return services.Container(name=name, state=state, health=health, status=status)


def test_the_wait_for_healthy_verdict():
    assert services.health_of([c("running", "healthy")]) == services.RUNNING
    assert services.health_of([c("running", "none")]) == services.RUNNING
    assert services.health_of([c("running", "unhealthy")]) == services.UNHEALTHY
    assert services.health_of([c("exited", "none", status="Exited (1) 2 minutes ago")]) == services.STOPPED
    assert services.health_of([c("restarting", "none", status="Restarting")]) == services.RESTARTING
    assert services.health_of([]) == services.UNKNOWN
    # one bad container is the whole stack's answer — the same way wait_for_healthy fails the run
    assert services.health_of([c("running", "healthy"), c("running", "unhealthy")]) == services.UNHEALTHY


def test_docker_labels_group_containers_into_one_stack():
    row = {
        "Names": "forgejo-1",
        "State": "running",
        "HealthStatus": "healthy",
        "Status": "Up 2 hours",
        "Image": "codeberg/forgejo",
        "Ports": "0.0.0.0:3000->3000/tcp, :::3000->3000/tcp",
        "Labels": "com.docker.compose.project=forgejo,com.docker.compose.project.config_files=/srv/forgejo/docker-compose.yml",
    }
    text = json.dumps(row)
    rows = services._json_rows(text)
    labels = services._labels(rows[0])
    assert labels["com.docker.compose.project"] == "forgejo"
    assert services._ports(str(rows[0]["Ports"])) == [3000]


def test_a_stack_defined_on_disk_but_not_running_is_stopped(tmp_path, monkeypatch):
    srv = tmp_path / "srv"
    (srv / "planka").mkdir(parents=True)
    (srv / "planka" / "docker-compose.yml").write_text("services: {}\n")
    (srv / "empty").mkdir()
    monkeypatch.setattr(services, "SRV_ROOT", srv)
    found = services.srv_stacks()
    assert found["planka"].state == services.STOPPED
    assert "empty" not in found, "no compose file is not a service"


def test_docker_services_merges_ls_and_ps(monkeypatch):
    ls = [{"Name": "kestra", "Status": "running(2)", "ConfigFiles": "/srv/kestra/docker-compose.yml"}]
    rows = [
        {
            "Names": "kestra-1",
            "State": "running",
            "HealthStatus": "healthy",
            "Status": "Up 3 hours",
            "Image": "kestra/kestra",
            "Ports": "0.0.0.0:8080->8080/tcp",
            "Labels": "com.docker.compose.project=kestra",
        },
        {
            "Names": "kestra-2",
            "State": "running",
            "HealthStatus": "none",
            "Status": "Up 3 hours",
            "Image": "postgres",
            "Ports": "",
            "Labels": "com.docker.compose.project=kestra",
        },
    ]
    ps = "\n".join(json.dumps(row) for row in rows)

    def fake_run(tool, args, timeout):
        if args[:2] == ["info", "--format"]:
            return "29.0.0"
        if args[:2] == ["compose", "ls"]:
            return json.dumps(ls)
        if args[:2] == ["ps", "-a"]:
            return ps
        return ""

    monkeypatch.setattr(services, "_run", fake_run)
    found = services.docker_services()
    assert found["kestra"].state == services.RUNNING
    assert found["kestra"].srv == "/srv/kestra"
    assert found["kestra"].ports == [8080]
    assert len(found["kestra"].containers) == 2


def test_no_docker_daemon_is_not_an_error(monkeypatch):
    monkeypatch.setattr(services, "_run", lambda *a, **k: "")
    assert services.docker_running() is False
    assert services.docker_services() == {}


def test_a_unit_that_does_not_exist_is_not_reported_as_stopped(monkeypatch):
    monkeypatch.setattr(services, "_run", lambda *a, **k: "LoadState=not-found\nActiveState=inactive\nSubState=dead\n")
    assert services.systemd_services(["ghost"]) == []


def test_a_real_unit_maps_to_a_state(monkeypatch):
    monkeypatch.setattr(services, "_run", lambda *a, **k: "LoadState=loaded\nActiveState=active\nSubState=running\n")
    found = services.systemd_services(["setup-llama-swap"])
    assert found[0].name == "llama-swap"
    assert found[0].state == services.RUNNING
    assert found[0].manager == "systemd"


def test_target_names_and_service_names_agree_after_canonical():
    assert services.canonical("setup-traefik") == "traefik"
    stack = services.Service(name="traefik", manager="docker", state=services.RUNNING)
    assert services.find([stack], "setup-traefik") is stack
    assert stack.annotation() == "docker · running"


def test_unhealthy_is_the_subset_doctor_exits_five_on():
    good = services.Service(name="a", state=services.RUNNING)
    bad = services.Service(name="b", state=services.UNHEALTHY)
    assert services.unhealthy([good, bad]) == [bad]


def test_log_source_prefers_the_stack_then_the_unit_then_the_apply_log(tmp_path):
    from kwisatz import logs as logsio

    compose = tmp_path / "docker-compose.yml"
    compose.write_text("services: {}\n")
    stack = services.Service(name="forgejo", manager="docker", source=str(compose))
    src = logsio.source_for(stack, "forgejo", tmp_path / "logs")
    assert src.kind == logsio.DOCKER and "compose" in " ".join(src.argv)

    unit = services.Service(name="llama-swap", manager="systemd", unit="llama-swap.service")
    assert logsio.source_for(unit, "llama-swap", tmp_path / "logs").kind == logsio.JOURNAL

    logs_dir = tmp_path / "logs"
    logs_dir.mkdir()
    (logs_dir / "kwisatz-20261022T0000-llama-swap.log").write_text("old run\n")
    assert logsio.source_for(None, "llama-swap", logs_dir).kind == logsio.APPLY_LOG

    missing = logsio.source_for(None, "nothing", logs_dir)
    assert missing.argv is None and "no logs" in missing.description


def test_stream_argv_uses_each_tool_s_dialect():
    from kwisatz import logs as logsio

    journal = logsio.LogSource(logsio.JOURNAL, ["journalctl", "-u", "x.service"], "unit")
    compose = logsio.LogSource(logsio.DOCKER, ["docker", "compose", "-f", "f", "logs"], "stack")
    assert logsio.stream_argv(journal, tail=50, since="10m", follow=True) == [
        "journalctl", "-u", "x.service", "--since", "10m", "-n", "50", "-f",
    ]
    assert logsio.stream_argv(compose, tail=50, since=None, follow=False) == [
        "docker", "compose", "-f", "f", "logs", "--tail", "50",
    ]


def test_a_modern_engine_is_still_read_as_running(monkeypatch):
    """Engine 29.9 dropped `.Server.Version` from `docker info`'s format struct.

    Probing only that spelling makes `docker_running()` False on a box with a working
    daemon, which silently drops every docker stack from discovery — the traefik stack on
    the Ubuntu 26.04 VM vanished from `kwisatz services` for exactly this reason.
    """

    def fake_run(tool, args, timeout):
        if args[:1] == ["info"] and "{{.Server.Version}}" in " ".join(args):
            return ""  # rc != 0: template error
        if args[:1] == ["info"]:
            return "29.9.2\n"
        if args[:2] == ["compose", "ls"]:
            return '[{"Name":"traefik","Status":"running(2)","ConfigFiles":"/opt/traefik/docker-compose.yml"}]\n'
        if args[:2] == ["ps", "-a"]:
            return (
                json.dumps(
                    {
                        "Names": "traefik",
                        "State": "running",
                        "HealthStatus": "none",
                        "Status": "Up 3 minutes",
                        "Image": "traefik:v3",
                        "Ports": "",
                        "Labels": "com.docker.compose.project=traefik,"
                        "com.docker.compose.project.config_files=/opt/traefik/docker-compose.yml",
                    }
                )
                + "\n"
            )
        return ""

    monkeypatch.setattr(services, "_run", fake_run)
    assert services.docker_running() is True
    found = services.docker_services()
    assert found["traefik"].state == services.RUNNING
    assert found["traefik"].srv == "/opt/traefik"


def test_no_daemon_means_no_docker_stacks(monkeypatch):
    monkeypatch.setattr(services, "_run", lambda *a, **k: "")
    assert services.docker_running() is False
    assert services.docker_services() == {}
