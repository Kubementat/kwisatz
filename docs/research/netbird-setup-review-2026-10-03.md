# NetBird setup review and research — 2026-10-03

Scope: `tasks/setup-netbird.sh`, `templates/netbird/*`, checked against the
current upstream sources. Complements `docs/research/netbird-research.md`
(architecture, routing peers, bootstrap sequence), which is still accurate
except where noted in section 3.

Method: static review plus upstream source reading. Nothing was deployed; the
findings marked "source-verified" were confirmed in upstream code, the rest
are labelled.

## 1. Verdict

The Traefik mode is architecturally current: combined `netbird-server`
container, embedded IdP, embedded STUN, and router labels identical to the
official "existing Traefik" template. It is not yet state of the art in four
respects: image pins are three minor releases behind, two config keys upstream
added since August are missing, the Traefik entrypoint it relies on has a 60 s
read timeout, and the re-run/upgrade path does not follow the repo's own
converge policy.

The direct mode is not a usable deployment for remote peers and is exposed
more widely than it should be.

`shellcheck` and `yamllint` pass on the script and both compose templates.

## 1b. Addendum (2026-10-21, deployed stack) — two enrollment blockers, verified live

L1 turned out to be High, not Low, and a second bug was hiding under it:

**H6. `exposedAddress` without `:443` kills the Signal connection for every
peer.** Peers derive the Signal (and relay) endpoint from `exposedAddress`. With
`https://<domain>` the dial string is host-only and gRPC rejects it:
`dial tcp: address <domain>: missing port in address`, then `create connection:
dial context: context deadline exceeded`. `netbird status` inside the client shows
the split that gives it away: `management: …:443 Connected`, `signal: …
(omitting the port) Disconnected`, `Relays: 0/0`. Symptoms: the peer logins once
(its record appears in the dashboard), `peer_status_connected` stays `0` forever,
and a routing peer routes nothing. Fixed by rendering
`exposedAddress: "${NETBIRD_MGMT_URL}:443"` — after that change `Signal:
Connected` and `Relays: 2/2` immediately, `peer_status_connected` flipped to `1`.

**H7. The routing-peer client never registers.** `templates/netbird/
docker-compose.traefik.yml` configured the client with `NB_SETUP_KEY` (ignored —
verified on 0.77.1 *and* `latest`: the entrypoint runs a bare `netbird up` and the
client binary has no such env mapping — this particular claim is corrected below)
and a non-existent `NB_MGMT_URL`. The
consequence is worse than doing nothing: `netbird up` without flags starts an
interactive OAuth **device flow** and polls the IdP for 5 minutes, so every start
of an unregistered peer spams the management's device endpoint and the peer never
joins. `NB_MANAGEMENT_URL` *is* honoured (unlike the `NB_MGMT_URL` the template used before) but a keyless
`up` still does not enroll. Fixed by overriding entrypoint/command to run
`netbird service run`, wait for `netbird status --check live`, then
`netbird up --setup-key "$NETBIRD_SETUP_KEY"`, and by erroring out instead of
starting a device flow when no key is available. `netbird status --check ready`
(NonZero on NeedsLogin / LoginFailed / SessionExpired) is the gate the task script
now uses — `wait_for_healthy` alone only proves "running" (M5).

**Correction 2026-10-21** (local testing on 0.77.1): the claim that `NB_SETUP_KEY` is
ignored is wrong. The client does read it — a non-UUID value is rejected with
`invalid setup-key ... invalid UUID length: 12` and an unknown one with
`setup key is invalid`, both before any SSO attempt; only an *empty or absent* variable
leaves `netbird up` in the interactive device flow. The finding's remedy still stands,
because the stack passes the key as `NETBIRD_SETUP_KEY`, which is not a client variable
at all — so `netbird up --setup-key "$NETBIRD_SETUP_KEY"` remains required for
enrollment on this deployment.

Also verified: `netbird up --foreground-mode` does **not** start the daemon (no
`/var/run/netbird.sock`), so `netbird service run &` must stay in the container's
cmd — the 3-line `entrypoint: [netbird]` + `up -F` shortcut does not work.

## 2. Findings

### High

**H1. Script fails for a non-root user when `/srv` is not user-writable.**
`mkdir -p … || sudo mkdir -p` leaves `/srv/netbird` root-owned; `.env` is then
installed via `sudo cp` + `sudo chmod 600`; the following `grep` on `.env`
(line 295) runs unprivileged and aborts with "Could not read
NETBIRD_AUTH_SECRET". `docker compose -f` would fail on the same file next.
The script only works under `sudo` (which the header and `--help` advertise),
contradicting AGENTS.md "non root user executes, sudo internally".
`setup-openwebui.sh` shows the repo pattern: `sudo mkdir -p` + `sudo chown
"${USER}:${USER}"`.

**H2. Upgrades do not persist, and a later run silently downgrades.**
`.env` and `docker-compose.yml` are write-once. `NETBIRD_SERVER_TAG=0.80.0
./setup-netbird.sh` upgrades for that run only (process env beats `.env`),
but `.env` keeps the old tag. The next plain re-run, or any manual
`docker compose up -d`, recreates the containers on the old tag against a
database already migrated by the newer version. Bumping the script defaults
has no effect on existing installs for the same reason. The documented
workaround ("delete `.env`") also deletes the generated secrets from `.env`
(they survive in `config.yaml`, but the script would generate new ones into
`.env` that no longer match).

**H3. Re-run behaviour contradicts the converge policy.**
`specification/project/conventions.md` requires re-rendering config from
templates while reusing secrets. The script freezes all three generated files
and only warns about drift. Consequences: template fixes (such as M1/M2 below)
never reach an existing install, and `NETBIRD_ADMIN_EMAIL/PASSWORD` on a
re-run are ignored while the summary still says "log in with the bootstrap
owner".

**H4. Direct mode cannot serve remote peers (source-verified).**
With the default empty `NETBIRD_DOMAIN`, `exposedAddress` is
`http://localhost:8081`. `combined/cmd/config.go` derives everything handed to
peers from it: relay `rel://localhost:8081`, signal `http://localhost:8081`,
STUN `stun:localhost:3478`, DNS domain `localhost`. Only a client on the same
host can connect. With `NETBIRD_DOMAIN` set to a LAN name or IP, dashboard
login breaks instead: the dashboard sends `redirect_uri =
window.location.origin + /nb-auth` (port 8080, `src/auth/OIDCProvider.tsx`),
while the script registers `${NETBIRD_MGMT_URL}/nb-auth` (port 8081). On
`localhost` this is masked because the IdP client is public and Dex accepts
any `http://localhost` redirect (Dex rule recalled from memory, not re-read).
Browsers also refuse the PKCE crypto over plain HTTP on non-localhost origins
(general browser behaviour, not NetBird-specific evidence).

**H5. Direct mode publishes plaintext management on all interfaces.**
Ports 8080/8081 bind to `0.0.0.0` and UFW rules open them to the world.
Upstream binds to `127.0.0.1` whenever a proxy is on the same host, and never
ships a no-TLS topology. Recommendation: either drop direct mode or redefine
it as "behind another proxy on this host" — one public URL, `127.0.0.1` binds,
no UFW rules for 8080/8081.

### Medium

**M1. Traefik entrypoint read timeout (cross-script, `setup-traefik.sh`).**
The repo runs `traefik:v3` with no `respondingTimeouts`. Traefik v3 defaults
`readTimeout` to 60 s, which terminates bidirectional gRPC streams at exactly
60 s (traefik/traefik#10652). NetBird's signal stream is bidirectional;
clients reconnect, so the symptom is churn, not an outage. NetBird's bundled
Traefik sets `readTimeout`, `writeTimeout` and `idleTimeout` to 0 on
`websecure` "for long-lived gRPC streams". This is an entrypoint-wide setting
and affects every service behind that Traefik, so it is a decision for
`setup-traefik.sh`, not a netbird-only change. Not reproduced here.

**M2. `reverseProxy.trustedHTTPProxies` / `trustedPeers` missing.**
Added to the upstream installer in September 2026. Upgrade docs: without it,
management up to v0.79 records the proxy's address as the client IP; after
v0.79 it accepts forwarded client-IP headers from any source and logs a
spoofing warning. In Traefik mode the server has no published TCP port, so
only containers on the `proxy` network can reach it, which limits the
exposure. Fix: set both to the `proxy` network CIDR
(`docker network inspect proxy`).

**M3. Image pins are behind.** Defaults `0.77.1` / `v2.91.1`; current stable
is `0.80.0` (2026-10-01) and dashboard `v2.94.0` (2026-09-28). All three
pinned tags exist on Docker Hub. None of the published GitHub security
advisories affects 0.77.1 (highest patched version listed is 0.76.1).
Pinning itself is right; upstream defaults to `latest`.

**M4. Secrets are rendered into `config.yaml`.** This breaks the AGENTS.md
rule, but upstream forces it: `config.go` reads no environment overrides for
`authSecret`, `store.encryptionKey` or `auth.owner.password`. Worth recording
as a documented exception. Two avoidable parts remain:
- the owner password is written with `printf '"%s"'`; a password containing
  `"` or `\` produces invalid YAML, and it stays in the file in clear text
  after first start. `NB_SETUP_PAT_ENABLED=true` + `POST /api/setup` avoids
  both.
- `cp` then `chmod 600` leaves the file briefly at the umask default; the repo
  helpers `env_file_write` / `sudo install -m 600` do this atomically, and
  `env_file_get` replaces the hand-rolled `grep | head | cut`.

**M5. Health gate is weaker than it looks.** Neither image defines a
healthcheck, so `wait_for_healthy` only proves "running". The HTTP readiness
poll that follows only warns on failure, and the summary then prints "setup
complete". Making the direct-mode poll fatal, and probing the server over the
docker network in Traefik mode, would meet the convention.

### Low

- **L1.** `exposedAddress` is rendered as `https://domain` in Traefik mode;
  docs and upstream use `https://domain:443`. The parser accepts the short
  form and hands peers `rels://domain` and `https://domain` without a port.
  Probably works via default ports, but untested here; adding `:443` removes
  the question.
- **L2.** `auth.sessionCookieEncryptionKey` (new upstream, `openssl rand
  -base64 32`) is not set.
- **L3.** No `logging:` limits on the containers; upstream sets `json-file`
  with `max-size`.
- **L4.** The bound-port pre-check for STUN runs only in direct mode although
  STUN is published in both.
- **L5.** Header and `--help` show `sudo ./tasks/setup-netbird.sh`.
- **L6.** Routing peer enables IPv4 forwarding only; add
  `net.ipv6.conf.all.forwarding=1` if IPv6 LANs are to be routed.
- **L7.** Docker-published ports bypass UFW, so the UFW rules for 3478/udp
  (and 8080/8081) document intent rather than control access.

### Confirmed correct

- Combined `netbirdio/netbird-server` + `netbirdio/dashboard`; legacy
  five-container layout avoided.
- Traefik labels match the official template: three gRPC prefixes including
  `management.ProxyService`, h2c service, backend router for `/relay`,
  `/ws-proxy/`, `/api`, `/oauth2`, priorities 100 / 1.
- Dashboard environment matches upstream `dashboard.env` key for key.
- STUN published directly on UDP; `listenAddress: ":80"` behind the proxy.
- Secret formats match upstream (base64 32-byte store key with padding).
- `config.yaml` mounted read-only, mode 600; telemetry disabled.
- Client container capabilities, `/dev/net/tun` and host networking match the
  official Docker client compose.
- Secrets are read back from `.env` before use and never regenerated.

## 3. Research: setting up NetBird properly (state October 2026)

**Topology.** One public hostname, TLS on 443, plus UDP 3478 for STUN
published directly from the container. Everything else (dashboard, REST,
gRPC, WebSocket relay, OIDC) shares the one HTTPS origin. Minimum 1 CPU / 2 GB.

**Reverse proxy requirements.** HTTP/2 with h2c to the backend for the gRPC
prefixes, WebSocket upgrade for `/relay*` and `/ws-proxy/*`, and no read/idle
timeouts on the entrypoint (Nginx examples use `1d`; bundled Traefik uses 0).
Bind backend ports to `127.0.0.1` or publish none.

**`config.yaml` as upstream renders it today** (differences to this repo's
template marked):

```yaml
server:
  listenAddress: ":80"
  exposedAddress: "https://netbird.example.com:443"   # port included
  stunPorts: [3478]
  metricsPort: 9090
  healthcheckAddress: ":9000"
  authSecret: "<openssl rand -base64 32, padding stripped>"
  dataDir: "/var/lib/netbird"
  auth:
    issuer: "https://netbird.example.com/oauth2"
    signKeyRefreshEnabled: true
    sessionCookieEncryptionKey: "<openssl rand -base64 32>"   # new
    dashboardRedirectURIs: [".../nb-auth", ".../nb-silent-auth"]
    cliRedirectURIs: ["http://localhost:53000/"]
  reverseProxy:                                               # new
    trustedHTTPProxies: ["<proxy address or network CIDR>"]
    trustedPeers: ["<proxy address or network CIDR>"]
  store:
    engine: "sqlite"
    encryptionKey: "<openssl rand -base64 32>"
```

**First account.** Three options: the `/setup` page (first visitor becomes
owner, so do it immediately), `auth.owner` in `config.yaml`, or
`NB_SETUP_PAT_ENABLED=true` with `POST /api/setup`, which also returns a
personal access token for scripting groups, setup keys and policies. Remove
the variable afterwards. Enable TOTP for local users.

**Hardening.** `NB_API_RATE_LIMITING_ENABLED` (+ `_RPM`, `_BURST`) on the
server; keep `:9000`, `:9090` and `NB_PPROF_ADDR` off public interfaces;
optional CrowdSec only applies to NetBird's own reverse-proxy feature.

**Upgrades.** Back up first, read both release pages, then
`docker compose pull` and `up -d --force-recreate`. Since v0.76.1 the optional
`reverse-proxy` container must not be newer than management. Installs created
before September 2026 need the `reverseProxy` block added by hand.

**Backup.** `docker compose stop`, copy `docker-compose.yml`, `config.yaml`
and the dashboard env, and `docker compose cp -a
netbird-server:/var/lib/netbird/ backup/`. The archive contains the store
encryption key; losing the key invalidates setup keys and API tokens.

**Routing the LAN.** Use Networks (resource CIDR + routing peer + access
policy), not legacy Routes, which upstream now reserves for exit nodes.
Masquerade is on by default, so the LAN needs no return route.

## 4. Sources

- https://docs.netbird.io/selfhosted/selfhosted-quickstart
- https://docs.netbird.io/selfhosted/external-reverse-proxy
- https://docs.netbird.io/selfhosted/maintenance/configuration-files
- https://docs.netbird.io/selfhosted/maintenance/upgrade
- https://docs.netbird.io/selfhosted/maintenance/backup
- https://docs.netbird.io/selfhosted/environment-variables
- https://github.com/netbirdio/netbird/blob/main/infrastructure_files/getting-started.sh
- https://github.com/netbirdio/netbird/blob/main/combined/config.yaml.example
- https://github.com/netbirdio/netbird/blob/main/combined/cmd/config.go
- https://github.com/netbirdio/netbird/blob/main/management/server/idp/embedded.go
- https://github.com/netbirdio/dashboard/blob/main/src/auth/OIDCProvider.tsx
- https://github.com/netbirdio/netbird/releases (v0.80.0, 2026-10-01)
- https://github.com/netbirdio/dashboard/releases (v2.94.0, 2026-09-28)
- https://github.com/netbirdio/netbird/security/advisories
- https://github.com/traefik/traefik/issues/10652
