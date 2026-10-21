# Self-Hosted NetBird for a Homelab — Research Document

Research date: 2026 (verified against official NetBird docs, July/August 2026 updates)
Goal: self-host NetBird on the Docker + Traefik host `evobox` so the user can connect to the homelab network from anywhere, including devices that have no NetBird client (via a routing peer + subnet route).

Sources verified:
- Prior research doc: `/home/verfeinerer/vault/research/netbird-selfhosted-setup-guide.md` (all links followed; current status noted below)
- Official docs: https://docs.netbird.io (self-hosted quickstart, advanced guide, configuration-files reference, external-reverse-proxy, environment-variables, automated-setup, backup, upgrade, networks/routes, setup keys, docker client, ports & firewalls, homelab use case)
- Source: https://github.com/netbirdio/netbird (`combined/config.yaml.example`, `combined/Dockerfile`, `combined/cmd/config.go`), https://github.com/netbirdio/docs (raw MDX pages)
- Client images/docs: https://hub.docker.com/r/netbirdio/netbird, https://docs.netbird.io/get-started/install/docker

> Note: the canonical GitHub org is **netbirdio** (the task prompt said `netbirdco` — that is incorrect; the repo is `github.com/netbirdio/netbird`).

---

## 1. NetBird Architecture

NetBird is an open-source (BSD-3), WireGuard-based mesh VPN. Peers form an overlay network in the CGNAT range `100.64.0.0/10` (default) with end-to-end WireGuard encryption. Connectivity negotiation uses ICE/STUN for NAT traversal; no inbound ports are ever needed on clients.

### Components

| Component | Role |
|---|---|
| **Management server** | Control plane: accounts/users (via embedded or external OIDC IdP), peers, groups, access policies, Networks/Routes, DNS config, setup keys, API tokens, activity log. Exposes a REST API (`/api/*`) and a gRPC API (`/management.ManagementService/*`). |
| **Signal server** | Coordinates the initial connection handshake between peers (exchanges WireGuard public keys and endpoint info, like STUN "hole-punch" coordination). gRPC (`/signalexchange.SignalExchange/*`) plus WebSocket (`/ws-proxy/signal/*`). |
| **Relay server (DERP-based)** | Fallback data path for peers that cannot establish a direct P2P WireGuard connection (symmetric NAT / firewalls). The relay is DERP-style (the NetBird relay implementation in `relay/` of the repo). Traffic flows over a **WebSocket** at `/relay/*` (and, for modern clients, also QUIC/UDP 443 in the NetBird Cloud; self-hosted relay uses the WebSocket path on the same HTTP port). Relay credentials are time-limited and protected by a shared `authSecret`. |
| **STUN server** | Lets clients discover their public IP/UDP reachability for NAT traversal. Uses **UDP**, so it can *not* be proxied through an HTTP/TCP reverse proxy. Since the v0.65.0 combined container, STUN is **embedded in the relay/server container** (Coturn is legacy only). |
| **Dashboard** | Web UI (Next.js) served by an embedded nginx. Talks to the management REST API from the browser, authenticates via the embedded IdP (Dex) OIDC endpoints. |
| **Embedded IdP (Dex)** | Built-in OAuth2/OIDC identity provider at `/oauth2/*` — local user management with no external IdP required. Supports local users, MFA (TOTP), and adding external OIDC providers (Google, Entra ID, Okta, Keycloak, etc.). |

### Combined container (v0.65.0+) — the current architecture

Since v0.65.0, new self-hosted deployments use **one combined server container** `netbirdio/netbird-server` that runs management + signal + relay + embedded STUN + embedded IdP. It is configured by a single `config.yaml` (replacing the old `management.json` + `relay.env` + separate `signal`/`relay`/`coturn` containers). Management listens on **one HTTP port** (default `:80` inside the container when behind a proxy) that serves all of: REST API, gRPC (h2c), WebSockets (signal/relay/management), and OIDC.

The old multi-container setup (management :33073 gRPC, signal :10000, relay :33080, coturn :3478 + 49152-65535 UDP) still works but is **legacy**; docs now mark the advanced multi-container guide as older. There is a migration guide (`/selfhosted/migration/combined-container`).

**Key consequence for us:** behind a reverse proxy only three things are exposed:
- TCP 443 (and 80 for cert validation) — dashboard, API, gRPC, WebSockets, OIDC — all on **one backend port**
- UDP 3478 — STUN, direct from the container, bypassing the proxy

### "Stable connection / reverse connection" behavior

- All control-plane and data-path connections to the server are **initiated by the client (reverse direction from the server's perspective)**: clients dial out to management (gRPC/REST), to signal (gRPC + WebSocket), and to the relay (WebSocket at `/relay/...`). Therefore the server only needs inbound 443 + 3478/UDP; clients never need inbound ports.
- These connections are **long-lived** (gRPC streams and WebSockets for signal/relay, management keep-alives). Any reverse proxy in the path must:
  - support HTTP/2 and gRPC (`h2c` to the backend, since the combined container speaks cleartext HTTP/2 on its internal port when TLS is terminated upstream),
  - pass WebSocket `Upgrade` headers,
  - have **no read/idle timeouts** (the built-in Traefik in NetBird's own compose sets `readTimeout=0` on the websecure entrypoint explicitly "required for long-lived gRPC and WebSocket connections"),
  - **disable response buffering** for the WebSocket/gRPC routes (Nginx: `proxy_buffering off` + high `proxy_read_timeout`; Traefik handles WebSockets fine without extra config).
- WireGuard data between peers is direct P2P where possible; only when hole-punching fails does traffic go through the relay. Relay traffic is end-to-end encrypted WireGuard packets tunneled in the WebSocket, so the relay cannot read contents.

---

## 2. Official Docker Images, Privileges, Ports, Volumes

### Images

| Image | Purpose | Notes |
|---|---|---|
| `netbirdio/netbird-server:<tag>` | Combined server (management + signal + relay + STUN + embedded Dex IdP) | Base `ubuntu:24.04`; `ENTRYPOINT ["/go/bin/netbird-server"]`, `CMD ["--config", "/etc/netbird/config.yaml"]` (verified in `combined/Dockerfile`). No special privileges/capabilities needed; runs without root capabilities (it is a pure network service — no TUN device involved on the server side). Config expected at `/etc/netbird/config.yaml`. |
| `netbirdio/dashboard:<tag>` | Web dashboard | Embedded nginx serving the UI on **port 80** inside the container. No privileges needed. |
| `netbirdio/netbird:<tag>` | **Client** (agent) | For Linux servers/routing peers. |
| `netbirdio/netbird:rootless-latest` | Rootless client image | gVisor netstack userspace WireGuard; no privileges, but mainly good for inbound access/routing peers, not general clients. |

Pin a version tag (e.g. a release like `v0.76.x`); `latest` works but complicates upgrades. Management/signal/relay share one version number; dashboard is versioned separately.

### Ports (combined setup, behind a reverse proxy)

| Service | Container port | Recommended host mapping | Protocol | Proxied? |
|---|---|---|---|---|
| Dashboard (nginx) | 80 | `127.0.0.1:8080:80` | TCP | Yes → Traefik |
| NetBird server (mgmt/signal/relay/IdP) | 80 | `127.0.0.1:8081:80` | TCP | Yes → Traefik |
| STUN (embedded) | 3478/udp | `3478:3478/udp` (0.0.0.0) | UDP | **No — must be directly published** |
| (host) Traefik | 80/443 | 80/443 | TCP | entrypoint |

Official docs: "Binding to `127.0.0.1` is recommended when your reverse proxy runs on the same host. This prevents direct access to the containers and ensures all traffic goes through the proxy."

Corrections vs. the prior doc / task framing:
- There is **no "management port 8080"** in the combined deployment. 8080/8081 are just the *host-side* ports the setup script chooses for dashboard (8080) and netbird-server (8081). Both map to container port 80.
- "DERP/WebSocket 443": the relay WebSocket lives at `https://<domain>/relay/...` on the normal HTTPS port — nothing special about 443 itself; it is the same consolidated 443 entrypoint. (NetBird Cloud relays also speak QUIC on UDP/443; the self-hosted combined relay provides the WebSocket transport on the main HTTP port.)
- Since v0.29, without a proxy the direct-exposure ports were 80, 443, 33073, 10000, 33080 + UDP 3478; the combined container collapses this to one internal port.

### Volumes

| Volume | Mount | Purpose |
|---|---|---|
| `netbird_data` | `/var/lib/netbird` | SQLite database (`store.db`), embedded IdP store (`idp.db`), activity events (`events.db`), encryption keys, GeoLite. **Back up this volume** — it is your entire installation state (accounts, peers, policies, keys). |
| bind-mount | `./config.yaml` → `/etc/netbird/config.yaml` | Server configuration (read-only mount fine). |
| (client) `netbird-client` | `/var/lib/netbird` | Client state on the routing-peer machine. |

---

## 3. Server Config File (`config.yaml`)

Full official example: https://github.com/netbirdio/netbird/blob/main/combined/config.yaml.example

Key fields (all under a top-level `server:` key):

| Field | Meaning |
|---|---|
| `listenAddress` | Internal listen address, e.g. `:80` behind a proxy (the example uses `:443` for standalone). TLS is handled by the reverse proxy in our setup, so plaintext `:80`. |
| `exposedAddress` | **Public URL handed to every peer**, e.g. `https://netbird.example.com:443`. Must be reachable by all clients; this is the "join URL" base. |
| `stunPorts` | UDP ports for the embedded STUN server, default `[3478]`. Must be published + firewalled. |
| `authSecret` | Shared secret for relay authentication (auto-generated by the setup script). Required when the local relay is used. |
| `dataDir` | Default `/var/lib/netbird/`. |
| `metricsPort` / `healthcheckAddress` | Prometheus metrics (default 9090) and `/health` (default :9000). Not needed publicly. |
| `tls.certFile/keyFile/letsencrypt` | Optional server-side TLS; leave disabled behind Traefik. |
| `auth.issuer` | OIDC issuer URL, e.g. `https://netbird.example.com/oauth2` (embedded IdP). |
| `auth.localAuthDisabled` | Set `true` to force external IdP only (default `false`). |
| `auth.signKeyRefreshEnabled` | Rotate IdP signing keys; recommended `true`. |
| `auth.dashboardRedirectURIs` | e.g. `https://netbird.example.com/nb-auth`, `.../nb-silent-auth`. |
| `auth.cliRedirectURIs` | default `["http://localhost:53000/"]` (CLI login). |
| `auth.grantTypes` | Optional restriction (e.g. drop `device_code`). |
| `auth.owner.email` / `auth.owner.password` | **Bootstrap admin user** created on first startup when both are set. |
| `store.engine` / `store.dsn` | `sqlite` (default), `postgres`, or `mysql`. |
| `store.encryptionKey` | Base64 32-byte key encrypting setup keys/API tokens at rest. Auto-generated by the script. **Back this up with the volume** — losing it invalidates all setup keys and API tokens. |
| `activityStore.*`, `authStore.*` | Optional separate stores (default: SQLite files in dataDir). |
| `stuns` / `relays` / `signalUri` | External service overrides: setting `stuns`/`relays`/`signalUri` disables the corresponding embedded service and uses external ones (e.g. `rels://relay.example.com:443`, `stun:stun.example.com:3478`). |
| `reverseProxy.trustedHTTPProxies` | CIDRs of trusted fronting proxies (X-Real-Ip trust). |
| `disableAnonymousMetrics` | Opt out of anonymous usage metrics. |

### Admin credentials & keys
- **Admin user**: created either via the browser `https://<domain>/setup` page (only available while no users exist), via `server.auth.owner.email/password` in `config.yaml`, or via the **setup API** (`POST /api/setup`, see below).
- **Automated setup (ideal for a builder agent)**: set env `NB_SETUP_PAT_ENABLED=true` on the `netbird-server` container, then
  ```bash
  curl -fsS -X POST "https://netbird.example.com/api/setup" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","name":"Admin","password":"<long-random>",
         "create_pat":true,"pat_expire_in":7}'
  ```
  Response contains a one-time plaintext **Personal Access Token** (`nbp_...`) usable as `Authorization: Token <PAT>` against the management REST API — lets the builder create users, groups, setup keys, policies, and Networks programmatically. Endpoint is unauthenticated only while setup is pending; disable the env var afterwards.
- **Setup keys** (peer enrollment, a.k.a. join/invite keys): created in Dashboard → Settings → Setup Keys or `Peers → Add Peer → Generate Key` (or via API). Types: one-off (single use) or reusable (with usage limit), optional expiration (default 7 days), optional ephemeral peers, optional auto-assign groups. Revoking a key does not disconnect already-enrolled peers.

---

## 4. How Clients Join & How to Route the Whole Homelab Subnet

### Joining (invite / join key)

Two ways for a device to join:

1. **Interactive (default)**: install the client, point it at the management URL (`netbird up --management-url https://netbird.example.com`, or set it in the desktop/mobile app settings), which prints a **login URL** — the user opens it in a browser and authenticates against the dashboard (embedded IdP). The device registers as a peer and gets a stable IP in `100.64.0.0/10`.
2. **Unattended (setup key / invite key)**: create a setup key, then:
   - CLI: `netbird up --setup-key <KEY>`
   - Docker client: `-e NB_SETUP_KEY=<KEY>`
   - Or pre-provision the full client config file ("Bootstrap peers via config file" for IaC).

### Docker client (for the homelab routing peer / other Linux servers)

Official compose (docs.netbird.io/get-started/install/docker):

```yaml
services:
  netbird-client:
    container_name: netbird-client
    hostname: <HOSTNAME>
    cap_add: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
    devices:
      - /dev/net/tun          # needed for userspace mode / missing kernel module
    network_mode: host
    environment:
      - NB_SETUP_KEY=<SETUP KEY>
      # - NB_MANAGEMENT_URL=https://netbird.example.com   # management URL
      #   (NB_MGMT_URL does not exist — the client then stays on api.netbird.io)
    volumes:
      - netbird-client:/var/lib/netbird
    image: netbirdio/netbird:latest
volumes:
  netbird-client:
```

`network_mode: host` on the routing peer is the practical choice (the `wt0` WireGuard interface then lives on the host, so host-level IP forwarding/NAT covers the routing).

### Routing the whole LAN (VPN-to-Site)

- Install the client on an **always-on machine on the homelab LAN** (e.g. `evobox` itself, or the router — NetBird even has a MikroTik guide). That peer becomes a **routing peer**.
- On the routing peer enable kernel forwarding:
  ```bash
  sudo sysctl -w net.ipv4.ip_forward=1
  echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-netbird.conf
  # IPv6: net.ipv6.conf.all.forwarding=1
  ```
- In the dashboard create the route. **Modern model (recommended)**: **Networks** (Dashboard → Networks): create a Network, add **Resources** (CIDR e.g. `192.168.1.0/24`, single hosts `/32`, or domains), assign the **Routing Peer**, and add an **Access Policy** (source group → resource/group; Zero Trust by default — a resource with no policy is unreachable). Multiple routing peers give HA.
  **Legacy model**: **Routes** (deprecated except for exit nodes): identifier + CIDR range + routing peer/group + **distribution groups** (which clients receive the route) + **masquerade** flag.
- **Masquerade (NAT)**: on by default — the routing peer SNATs forwarded traffic to its LAN-side IP, so the homelab LAN needs no return route to `100.64.0.0/10`. Disable it only if you need source-IP visibility (then you must add a return route for `100.64.0.0/10` → routing peer on the LAN).
- **DNS caveat**: NetBird Magic DNS resolves NetBird peer names only. To resolve LAN hostnames, add your home router's DNS (e.g. Pi-hole) as a **custom/internal DNS server** in NetBird DNS settings; otherwise use IPs.
- The routing peer's bandwidth/CPU is the bottleneck for LAN traffic.
- Access policies: verify that the client groups (e.g. "All" or a personal group) have a policy allowing the LAN resource. In legacy Routes without ACL groups, routed networks are open to all distributed peers.

---

## 5. Running the NetBird Server Behind an Existing Traefik (the evobox case)

Requirements (official docs, "External Reverse Proxy" page, combined-container section):
- Traefik must terminate TLS and support **HTTP/2 + gRPC** to the backend (`h2c`), and WebSocket upgrades.
- The proxy must route these paths to the **single** `netbird-server:80` backend:

| Path | Protocol | Notes |
|---|---|---|
| `/relay*` | WebSocket | relay traffic |
| `/ws-proxy/signal*` | WebSocket | signal fallback |
| `/ws-proxy/management*` | WebSocket | management fallback |
| `/signalexchange.SignalExchange/*` | gRPC over h2c | |
| `/management.ManagementService/*` | gRPC over h2c | |
| `/management.ProxyService/*` | gRPC over h2c | only if using the NetBird Reverse Proxy feature |
| `/api/*` | HTTP | REST API |
| `/oauth2/*` | HTTP | embedded IdP (discovery, JWKS, token, device-code) |
| `/*` (catch-all) | HTTP | → `dashboard:80` |

- **UDP 3478 (STUN) cannot be proxied** — publish it directly from the container and allow it in the firewall. (If STUN is unreachable, hole-punching degrades and more traffic is relayed; connections still work via relay.)
- Everything else goes through port 443 (and 80 for ACME HTTP-01 validation if the existing Traefik issues certs).
- **Recommended port mapping strategy** (docs-verbatim approach): bind the dashboard and server containers to `127.0.0.1:8080` / `127.0.0.1:8081` so nothing bypasses Traefik; publish only `3478:3478/udp` on the external interface. In our case Traefik is on the same Docker network, so the containers can instead be label-discovered with **no published ports at all** for TCP.
- **WebSocket/gRPC buffering & timeout caveats**:
  - Traefik entrypoint must allow long-lived connections: built-in NetBird Traefik uses `--entryPoints.websecure.readTimeout=0` (and `writeTimeout=0`). On an *existing* Traefik, ensure your websecure entrypoint has no aggressive `readTimeout`/`idleTimeout` defaults (Traefik defaults are generous — no explicit timeout — but verify if you had custom timeouts).
  - Traefik needs **two service definitions** for the combined server: `netbird-server` (http scheme) for WebSockets/REST/OIDC and `netbird-server-h2c` with `scheme=h2c` for the gRPC paths (Traefik won't negotiate h2c unless told).
  - On Nginx/Caddy equivalents you additionally need `proxy_buffering off`, WebSocket `Upgrade`/`Connection` header pass-through, and high read/send timeouts — Traefik does not have a "buffering" knob; it is fine as long as timeouts don't cut idle WebSocket/gRPC streams.
  - Long-lived gRPC/WebSockets must not be truncated by `sendTimeout`/`flushInterval` misconfigurations; keep defaults or raise them.

### Official Traefik label template (existing Traefik, combined container)

From `external-reverse-proxy.mdx` (verbatim, with domain/entrypoint/certresolver placeholders):

```yaml
services:
  dashboard:
    image: netbirdio/dashboard:latest
    networks: [traefik-network]
    labels:
      - traefik.enable=true
      - traefik.http.routers.netbird-dashboard.rule=Host(`netbird.example.com`)
      - traefik.http.routers.netbird-dashboard.entrypoints=websecure
      - traefik.http.routers.netbird-dashboard.tls=true
      - traefik.http.routers.netbird-dashboard.tls.certresolver=letsencrypt
      - traefik.http.routers.netbird-dashboard.priority=1
      - traefik.http.services.netbird-dashboard.loadbalancer.server.port=80

  netbird-server:
    image: netbirdio/netbird-server:latest
    networks: [traefik-network]
    ports:
      - '3478:3478/udp'
    volumes:
      - netbird_data:/var/lib/netbird
      - ./config.yaml:/etc/netbird/config.yaml
    command: ["--config", "/etc/netbird/config.yaml"]
    labels:
      - traefik.enable=true
      # gRPC router (needs h2c backend for HTTP/2 cleartext)
      - traefik.http.routers.netbird-grpc.rule=Host(`netbird.example.com`) && (PathPrefix(`/signalexchange.SignalExchange/`) || PathPrefix(`/management.ManagementService/`) || PathPrefix(`/management.ProxyService/`))
      - traefik.http.routers.netbird-grpc.entrypoints=websecure
      - traefik.http.routers.netbird-grpc.tls=true
      - traefik.http.routers.netbird-grpc.tls.certresolver=letsencrypt
      - traefik.http.routers.netbird-grpc.service=netbird-server-h2c
      - traefik.http.routers.netbird-grpc.priority=100
      # Backend router (relay, WebSocket, API, OAuth2)
      - traefik.http.routers.netbird-backend.rule=Host(`netbird.example.com`) && (PathPrefix(`/relay`) || PathPrefix(`/ws-proxy/`) || PathPrefix(`/api`) || PathPrefix(`/oauth2`))
      - traefik.http.routers.netbird-backend.entrypoints=websecure
      - traefik.http.routers.netbird-backend.tls=true
      - traefik.http.routers.netbird-backend.tls.certresolver=letsencrypt
      - traefik.http.routers.netbird-backend.service=netbird-server
      - traefik.http.routers.netbird-backend.priority=100
      # Services
      - traefik.http.services.netbird-server.loadbalancer.server.port=80
      - traefik.http.services.netbird-server-h2c.loadbalancer.server.port=80
      - traefik.http.services.netbird-server-h2c.loadbalancer.server.scheme=h2c

networks:
  traefik-network:
    external: true

volumes:
  netbird_data:
```

Preconditions for "existing Traefik" mode (docs): Traefik already running with docker provider (`exposedByDefault=false` recommended), an HTTPS entrypoint (usually `websecure`), a working cert resolver (`letsencrypt`), domain resolving to the host, ports 80/443 reachable. Readiness check: `https://<domain>/oauth2/.well-known/openid-configuration` should return JSON through the proxy.

---

## 6. Security Considerations

- **TLS termination**: Terminate TLS at Traefik with a valid public cert (Let's Encrypt). Clients validate the certificate for the management URL — self-signed certs force client-side trust workarounds. Dashboard and API are reachable by anyone on the internet, so TLS + strong auth are the perimeter.
- **Auth**: Embedded Dex IdP gives local user/password auth (optionally TOTP MFA — enable local MFA). Recommendations: strong unique admin password, enable MFA, consider `server.auth.localAuthDisabled: true` + an external OIDC (Authentik/Keycloak) or at least restrict who can sign up. New self-hosted deployments start with *no* users; the `/setup` page is only live until the first account exists (good for a controlled first-login, but note anyone who hits it first becomes the owner).
- **Exposed surface**: with Traefik + `127.0.0.1` binds (or pure label routing), only 80/443 + 3478/udp are public. Keep `metricsPort` (9090), healthcheck (9000), and pprof (`NB_PPROF_ADDR`, unauthenticated!) private.
- **Rate limiting**: `NB_API_RATE_LIMITING_ENABLED=true` (+ `NB_API_RATE_LIMITING_RPM` / `_BURST`) on netbird-server to blunt credential brute-force. Optional CrowdSec IP-reputation blocking is available in the script-based deployment.
- **Secrets**: `server.authSecret` (relay auth), `server.store.encryptionKey` (encrypts setup keys/API tokens at rest), `auth.sessionCookieEncryptionKey` — generate random values, store in your compose file/backups securely. A leaked `authSecret` lets an attacker issue relay credentials.
- **Data**: back up the `netbird_data` volume + `config.yaml` (stop container, `docker compose cp`). Losing the volume or the encryption key loses all state.
- **Peers/zero-trust**: use groups + access policies rather than an open-all config; prefer Networks (Zero Trust by default) over legacy Routes (open by default without ACL groups).
- **STUN port**: 3478/udp public is a minor information channel (STUN reflect); consider rate-limiting at the firewall (e.g. ufw) if you worry about reflection abuse.
- **Firewall on the host**: ufw rules mirroring the mapping (allow 80/443/tcp, 3478/udp from anywhere; deny 8080/8081 publicly — not needed if bound to 127.0.0.1 or internal Docker network).

---

## 7. Recommended evobox Deployment (concrete artifacts)

### 7.1 docker-compose snippet (existing Traefik, external network `proxy`)

Assumes evobox's existing Traefik: Docker network name `<traefik-network>` (e.g. `proxy`), HTTPS entrypoint `websecure`, certresolver `letsencrypt`, and a DNS A record `netbird.<domain>` → evobox public IP, with ufw allowing 80/443/tcp and 3478/udp.

```yaml
# /srv/netbird/docker-compose.yml
name: netbird

services:
  netbird-dashboard:
    image: netbirdio/dashboard:<VERSION>
    container_name: netbird-dashboard
    env_file: ./dashboard.env
    networks: [traefik-net]
    restart: unless-stopped
    labels:
      - traefik.enable=true
      - traefik.http.routers.netbird-dashboard.rule=Host(`netbird.<domain>`)
      - traefik.http.routers.netbird-dashboard.entrypoints=websecure
      - traefik.http.routers.netbird-dashboard.tls=true
      - traefik.http.routers.netbird-dashboard.tls.certresolver=letsencrypt
      - traefik.http.routers.netbird-dashboard.priority=1
      - traefik.http.services.netbird-dashboard.loadbalancer.server.port=80

  netbird-server:
    image: netbirdio/netbird-server:<VERSION>
    container_name: netbird-server
    environment:
      - NB_SETUP_PAT_ENABLED=true      # only until bootstrap is done, then remove
      - NB_DISABLE_ANONYMOUS_METRICS=true
      # - NB_API_RATE_LIMITING_ENABLED=true
      # - NB_API_RATE_LIMITING_RPM=60
      # - NB_API_RATE_LIMITING_BURST=10
    networks: [traefik-net]
    ports:
      - "3478:3478/udp"                 # STUN — must be public, cannot be proxied
    volumes:
      - netbird_data:/var/lib/netbird
      - ./config.yaml:/etc/netbird/config.yaml:ro
    command: ["--config", "/etc/netbird/config.yaml"]
    restart: unless-stopped
    labels:
      - traefik.enable=true
      - traefik.http.routers.netbird-grpc.rule=Host(`netbird.<domain>`) && (PathPrefix(`/signalexchange.SignalExchange/`) || PathPrefix(`/management.ManagementService/`) || PathPrefix(`/management.ProxyService/`))
      - traefik.http.routers.netbird-grpc.entrypoints=websecure
      - traefik.http.routers.netbird-grpc.tls=true
      - traefik.http.routers.netbird-grpc.tls.certresolver=letsencrypt
      - traefik.http.routers.netbird-grpc.service=netbird-server-h2c
      - traefik.http.routers.netbird-grpc.priority=100
      - traefik.http.routers.netbird-backend.rule=Host(`netbird.<domain>`) && (PathPrefix(`/relay`) || PathPrefix(`/ws-proxy/`) || PathPrefix(`/api`) || PathPrefix(`/oauth2`))
      - traefik.http.routers.netbird-backend.entrypoints=websecure
      - traefik.http.routers.netbird-backend.tls=true
      - traefik.http.routers.netbird-backend.tls.certresolver=letsencrypt
      - traefik.http.routers.netbird-backend.service=netbird-server
      - traefik.http.routers.netbird-backend.priority=100
      - traefik.http.services.netbird-server.loadbalancer.server.port=80
      - traefik.http.services.netbird-server-h2c.loadbalancer.server.port=80
      - traefik.http.services.netbird-server-h2c.loadbalancer.server.scheme=h2c

  # (Optional, on evobox as LAN routing peer — needs a one-off/reusable setup key first)
  netbird-client:
    image: netbirdio/netbird:<VERSION>
    container_name: netbird-client
    hostname: evobox
    network_mode: host
    cap_add: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
    devices:
      - /dev/net/tun
    environment:
      - NB_SETUP_KEY=<SETUP-KEY>
      - NB_MANAGEMENT_URL=https://netbird.<domain>:443
    volumes:
      - netbird-client:/var/lib/netbird
    restart: unless-stopped

networks:
  traefik-net:
    external: true
    name: <traefik-network>            # e.g. proxy

volumes:
  netbird_data:
    name: netbird_data
  netbird-client:
    name: netbird-client
```

### 7.2 `config.yaml` example

```yaml
server:
  listenAddress: ":80"                              # TLS terminated by Traefik
  exposedAddress: "https://netbird.<domain>:443"    # handed out to all peers
  stunPorts: [3478]
  # metricsPort: 9090
  # healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"
  authSecret: "<32+ random chars>"                  # relay authentication shared secret
  dataDir: "/var/lib/netbird/"
  disableAnonymousMetrics: true
  auth:
    issuer: "https://netbird.<domain>/oauth2"
    localAuthDisabled: false
    signKeyRefreshEnabled: true
    dashboardRedirectURIs:
      - "https://netbird.<domain>/nb-auth"
      - "https://netbird.<domain>/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"
    # Optional: bootstrap admin without the /setup page
    # owner:
    #   email: "admin@example.com"
    #   password: "<long-random>"
  store:
    engine: "sqlite"
    # dsn: ""                                        # postgres/mysql if needed
    encryptionKey: "<base64 of 32 random bytes>"     # openssl rand -base64 32
```

### 7.3 `dashboard.env`

```bash
NETBIRD_MGMT_API_ENDPOINT=https://netbird.<domain>
NETBIRD_MGMT_GRPC_API_ENDPOINT=https://netbird.<domain>
AUTH_AUDIENCE=netbird-dashboard
AUTH_CLIENT_ID=netbird-dashboard
AUTH_CLIENT_SECRET=
AUTH_AUTHORITY=https://netbird.<domain>/oauth2
USE_AUTH0=false
AUTH_SUPPORTED_SCOPES=openid profile email groups
AUTH_REDIRECT_URI=/nb-auth
AUTH_SILENT_REDIRECT_URI=/nb-silent-auth
LETSENCRYPT_DOMAIN=none
NGINX_SSL_PORT=443
```

### 7.4 Environment variables worth knowing

- `NB_SETUP_PAT_ENABLED=true` (netbird-server): enable `POST /api/setup` PAT creation for automation.
- `NB_DISABLE_ANONYMOUS_METRICS=true`: opt out of telemetry.
- `NB_API_RATE_LIMITING_ENABLED/RPM/BURST`: API rate limiting.
- `NB_PPROF_ADDR`: debug pprof — keep unset/loopback.
- `NB_LOG_LEVEL` / `NB_LOG_FILE`: logging (also in config.yaml).
- `NETBIRD_MGMT_API_ENDPOINT`, `AUTH_*`, `LETSENCRYPT_DOMAIN=none`: dashboard (see 7.3).
- Client: `NB_SETUP_KEY` and `NB_MANAGEMENT_URL` (any `--flag` maps to `NB_FLAGNAME`; there is no `NB_MGMT_URL`, and without the URL the client stays on `api.netbird.io`).
- Precedence (upstream, deliberately unusual): env vars > CLI flags > `<profile>.json` > defaults.

### 7.5 Bootstrap & verification sequence

1. `docker compose up -d`; wait for netbird-server healthy.
2. Verify through Traefik: `curl -fsS https://netbird.<domain>/oauth2/.well-known/openid-configuration`.
3. Create owner + PAT via `POST /api/setup` (or set `auth.owner.*` before first start; or open `https://netbird.<domain>/setup` in a browser).
4. Via API/dashboard: create a setup key (e.g. reusable, 30 uses, no expiry or 30 d, auto-assign group).
5. Start `netbird-client` on evobox with that key; `netbird status` shows connected + assigned `100.x.y.z`.
6. Enable `net.ipv4.ip_forward=1` on evobox.
7. Dashboard → Networks: create Network "Home LAN", resource `192.168.1.0/24` (or real LAN CIDR), routing peer = evobox, access policy = user group → resource group.
8. On phones/laptops install the NetBird app, set management URL, log in; ping a LAN device that has no client to verify.
9. Remove `NB_SETUP_PAT_ENABLED` once bootstrapped; back up `netbird_data` + `config.yaml` + the two secret values.

---

## 8. Prior-doc verification notes (what changed / corrections)

- Prior doc is broadly accurate but describes the pre-current setup as "the" setup. Current state:
  - **Combined container** (`netbirdio/netbird-server`) is the default since v0.65.0; the old multi-container (management/signal/relay/coturn) is legacy with a migration guide.
  - **Embedded STUN** replaced the Coturn container in the new deployment; only UDP 3478 is needed (legacy deployments additionally needed UDP 49152-65535 for TURN).
  - **Coturn TURN relay port range** is legacy-only; relay is now WebSocket (and QUIC on NetBird Cloud) on the main HTTPS port.
  - Ports: docs now emphasize consolidated port architecture since v0.29; behind a proxy it's just 80/443 + UDP 3478.
  - **Routes are deprecated** in favor of **Networks** (zero-trust default); the prior doc's "Add Route" instructions still work but the dashboard now centers on Networks.
  - The `/setup` page, PAT automation (`NB_SETUP_PAT_ENABLED`), local MFA, API rate limiting, and Postgres/MySQL stores are newer additions usable for unattended deployment.
  - `config.yaml.example` in the repo uses `listenAddress: ":443"`; behind Traefik set `:80` (or keep `:443` and publish 443 directly — not recommended when Traefik owns 443).

---

## 9. Source List

Official docs:
- Quickstart (self-hosting, combined container): https://docs.netbird.io/selfhosted/selfhosted-quickstart
- Advanced (legacy multi-container) guide + port table: https://docs.netbird.io/selfhosted/selfhosted-guide
- Configuration files reference (docker-compose, config.yaml, dashboard.env): https://docs.netbird.io/selfhosted/maintenance/configuration-files
- External reverse proxy (Traefik/Nginx/Caddy/NPM templates, combined + legacy): https://docs.netbird.io/selfhosted/external-reverse-proxy
- Environment variables reference: https://docs.netbird.io/selfhosted/environment-variables
- Automated setup / setup API / PAT: https://docs.netbird.io/selfhosted/automated-setup
- Backup: https://docs.netbird.io/selfhosted/maintenance/backup
- Upgrade: https://docs.netbird.io/selfhosted/maintenance/upgrade
- Migration to combined container: https://docs.netbird.io/selfhosted/migration/combined-container
- Local identity provider (embedded IdP, local users): https://docs.netbird.io/selfhosted/identity-providers/local
- Identity providers overview: https://docs.netbird.io/selfhosted/identity-providers
- Ports & firewalls (client-side endpoints): https://docs.netbird.io/about-netbird/ports-and-firewalls
- How NetBird works (architecture): https://docs.netbird.io/about-netbird/how-netbird-works
- Docker client installation: https://docs.netbird.io/get-started/install/docker
- Setup keys (join keys): https://docs.netbird.io/manage/peers/register-machines-using-setup-keys
- Bootstrap peers via config file: https://docs.netbird.io/manage/peers/bootstrap-via-config-file
- Networks (new routing model): https://docs.netbird.io/manage/networks
- How routing peers work (forwarding, masquerade, HA): https://docs.netbird.io/manage/networks/how-routing-peers-work
- Routes (legacy): https://docs.netbird.io/manage/network-routes
- Homelab use case: https://docs.netbird.io/use-cases/homelab
- Access home devices (VPN-to-site): https://docs.netbird.io/use-cases/remote-access/access-home-devices
- Enable reverse proxy feature: https://docs.netbird.io/selfhosted/migration/enable-reverse-proxy
- Troubleshooting: https://docs.netbird.io/selfhosted/troubleshooting

Source code:
- Repository: https://github.com/netbirdio/netbird
- Combined server config example: https://github.com/netbirdio/netbird/blob/main/combined/config.yaml.example
- Combined server Dockerfile: https://github.com/netbirdio/netbird/blob/main/combined/Dockerfile
- Docs source (raw MDX): https://github.com/netbirdio/docs
- Dashboard repo/releases: https://github.com/netbirdio/dashboard
- Docker Hub: https://hub.docker.com/r/netbirdio/netbird-server, https://hub.docker.com/r/netbirdio/dashboard, https://hub.docker.com/r/netbirdio/netbird
- Client install script: https://pkgs.netbird.io/install.sh
- Self-hosting install script: https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh

Prior work:
- `/home/verfeinerer/vault/research/netbird-selfhosted-setup-guide.md`

---

## RECOMMENDATIONS (for the builder agent)

1. **Use the combined-container architecture** (`netbirdio/netbird-server` + `netbirdio/dashboard`), pinned to current stable release tags. Do **not** use the legacy multi-container setup.
2. **Deploy under `/srv/netbird/`** with `docker-compose.yml`, `config.yaml`, and `dashboard.env` per §7. Attach both services to evobox's existing Traefik Docker network via labels (routers: `netbird-grpc` with `scheme=h2c` backend for the three gRPC path prefixes; `netbird-backend` for `/relay`, `/ws-proxy/`, `/api`, `/oauth2`; dashboard catch-all at `priority=1`). Use the exact label template in §7.1 — the two-backend (http + h2c) split is mandatory for gRPC.
3. **Expose exactly**: Traefik 80/443 (existing) + `3478:3478/udp` from `netbird-server` (STUN is not proxyable). Bind nothing else to 0.0.0.0; if you prefer explicit host ports instead of label discovery, use `127.0.0.1:8080`/`127.0.0.1:8081`.
4. **Ensure Traefik**: working `letsencrypt` certresolver for `netbird.<domain>` (A record → evobox), `websecure` entrypoint without aggressive timeouts on long-lived connections (readTimeout 0 semantics as in NetBird's own compose), `exposedByDefault=false` docker provider.
5. **Set in `config.yaml`**: `listenAddress: ":80"`, `exposedAddress: https://netbird.<domain>:443`, `stunPorts: [3478]`, random `authSecret`, random base64 32-byte `store.encryptionKey`, embedded IdP `auth.issuer` + redirect URIs, `disableAnonymousMetrics: true`.
6. **Bootstrap unattended**: `NB_SETUP_PAT_ENABLED=true` + `POST /api/setup` (create_pat) to get owner + PAT; then drive the rest through the REST API (users/groups/setup keys/Network + access policy). Remove the env var after bootstrap. Strong admin password + MFA.
7. **Routing peer = evobox**: run `netbirdio/netbird` client container with `network_mode: host`, `cap_add: NET_ADMIN SYS_ADMIN SYS_RESOURCE`, `/dev/net/tun`, `NB_SETUP_KEY`, and `NB_MANAGEMENT_URL`; enable `net.ipv4.ip_forward=1` (and IPv6 forwarding if used) on the host.
8. **LAN exposure**: create a **Network** (not legacy Route) with resource `<LAN-CIDR>` (e.g. `192.168.1.0/24`), routing peer evobox, masquerade ON (default), and an access policy from the user's group to that resource. Add the home DNS (Pi-hole/router) as NetBird custom DNS for hostname resolution.
9. **Post-deploy checks**: `curl https://netbird.<domain>/oauth2/.well-known/openid-configuration`; `netbird status` on the client container (connected, not permanently relayed — if always relayed, check STUN reachability `stun <domain> 3478`); ping a clientless LAN device from an external network; verify Traefik logs show the gRPC routes working.
10. **Maintenance**: back up `netbird_data` volume + `config.yaml`/`dashboard.env` (and the secret values) regularly; upgrade by pulling new tags and `docker compose up -d --force-recreate`; watch release notes for management/proxy version-coupling notes.
