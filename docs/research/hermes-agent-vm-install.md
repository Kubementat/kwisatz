# Hermes Agent install best practices + VM hosting research (verified 2026-10-01)

Sources: official docs https://hermes-agent.nousresearch.com/docs (installation, cli-commands,
security, docker, messaging), the official installer https://hermes-agent.nousresearch.com/install.sh
(downloaded and read), GitHub releases https://github.com/NousResearch/hermes-agent/releases,
virt-runner README + source (`~/dev/os_projects/virt-runner`, HEAD 2103509), third-party VPS guides
(virtua.cloud v0.20.4 guide, lumadock backup guide). Third-party claims are marked as such.

## 1. Install
- Official method: `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`.
  Clones the repo to `~/.hermes/hermes-agent/`, bootstraps `uv`, installs a pinned Python, Node.js,
  ripgrep, FFmpeg, browser tools (Chromium) and a computer-use driver, creates `~/.local/bin/hermes`.
  User data lives in `~/.hermes/` (override: `HERMES_HOME`). Install log: `~/.hermes/logs/install.log`.
- Installer flags (read from the script): `--non-interactive` / `--skip-setup`, `--skip-browser`,
  `--skip-computer-use`, `--include-desktop`, `--verbose`, `--dir PATH`, `--hermes-home PATH`,
  `--branch NAME`, `--commit SHA`, `--json`, `--manifest`, `--stage`.
- Version pinning: default branch is `main` (moving). `--commit SHA` pins. The docs only list a
  subset of the flags; `--commit` is in the script but undocumented, so behaviour must be verified
  in the VM before we rely on it.
- Latest release: v0.21.5 (2026-09-24). Git tags and Docker image tags are date-based: v0.21.5 is
  git tag `v2026.9.24`, commit `f97608f178d1ffeca59860195ab7da295f7c8e5f`, an ancestor of `main`
  (checked via the GitHub compare API). The old Docker setup pinned image `v2026.8.27`.
- `--commit` behaviour (read from the installer): on a re-run it first fast-forwards the checkout
  to `origin/main`, then checks out the pinned commit, and fails if the commit is not on the
  branch. The installer itself is also available per commit at
  `https://raw.githubusercontent.com/NousResearch/hermes-agent/<commit>/scripts/install.sh`.
- Service-user install (official): install prerequisites as admin, run the installer **as the
  service user**, add `~/.local/bin` to PATH, run `hermes doctor`, `sudo loginctl enable-linger <user>`.
- Sizing (third-party, virtua.cloud): 2 GB RAM / 1 vCPU / 10 GB minimum; 4 GB+ / 2 vCPU / 20 GB+
  recommended; Ubuntu 24.04 preferred. Chromium needs shared memory (docs: `--shm-size=1g` in Docker).

## 2. Running the gateway
- `hermes gateway install` → user unit `~/.config/systemd/user/hermes-gateway.service`.
  `sudo hermes gateway install --system` → `/etc/systemd/system/hermes-gateway.service`.
- Docs recommendation for headless machines: user service + linger gives start-at-boot with no
  root involvement and avoids password prompts during `hermes update`.
- `hermes gateway restart` drains in-flight turns; prefer it over `systemctl restart`.
- Logs: `journalctl --user -u hermes-gateway -f`, plus `~/.hermes/logs/`.
- Messaging platforms are outbound-only; no inbound port is needed for Telegram etc.
- v0.21.4 added a host-wide gateway singleton lock. Never run two gateways on the same data dir.

## 3. Security model (official checklist)
- Never run the gateway as root; `chmod 600 ~/.hermes/.env`.
- Explicit allowlists (`TELEGRAM_ALLOWED_USERS`, `GATEWAY_ALLOWED_USERS`) or DM pairing; never
  `GATEWAY_ALLOW_ALL_USERS=true`. Default with no allowlist is deny.
- Isolate command execution: docs recommend `terminal.backend: docker|modal|daytona|vercel_sandbox`,
  or "run gateway on separate machine/VM". A dedicated VM with `terminal.backend: local` matches
  the second option: the VM is the blast radius.
- `approvals.mode: smart|manual|off` (default smart); `approvals.deny` patterns; a hardline
  blocklist always applies. `HERMES_WRITE_SAFE_ROOT` restricts file writes.
- The virtua.cloud guide gives the service user `NOPASSWD:ALL` sudo. Acceptable only inside a
  disposable VM, not on a shared host.

## 4. Backup, update, migration
- `hermes backup [-o PATH] [-q] [-k N]` → zip of config, skills, sessions, state DBs. Excludes
  SQLite sidecars, `checkpoints/`, `models/`, `runtimes/`, `node/`, browser profiles and
  credentials, symlinks, and the source checkout. Exit 1 = partial (files skipped).
- `hermes import <zip> [-f]` restores into `HERMES_HOME`; stop the gateway first.
- Update: `hermes backup` → `hermes update [--backup]` → `hermes config migrate` → restart.
  `hermes doctor [--fix]` exits non-zero while problems remain (usable as a health gate).
- **No official Docker → native migration path.** Docs say the data layout is identical
  (`/opt/data` == `~/.hermes`), so copying works in principle but is unsupported.
- Data that matters: `SOUL.md`, `memories/`, `skills/`, `state.db`, `.env`, `config.yaml`,
  `cron/`, `hooks/`, `sessions/`. Do not copy `hermes-agent/` or venvs.
- Pitfalls: never `cp` a live `state.db` (WAL); archives contain secrets; ownership differs
  (Docker image uid 10000 vs guest user uid 1000); browser profiles/credentials are not in the
  backup zip, so platform logins stored there need re-pairing.
- Version gap risk: v0.21.0 rewrote the session store's connection handling and made `state.db`
  fragile on some installs; fixed in v0.21.2. Target ≥ v0.21.2 and keep a cold copy of the old
  data dir until the new install is verified.

## 5. SQLite on shared filesystems
- Docs: `state.db` uses WAL, which is not coherent across VM boundaries (virtiofs, 9p). Fresh DBs
  auto-downgrade to DELETE mode with a warning; existing WAL DBs log errors unless converted
  offline and `database.journal_mode: delete` is set.
- Consequence: keep `HERMES_HOME` on the VM's own disk. Use virtiofs only for plain files
  (workspace, backup zips).

## 6. Desktop / mobile access (remote gateway)
Sources: https://hermes-agent.nousresearch.com/docs/user-guide/desktop,
https://www.glukhov.org/ai-systems/hermes/hermes-remote-backend-desktop/,
https://github.com/NousResearch/hermes-agent/issues/38412
- Hermes Desktop connects to a remote backend started with `hermes serve --host 0.0.0.0 --port 9119`
  (Settings → Gateways → Remote gateway → `http://<host>:9119`, or `HERMES_DESKTOP_REMOTE_URL`).
  This is a **second process** next to `hermes gateway`; both share `~/.hermes`.
- A non-loopback bind forces auth. For trusted networks: `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`,
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` (or `..._PASSWORD_HASH`), `HERMES_DASHBOARD_BASIC_AUTH_SECRET`
  in `~/.hermes/.env`. Docs: never expose basic auth to the internet; use VPN, Nous OAuth or OIDC.
- No built-in service installer for `serve`; docs suggest a systemd unit with
  `EnvironmentFile=%h/.hermes/.env`. WebSocket path `/api/ws`; reverse-proxy path prefixes supported.
- Port 8642 is the separate OpenAI-compatible API server, not the Desktop remote gateway.
- Issue #38412: packaged Desktop client was rejected on `/api/ws` (4403) against a remote gateway.
  Must be re-tested on the pinned version.
- **There is no official mobile app** in the docs. Community clients exist (gldc/hermes-mobile-app,
  rusty4444/hermes-android, michaeldimuro/hermes-mobile, dylan-buck/Hermes-iOS); they target the
  dashboard and/or the 8642 API server over LAN/Tailscale. The dashboard served on 9119 is also
  usable from a phone browser.

## 7. libvirt networking facts (checked on this host)
- `default` network: NAT, bridge `virbr0`, host `192.168.122.1`, DHCP range `.2`–`.254`.
- libvirt NAT rejects new inbound connections to guests from other interfaces (LAN, Docker
  bridges); connections originating from the host itself are fine.
- Guest → host traffic hits the host's INPUT chain, so ufw's default-deny applies to it.
- `virsh nwfilter-*` and `virt-xml` are available; nwfilters are enforced on the host side of the
  guest NIC, so root inside the guest cannot bypass them.
- Static address: `virsh net-update default add ip-dhcp-host` (MAC → IP reservation).

## 8. virt-runner facts relevant here
- `virt-runner create NAME --ram GiB --vcpu N --disk GiB --mount HOST[:GUEST] --json`; Ubuntu guest,
  cloud user `ubuntu` (uid 1000), key `~/.ssh/virt_runner_key`, libvirt `default` NAT network.
- VMs are always created with `--autostart` (come back after host reboot).
- `--mount` is virtiofs, read-write, UIDs pass straight through, persisted via fstab. Mounts cannot
  be added to an existing VM.
- `create` on an existing name fails with `vm-already-defined` (no converge). `destroy` deletes the
  disk. There is no start/stop/exec command: use `virsh` and plain `ssh` with the reported command.
- IP comes from DHCP; no static lease or port forwarding support.
