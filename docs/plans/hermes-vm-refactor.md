# Plan: Hermes Agent in a virt-runner VM (replaces the Docker setup)

Date: 2026-10-01 (v2 after brainstorming — implemented; verified in a nested VM test, real-server checks in `HOW_TO_TEST.md`)
Research: `docs/research/hermes-agent-vm-install.md`

## Goal

`tasks/setup-hermes.sh` provisions a dedicated KVM guest via virt-runner and installs Hermes
Agent natively inside it (official installer, non-root user, systemd user services). The VM is
the isolation boundary: Hermes gets a full machine (`terminal.backend: local`, passwordless
sudo), while the host controls what the VM may reach. A separate, explicit migration step moves
the existing Docker data into the VM.

## Decisions (2026-10-01)

| # | Decision |
|---|---|
| 1 | Docker is too limiting; Hermes gets a whole VM with passwordless sudo in the guest. |
| 2 | **Replace** `setup-hermes.sh`; Docker remains only as the migration source. |
| 3 | VM → LAN/host access is a **configurable allowlist** (forgejo, llama-swap, llama.cpp, planka, …), enforced on the host. Internet stays open. |
| 4 | Desktop (and phone) clients reach Hermes on the **local network** via `hermes serve`. |
| 5 | Hermes is **pinned** (`HERMES_COMMIT`), bumped deliberately through the script. |
| 6 | Missing prerequisites are not an error: notify, then run `setup-virtualization.sh` and `setup-virt-runner.sh`. |
| 7 | The 8642 API server is **not** exposed for now. |
| 8 | VM defaults: 4 GB RAM, 2 vCPU, 50 GB disk. |
| 9 | The Docker → VM migration is a **one-off, documentation only** (`docs/hermes-docker-to-vm-migration.md`); no migration code or flag in `setup-hermes.sh`. |
| 10 | Manual test instructions for the server live in `HOW_TO_TEST.md` (repo root). |

Out of scope: internet exposure (OAuth/OIDC), multi-profile gateways, changes to virt-runner,
installing a specific mobile app (there is no official one).

## Design

```
LAN client ──▶ host:9119 (systemd-socket-proxyd, ufw: LAN only) ──▶ guest:9119 hermes serve
                                                                    guest      hermes gateway
host /srv/hermes/workspace ── virtiofs ──▶ /workspace   (same path as in Docker)
host /srv/hermes/backups   ── virtiofs ──▶ /mnt/backups (daily hermes backup zips
                                                     + current/ plain-text config mirror)
guest ~/.hermes  (state.db etc. on the VM disk; SQLite WAL is unsafe on virtiofs)
guest NIC ── nwfilter hermes-egress ──▶ internet: allow · allowlist: allow · other private: drop
```

- **Static address:** DHCP reservation for the VM's MAC on the libvirt `default` network
  (`HERMES_VM_IP`, default `.50` on that network). Needed by the firewall rules and the proxy.
- **Egress allowlist:** `HERMES_ALLOWED_ENDPOINTS`, space-separated `ADDR:PORT[-PORT]`, where
  `host` means the hypervisor (`192.168.122.1`). Example:
  `host:3000 host:8080 192.168.1.20:8080-8090 192.168.1.30:443`.
  - libvirt nwfilter `hermes-egress` (rendered from `templates/hermes/`) attached to the VM NIC
    with `virt-xml`: allow DHCP/DNS to the host, allow the listed endpoints, drop all other
    RFC1918/link-local destinations, allow the rest. Host-enforced, so guest root cannot lift it.
    Re-runs redefine the filter, so changing the list converges without touching the VM.
  - For `host:` entries additionally `ufw allow in on virbr0 from <vm-ip> to any port <p>`.
  - Host services must listen on `0.0.0.0` or `virbr0`; `127.0.0.1`-only services stay unreachable.
- **Inbound (Desktop/phone):** opt-in `HERMES_SERVE=true`. Guest runs a second user unit
  `hermes-serve.service` (`hermes serve --host 0.0.0.0 --port 9119`, `EnvironmentFile=%h/.hermes/.env`).
  Basic-auth credentials are generated **inside the guest** into `~/.hermes/.env` (600) only if
  absent, and read back on re-runs. On the host a `systemd-socket-proxyd` unit pair forwards
  `:9119` to the VM (libvirt NAT blocks direct LAN → guest), with a ufw rule limited to
  `HERMES_SERVE_ALLOW_FROM` (LAN CIDR). Optional TLS via the existing Traefik
  `host-services` file-provider pattern (`HERMES_TRAEFIK=true`, `HERMES_DOMAIN`).
- **Secrets** never pass through the task script or templates; they live in the guest's
  `~/.hermes/.env`, written by `hermes setup`, `hermes import`, or generated in-guest.

## Steps

1. **Prerequisites** — if KVM/libvirt or `virt-runner` is missing: `info`, then run
   `tasks/setup-virtualization.sh` and `tasks/setup-virt-runner.sh`. If libvirt is still not
   usable in this shell (fresh group membership), exit with "log out/in and re-run".
   → verify: `virt-runner list --json` succeeds.
2. **Converge the VM** — create `hermes` if absent (`--ram/--vcpu/--disk`, two mounts); start it
   if shut off; never destroy. Add the DHCP reservation. → verify: bounded SSH round-trip on the
   reserved IP.
3. **Network policy** — render + define nwfilter, attach to the NIC, apply ufw rules.
   → verify from the guest: an allowlisted endpoint connects, a non-listed private address does
   not, an internet host does.
4. **Provision the guest** — `templates/hermes/provision-guest.sh` run over SSH as `ubuntu`: apt
   prerequisites, official installer `--non-interactive --commit <pinned>`, linger, daily backup
   timer; with `HERMES_LLM_BASE_URL`/`HERMES_LLM_MODEL` (+optional key) also wires the main model
   to that OpenAI-compatible endpoint (see implementation notes). Skips the installer when the
   pinned commit is already checked out.
   → verify: `hermes --version`, `hermes doctor`.
5. **Services** — only when `~/.hermes/.env` exists in the guest: `hermes gateway install` + start;
   with `HERMES_SERVE=true` also `hermes-serve.service` and the host proxy. Fresh install without
   config: print next steps (`virt-runner ssh hermes` → `hermes setup`) and exit 0.
   → verify: units active (bounded poll); `curl` to `host:9119` answers.
6. **Repo hygiene** — remove `docker-compose.yml` / `restart_hermes.sh` templates, update
   `config.yaml.example`, `--help`, `AUTOMATIONS.md`, `machine-config.yml.example`,
   `skills/kwisatz-assistant/SKILL.md`; shellcheck/yamllint.

Configuration (env, with defaults): `HERMES_VM_NAME=hermes`, `HERMES_VM_RAM=4`, `HERMES_VM_VCPU=2`,
`HERMES_VM_DISK=50`, `HERMES_VM_IP=<.50 on the libvirt network>`, `HERMES_COMMIT=<pinned release SHA>`,
`HERMES_HOST_DIRECTORY=/srv/hermes`, `HERMES_ALLOWED_ENDPOINTS=""`, `HERMES_SERVE=false`,
`HERMES_SERVE_PORT=9119`, `HERMES_SERVE_ALLOW_FROM=<required when HERMES_SERVE=true>`,
`HERMES_TRAEFIK=false`, `HERMES_DOMAIN=""`, `HERMES_LLM_BASE_URL=""`, `HERMES_LLM_MODEL=""`,
`HERMES_LLM_API_KEY=""`, `WAIT_TIMEOUT=180`.

## Migration path (existing Docker install on the server)

One-off manual procedure, documented in `docs/hermes-docker-to-vm-migration.md` and **not**
implemented in `setup-hermes.sh`. Because the new script no longer ships the compose file, the
doc must work with the `docker-compose.yml` already present in `/srv/hermes` on the server. The
old stack is only stopped, never deleted, so rollback is `docker compose up -d hermes-gateway`.

1. Stop the old gateway: `docker compose stop hermes-gateway` (two gateways on one bot token or
   one data dir must never run at once).
2. Cold safety copy: `sudo tar` of `/srv/hermes/.hermes` to `/srv/hermes/backups/` (mode 600).
3. Portable archive with the old image's own tooling:
   `docker compose run --rm hermes-gateway backup -o /workspace/hermes-migration.zip`
   (lands in `/srv/hermes/workspace`, visible in the guest as `/workspace`).
4. One-time ownership fix: `sudo chown -R <invoking user>` on `/srv/hermes/workspace` and
   `/srv/hermes/backups` (Docker used uid 10000, guest user is uid 1000 with pass-through).
5. Run steps 1–4 above, then in the guest: `hermes import /workspace/hermes-migration.zip -f`,
   `hermes config migrate`, set `terminal.backend: local` / `terminal.cwd: /workspace`,
   `hermes doctor`.
6. Start the services (step 5 above), send a test message, check memories/skills/sessions.
7. Delete the migration zip from the workspace (it contains secrets). Decommissioning the old
   container and `/srv/hermes/.hermes` stays a manual step after a soak period.

## Implementation notes (deviations from the design above)

- **`hermes doctor` is informational, not a gate.** It exits non-zero while any problem
  remains, which is always the case on a fresh, unconfigured install. The hard gates are the
  pinned-commit check and the units being active.
- **The gateway service always runs.** There is no reliable "configured" test (the installer
  writes default settings into `.env`), and an unconfigured gateway idles harmlessly. After
  `hermes setup`, `hermes gateway restart` picks up the settings.
- **Prerequisite bootstrap continues in the same run.** After installing the prerequisites the
  script re-executes itself once through `sudo -u <user>` to pick up the new `libvirt`/`kvm`
  group membership, passing its configuration explicitly (sudo-rs on Ubuntu 26.04 has no
  blanket `--preserve-env`).
- **`HERMES_VM_IP` defaults to `.50` on whatever subnet the libvirt `default` network uses**,
  not a fixed `192.168.122.50` (libvirt picks another subnet when that one is taken).
- **virt-runner must support `create --mount`**, which is on its `develop` branch but not on the
  default branch yet. The script checks for it; `setup-virt-runner.sh` gained an optional
  `VIRT_RUNNER_BRANCH`.
- **`setup-virtualization.sh` installs `qemu-system-x86`** (x86_64) or `qemu-system-arm` plus
  `qemu-efi-aarch64` (aarch64) instead of `qemu-kvm`, which has no installation candidate on
  Ubuntu 26.04.
- **The installer is fetched from the pinned commit** (`raw.githubusercontent.com/.../<commit>/scripts/install.sh`)
  instead of the moving `install.sh` URL, so its content is pinned as well.
- **One VM restart at first setup.** The DHCP reservation and the filter attachment only take
  effect on the next start, so the script does one `virsh shutdown` / `start` after creating
  the VM. Later allowlist changes are applied live (`nwfilter-define`), without a restart.
- **Filter details:** named `<vm-name>-egress`; besides RFC1918 and link-local it also drops
  CGNAT `100.64.0.0/10` (NetBird/Tailscale ranges); allowlist entries are TCP only.
- **Traefik needs a second ufw rule** (Docker `PROXY_NETWORK` subnet → serve port), because
  Traefik reaches the host proxy from its container network.
- **Local LLM endpoint (`HERMES_LLM_BASE_URL`/`HERMES_LLM_MODEL`/`HERMES_LLM_API_KEY`):** wires
  the main model to any OpenAI-compatible server the private AI stack exposes (llama-swap,
  vLLM, llama.cpp-server) using Hermes' `custom` provider (plain `chat_completions` wire; the
  `openai-api` overlay hardcodes the Codex/Responses transport and is rejected with HTTP 400 by
  llama-swap, so it must not be used for local endpoints): the guest runs
  `hermes config set model.provider custom` plus `model.base_url`/`model.default`/
  `model.api_mode chat_completions`/`model.key_env OPENAI_API_KEY`, and `OPENAI_BASE_URL`/`OPENAI_API_KEY` go into the guest's
  `~/.hermes/.env` — the key is only appended when the file has none (re-runs never rotate it),
  the base URL is upserted. The endpoint is deduplicated into the egress allowlist automatically
  when its host is the hypervisor (as `host:<port>`) or an IPv4; hostnames require manual
  `HERMES_ALLOWED_ENDPOINTS`. The provider switch is deliberate on every re-run — these variables
  are then the source of truth for the main model (to go back to e.g. Portal/OAuth, unset them
  and run `hermes model` inside the guest). If `config set` cannot upgrade a never-configured
  `model: ""` sentinel, run `hermes model` once in the guest first (verify during the real-server
  tests). Every written value is read back with `hermes config get` so a silently dropped setting
  fails provisioning instead of surfacing at chat time. A gateway already running is restarted to
  pick the endpoint up.
- **Backup retention:** the backup unit keeps the 7 newest zips in `/mnt/backups`.
- **Host-backup friendly:** everything the host backup solution
  (`setup-backup-client.sh`, borg; default scope includes `/srv`) needs is under
  `/srv/hermes`: the live workspace, the daily `hermes backup` zips, and a
  plain-text config mirror in `/srv/hermes/backups/current/` written after each
  run (`config.yaml`, `.env`, `SOUL.md`, `memories/`, `skills/`, `cron/`,
  `hooks/`, `skins/` — never `state.db`/`sessions/`, WAL-on-virtiofs is unsafe).
  A `current.old` swap artefact is kept one cycle. Restores still go through the
  zips (`hermes import`); `current/` is for browsing/host-side consistency.
- **Not converged:** ufw rules of endpoints removed from the allowlist (the filter already
  blocks them) and a previously enabled `HERMES_SERVE` (disable commands are printed).
- `tests/machine-config.test.yml` has an ad-hoc `setup-hermes` entry (nested KVM, disabled by
  default); `skills/kwisatz-assistant/SKILL.md` only lists the script name and needed no change.

## Risks / to verify during implementation

- `--commit` pinning is in the installer script but undocumented; confirm it survives re-runs.
- `hermes import` across the v2026.8.27 → v0.21.x gap (session store rewrite in v0.21.0, fixed in
  v0.21.2). The cold tar is the fallback; worst case copy `memories/`, `skills/`, `SOUL.md`,
  `config.yaml`, `.env` by hand and accept losing session history.
- Browser profiles and platform credentials are excluded from `hermes backup`; some platform
  logins may need re-pairing.
- nwfilter on a NAT network together with ufw and Docker-published host ports: rule order and
  DNAT interplay need a real test on the server (step 3 verification is the gate).
- Desktop remote gateway had a WebSocket rejection bug (issue #38412); test with the pinned
  version, directly and through Traefik.
- Mobile: no official app. Phone access means the dashboard in a browser or a community client;
  some of those want the 8642 API server, which this plan does not expose.
- An existing VM cannot gain mounts later; both mounts must be right at first create.
- VM-based test suite: this task needs nested KVM inside the test VM. Likely a preflight-only
  test there, full run verified manually on the host.
