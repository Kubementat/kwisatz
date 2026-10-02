# Feature Plan: Orca Remote Server Setup (`tasks/setup-orca.sh`)

## Background
Orca (https://www.onorca.dev, stablyai/orca, MIT) is an Agent Development
Environment. A **Remote Orca Server** runs the full Orca runtime on one machine
(worktrees, terminals, agent sessions) while clients (desktop, web, mobile)
connect to it.

Two host modes exist (never both at once on the same machine):
1. Orca desktop app + Tailscale (GUI, in-app pairing links)
2. `orca serve` — headless runtime, ideal for a systemd-managed server

Knowledge sources:
- https://www.onorca.dev/docs/remote-servers
- https://www.onorca.dev/docs/cli/reference (`orca serve --port --pairing-address --mobile-pairing --json`)
- **Official headless guide**: https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md
- GitHub releases: assets `orca-linux.AppImage` (x86_64) / `orca-linux-arm64.AppImage` (aarch64)

Key facts from the official headless guide:
- `orca serve` starts the runtime without a desktop window; it **auto-starts
  Xvfb on `:99`** when no `DISPLAY` is set, but the `xvfb` package and the
  Electron shared libraries must be installed first.
- Install dir `/opt/orca`, AppImage `root:root 755`; service runs as a
  dedicated unprivileged system user `orca` (keeps Chromium sandbox enabled).
- `loginctl enable-linger orca` keeps live terminals/agent processes in their
  own `orca-daemon-*.scope` across service restarts.
- Service: `KillMode=mixed`, `Restart=on-failure`,
  `RestartPreventExitStatus=3` (3 = userData profile lock),
  `StartLimitIntervalSec=300` / `StartLimitBurst=5`, `RestartSec=5`.
- With `--json`, the service logs one line
  `{"type":"orca_server_ready","schemaVersion":1,"pairing":{...},...}` after
  the listener binds — that is the readiness contract.
- `--pairing-address` is only the advertised address (not the bind address);
  wildcard/`127.0.0.1` values must not be advertised.
- `orca serve` never self-updates; upgrades = replace AppImage + restart.
  State lives in `/home/orca/.config/` and survives binary replacement.

## Goal
`tasks/setup-orca.sh` provisions a headless Orca remote server
(`orca serve` under systemd) on an Ubuntu/Debian host, idempotently, and
optionally also makes the desktop AppImage available.

## Behavior

### Env vars (all optional, shown in `--help`)
| Var | Default | Purpose |
|-----|---------|---------|
| `ORCA_VERSION` | `latest` | Release tag (e.g. `v1.4.218`) or `latest` |
| `ORCA_PORT` | `6768` | `serve` listen port |
| `ORCA_PAIRING_ADDRESS` | *(empty)* | Advertised client address (Tailscale IP/hostname, LAN IP, or full `https://…/runtime` URL). Empty = omit flag (local-only) |
| `ORCA_MOBILE_PAIRING` | `false` | Add `--mobile-pairing` (QR + link for the mobile app) |
| `ORCA_DESKTOP` | `false` | Also install a desktop AppImage launcher (`/usr/local/bin/orca-desktop` → AppImage) for GUI use |
| `ORCA_SERVICE_USER` | `orca` | System user running the service |
| `ORCA_INSTALL_DIR` | `/opt/orca` | AppImage install dir |
| `ORCA_HEALTH_TIMEOUT` | `120` | Seconds to wait for the ready JSON |

### Flags
- `--force` — re-download the AppImage even if the requested version is installed
- `--help`

### Steps (idempotent, converge by default)
1. **Preflight**: `systemctl`, `sudo`, `curl`, `apt-get`, `jq`, `file`,
   `envsubst` (fail with install hint otherwise).
2. **Apt dependencies**: `xvfb`, `libfuse2`, `git`, `zlib1g-dev`, `file`,
   `jq`, `ca-certificates` plus the Electron shared libraries (probe the
   package index *after* `apt-get update`). Package names with the `t64` suffix
   (64-bit `time_t` transition) are probed via `apt-cache show
   libgtk-3-0t64` — t64 list on Ubuntu ≥24.04 / Debian ≥13, unsuffixed
   otherwise. (Per the official guide's release matrix.)
3. **Service user**: `useradd --system --create-home --shell /usr/sbin/nologin
   orca` (skip if exists) + `loginctl enable-linger orca` (terminal-daemon
   scope preservation).
4. **AppImage**: resolve asset by `uname -m`; download
   `https://github.com/stablyai/orca/releases/[download/<tag>/]latest/download/<asset>`
   to a temp file, verify with `file` (ELF executable + arch), then
   `sudo install -m 755 -o root -g root` to `$INSTALL_DIR/orca-linux.AppImage.new`
   and `mv` into place (no in-place overwrite of the FUSE binary). The release
   tag is recorded in `/opt/orca/VERSION`. Skip download when the installed
   `VERSION` matches `ORCA_VERSION` (or a binary exists for `latest`) and
   `--force` is not set.
5. **Systemd unit**: render `templates/orca/orca-serve.service` (envsubst with
   an explicit var list: user, home, AppImage path, port, serve args) as the
   invoking user into a `mktemp` file; if the rendered unit differs from the
   installed one → `sudo install -m 644` + `daemon-reload` + restart; if
   identical → no restart. `ExecStart` always includes `--json` (supervisor
   readiness contract).
6. **Enable + (re)start**: `reset-failed` (clears a tripped start limit),
   `enable`, `restart`.
7. **Health verification (bounded)**: poll until `ORCA_HEALTH_TIMEOUT` for
   `systemctl is-active orca-serve == active` **and** the unit journal
   (since restart) containing an `orca_server_ready` line with
   `schemaVersion == 1` (jq parse). Failure → non-zero exit with
   `journalctl` / missing-library hints.
8. **Firewall**: if UFW is active → `ufw_add_rule $ORCA_PORT tcp`
   (convention: each service opens its own port).
9. **Desktop opt-in**: if `ORCA_DESKTOP=true` → symlink
   `/usr/local/bin/orca-desktop` to the AppImage + warn that only one host
   mode (desktop app **or** `orca serve`) may run per machine.
10. **Summary**: installed version, bound/advertised endpoints and the
    pairing URL (parsed from the ready JSON in the journal), client pairing
    steps, and a headless `account add` hint.

## Files
- `tasks/setup-orca.sh` (new)
- `templates/orca/orca-serve.service` (new)
- `machine-config.yml.example` (new `setup-orca` entry)
- `AUTOMATIONS.md` (new entry under AI & LLM Services)

## Out of scope (documented in `--help`/summary instead)
- Upgrades/rollback (official guide has a dedicated, carefully versioned
  procedure — out of scope for a setup script; `ORCA_VERSION` re-run with
  `--force` covers simple upgrades)
- Traefik integration, Docker mode (Orca ships no official container image;
  the official headless guide explicitly documents systemd as the service path)
- Agent account registration (`orca account add`) — interactive (browser
  login), so it stays a manual step

## Success criteria
- [ ] `shellcheck tasks/setup-orca.sh` clean; `yamllint` on edited YAML clean
- [ ] `--help` lists all env vars/flags
- [ ] First run on a clean Ubuntu 24.04 host: installs deps, user, AppImage,
      service; ready JSON logged; script exits 0
- [ ] Re-run: no re-download, no service restart when nothing changed; exits 0
- [ ] Changed `ORCA_PORT`/`ORCA_PAIRING_ADDRESS` in config: re-run updates the
      unit and restarts, healthy again
- [ ] Health timeout → non-zero exit with diagnostics
