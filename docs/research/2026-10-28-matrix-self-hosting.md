# Research: fully self-hosted Matrix chat server for team communication

**Date:** 2026-10-28
**Purpose:** technical basis for `docs/plans/matrix-setup-plan.md` (a new `tasks/setup-matrix.sh`).
**Scope:** small team (5–50 users), single Ubuntu server, docker compose, Traefik v3 + Let's Encrypt,
`ufw`, data under `/srv/matrix`, kwisatz conventions (idempotent, converge-on-rerun, secrets in
`.env`, templates in `templates/<component>/`).
**Method:** five parallel web-research passes (homeserver choice; federation/proxy/TLS; clients &
calls; auth/users/admin; operations/backup/bridges) against upstream docs, source trees, release
APIs and registries. Items not confirmed against a primary source are marked **[UNVERIFIED]** and
are collected in §13 — the implementation must close them, not assume them.

> The suggested starting page (matrix.org *Matrix for IM*) is an end-user onboarding guide
> (accounts, Element, how federation looks to a user). It contains no operator guidance; every
> operator fact below comes from the Synapse/MAS/Element/LiveKit docs and repos.

---

## 1. Executive summary

| Decision | Choice | Why (short) |
|---|---|---|
| Homeserver | **Synapse v1.164.0** (`matrixdotorg/synapse:v1.164.0`, monolith, no workers) | Only server with native Simplified Sliding Sync **and** first-class MAS **and** MatrixRTC **and** the full Admin API. Dendrite is in maintenance mode, conduwuit archived, Conduit had a string of critical CVEs, Tuwunel/continuwuity are RocksDB-only with no path to/from Synapse. |
| Database | **PostgreSQL 17** (`postgres:17-alpine`), C locale, UTF-8 | Synapse min PG 14 (13 dropped in 1.143); repo already standardises on PG17 and `pg_dump -Fc`; PG18 image moved its data path (pitfall). |
| Auth | **Matrix Authentication Service (MAS) 1.28.0** from day one | Element X's SSO, QR login, account management and Element Admin require MAS; Element X will become OIDC-only; adopting MAS later is a one-way `syn2mas` migration with downtime. On an empty server it costs one container + one DB. |
| Web client | **Element Web v1.12.33** on its own host (`chat.<domain>`) | Upstream explicitly advises against same-origin with the homeserver (XSS). Element Call is embedded — no separate Element Call app needed. |
| Mobile | Element X (iOS/Android) | Works against native SSS (Synapse ≥ 1.114); old sliding-sync proxy is archived. |
| Calls | **MatrixRTC: LiveKit SFU v1.13.11 + lk-jwt-service 0.9.0** (opt-in phase) | The current Element calling stack (group + 1:1 via `element_call.use_exclusively`). Embedded TURN/coturn not needed initially. |
| Federation | **Off by default** (private team server), switchable | Smaller attack surface, no 8448, no public-room RAM blowups; `server_name` still chosen as if federating later. |
| Push | Element's public push gateway (no Sygnal) | Only the app vendor holds APNs/FCM keys; Element X sends `event_id_only` — no message content leaves the server. |
| Admin UI | **Ketesa** (ex etkecc/synapse-admin), VPN/LAN-only | MAS-aware, actively maintained; Element Admin is still 0.x. |
| Bridges / bots | **Out of scope for v1** | Per-bridge DB, puppeting/E2EE burden, third-party protocol breakage. hookshot (generic webhooks for Forgejo) is the first v2 candidate. |

---

## 2. Matrix concepts an operator must get right

- **`server_name`** — the part after `:` in every ID (`@alice:example.com`). **Immutable** after first
  start. Together with the database and the **signing key** it is the server's permanent identity:
  re-using a `server_name` with a fresh DB/key breaks E2EE and federation state other servers cached
  about you. Choose a domain you own, normally the apex (`example.com`).
- **`public_baseurl`** — where clients actually connect (`https://matrix.example.com/`).
- **Delegation** — keep `@alice:example.com` while Synapse lives on `matrix.example.com:443`, via
  `/.well-known/matrix/server` (federation) and `/.well-known/matrix/client` (client discovery) on
  `https://example.com`. SRV records are "generally not recommended" by Synapse docs.
- **Signing key** — `/data/<server_name>.signing.key`; signs events and federation requests.
  Never regenerate it with home-grown code: ESS Community's secret hook produced **predictable
  signing keys** (GHSA-qwcj-h6m8-vp6q, critical, Feb 2026). Use Synapse's own generator only.
- **E2EE** — on by default for DMs/private rooms in Element clients; key backup/recovery key is
  client-side. An admin password reset does **not** restore message history — onboarding must
  teach users to keep their recovery key.

---

## 3. Homeserver comparison (state 2026-10-28)

| | Synapse | Dendrite | Tuwunel | continuwuity | Conduit | conduwuit |
|---|---|---|---|---|---|---|
| Status | very active (Element) | **maintenance mode** (security only) | active | active (community) | security releases | **archived** |
| Latest | v1.164.0 (2026-10-27) | v0.15.2 (2025-08-15) | v1.9.4 (2026-10-10) | v26.9.1 (2026-09-28) | v0.10.15 (2026-09-30) | — |
| DB | PostgreSQL (SQLite test-only) | PG / SQLite | RocksDB | RocksDB | RocksDB / SQLite | RocksDB |
| SSS (MSC4186, Element X) | native | **no** | yes | yes | yes (≥0.10.0) | — |
| Next-gen auth | MAS | no | built-in OIDC | built-in OAuth | ? | — |
| MatrixRTC | `matrix_rtc.transports` | ? | `livekit_url` | `[global.matrix_rtc]` | ? | — |
| Synapse migration | — | no | "planned" | no | no | — |

- Images: `matrixdotorg/synapse:v1.164.0` = `ghcr.io/element-hq/synapse:v1.164.0` (Debian trixie,
  Python 3.13; Python ≥ 3.11 required from 1.164). Release cadence ≈ every 2 weeks, rc1–rc3 first.
- MAS only supports `matrix.kind: synapse` → choosing a Rust server rules out MAS.
- **Fallback:** Tuwunel if RAM is the binding constraint and MAS/calls are not needed.

### Deployment projects used as reference

- **ESS Community** (`element-hq/ess-helm` 26.10.3) — Helm/K8s only (no compose), ≤100 users,
  non-commercial. Its `values.yaml` is a good *known-compatible version matrix*: Synapse v1.163.1,
  MAS 1.27.1, lk-jwt-service 0.9.0, LiveKit v1.13.10, Element Web v1.12.32, Element Admin 0.1.18,
  hookshot 7.5.0, `postgres:17.11-alpine`. Default hosts: `matrix.`, `account.` (MAS), `mrtc.`,
  `chat.`, `admin.`.
- **spantaleev/matrix-docker-ansible-deploy (MDAD)** — Ansible + systemd-managed containers,
  Traefik on 80/443/8448, Synapse v1.164.0 without workers, PG18; MAS, Matrix RTC, coturn, Ketesa,
  bridges all opt-in. Lessons: LiveKit needs its own TCP/UDP ports + a WebSocket route; the JWT
  service must reach LiveKit via its *public* URL ("Unable to create room on SFU" otherwise);
  synapse-auto-compressor for DB bloat.

---

## 4. Synapse configuration essentials

### 4.1 Docker image facts
- Single volume `/data` (config, signing key, media, `appservices/`). Runs as UID/GID **991**
  (overridable with `UID`/`GID`).
- Built-in `HEALTHCHECK`: `curl -fSs http://localhost:8008/health` (start-period 5s, interval 15s)
  — `wait_for_healthy` can rely on it as long as the client listener stays on 8008.
- jemalloc is preloaded by `start.py` automatically.
- `generate` mode (`SYNAPSE_SERVER_NAME`, `SYNAPSE_REPORT_STATS=no`) writes `homeserver.yaml` **with
  secrets inline**, a log config and the signing key → conflicts with the repo's secrets rule; use
  it only to bootstrap the signing key, and template `homeserver.yaml` ourselves.
- Synapse does not retry its DB connection on start → `depends_on: condition: service_healthy` on
  postgres plus `restart: unless-stopped`.
- `homeserver.yaml` has **no `${VAR}` interpolation**, but secrets have `*_path` variants:
  `registration_shared_secret_path` (1.67+), `macaroon_secret_key_path` (1.121+),
  `form_secret_path` (1.126+), `turn_shared_secret_path` (1.116+),
  `matrix_authentication_service.secret_path`. The DB password has **no** `_path`; the `args` are
  passed to libpq, so omitting `password` and setting `PGPASSWORD` in the container env (or
  `passfile`) should work **[UNVERIFIED]**.

### 4.2 Listener (behind Traefik, in a container)
```yaml
public_baseurl: https://matrix.example.com/
listeners:
  - port: 8008
    type: http
    tls: false
    x_forwarded: true                  # real client IPs → rate limits work
    bind_addresses: ['0.0.0.0']        # container: not 127.0.0.1
    resources:
      - names: [client, federation]    # drop 'federation' when private; keep 'openid' for lk-jwt
        compress: false
```
Routes to proxy: `/_matrix`, `/_synapse/client` (+ `/_synapse/mas` with MAS). **Do not** expose
`/_synapse/admin` publicly ("we do not recommend exposing them to the public internet").

### 4.3 PostgreSQL
```yaml
database:
  name: psycopg2
  args: {user: synapse, dbname: synapse, host: db, port: 5432, cp_min: 5, cp_max: 10}
```
- DB **must** be `UTF8` + `C` collation/ctype; Synapse refuses to start otherwise (never set
  `allow_unsafe_locale`). Docker: `POSTGRES_INITDB_ARGS="--encoding=UTF-8 --lc-collate=C --lc-ctype=C"`.
- Min PG 14; PG 14 EOL ≈ Nov 2026 → expect Synapse to require 15+ soon. Use 17.
- `postgres:18+` sets `PGDATA=/var/lib/postgresql/18/docker` and moves the `VOLUME` to
  `/var/lib/postgresql` — mounting `.../data` silently breaks. Staying on 17 avoids it.
- Synapse sets `idle_in_transaction_session_timeout` (30 min) since 1.159.
- Defaults are fine for <50 users; tuning knobs (`shared_buffers`, `work_mem`, …) only for scale.

### 4.4 Hardening defaults
```yaml
enable_registration: false            # MAS owns registration when enabled
report_stats: false
trusted_key_servers: []               # private server; [{server_name: matrix.org}] when federating
suppress_key_server_warning: true
allow_public_rooms_without_auth: false
allow_public_rooms_over_federation: false
url_preview_enabled: true             # optional; then the blacklist below is MANDATORY (no default)
url_preview_ip_range_blacklist: [127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
  100.64.0.0/10, 192.0.0.0/24, 169.254.0.0/16, 192.88.99.0/24, 198.18.0.0/15, 192.0.2.0/24,
  198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, '::1/128', 'fe80::/10', 'fc00::/7',
  '2001:db8::/32', 'ff00::/8', 'fec0::/10']
max_upload_size: 50M
encryption_enabled_by_default_for_room_type: invite   # 'all' breaks server-side search in public rooms
push:
  include_content: false
```
- `100.64.0.0/10` covers NetBird peers; without the blacklist "anyone in any room could cause your
  synapse to issue arbitrary GET requests to your internal services".
- `registration_shared_secret` lets its holder create admins even with registration disabled —
  file mode 600, never logged.
- Rate-limit defaults are sane (`rc_message` 0.2/s burst 10, `rc_login.*` …) — but only with
  correct `x_forwarded`.

### 4.5 Storage growth
| Key | Default | Recommendation |
|---|---|---|
| `media_retention.remote_media_lifetime` | never | `14d` (only matters with federation) |
| `media_retention.local_media_lifetime` | never | leave unset for a team (user uploads) |
| `forgotten_room_retention_period` | never | `28d` |
| `redaction_retention_period` | `7d` | keep |
| `retention:` (message policies) | disabled | keep disabled in v1 |

Purge History / Purge Media / Delete Room admin APIs exist; disk returns only after `VACUUM FULL`.
`synapse_auto_compressor` (rust-synapse-compress-state, last tag v0.1.4 2024-04, no official image)
matters mainly once you join big federated rooms → v2.

### 4.6 Sizing
- Element's ESS sizing for 1–500 users with closed/limited federation: Synapse 2 CPU / 2 GiB;
  PostgreSQL 1–2 CPU / 4–6 GiB. Open federation: much more (5 CPU / 4.5 GiB + 3 CPU / 8 GiB).
- Community experience **[UNVERIFIED]**: 200–600 MB RSS for a small, non-federated team; joining
  `#matrix:matrix.org`-size rooms pushes even one user to 2–3 GB.
- Disk ≈ 0.6 GB/active user/year without federation, plus media.
- Workers: "For small instances it is recommended to run Synapse in the default monolith mode."
- `caches.global_factor` default 0.5 (`SYNAPSE_CACHE_FACTOR` overrides); presence can be disabled
  if it causes CPU spikes.

---

## 5. Delegation, well-known and federation

### 5.1 Well-known documents
`https://<server_name>/.well-known/matrix/server` (federation, servers fetch it; cached 24–48 h):
```json
{ "m.server": "matrix.example.com:443" }
```
(omit the port → defaults to **8448**; always write `:443`.)

`https://<server_name>/.well-known/matrix/client` (clients; **needs CORS**, Element X ignores it
without):
```json
{
  "m.homeserver": { "base_url": "https://matrix.example.com" },
  "org.matrix.msc4143.rtc_foci": [
    { "type": "livekit", "livekit_service_url": "https://rtc.example.com/livekit/jwt" }
  ]
}
```
Headers: `Content-Type: application/json`, `Access-Control-Allow-Origin: *`,
`Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`,
`Access-Control-Allow-Headers: X-Requested-With, Content-Type, Authorization` (matches matrix.org's
live response).

### 5.2 Ways to serve them
1. **Static container on the apex** (`nginx:<pinned>-alpine`, `default_type application/json`, router
   `Host(apex) && PathPrefix(/.well-known/matrix)` + headers middleware). Works whenever the apex
   DNS points at this host. Flexible (`m.server` can name a subdomain).
2. **Synapse built-in** — `/.well-known/matrix/client` is served on the client listener *if
   `public_baseurl` is set* (with CORS, plus `extra_well_known_client_content`);
   `serve_server_wellknown: true` serves `{"m.server": "<server_name host>:443"}` — only correct
   when `https://<server_name>` itself routes to Synapse. Useful in the "server_name == homeserver
   host" layout.
3. **Apex hosted elsewhere** (company website) → the operator must publish the two JSON files
   there; the script prints them.

Federating Synapses do **not** follow HTTP 308 redirects — never 308-redirect the apex.
**[UNVERIFIED]** whether Traefik v3's permanent redirects emit 301 or 308.

### 5.3 Private (non-federated) operation
```yaml
federation_domain_whitelist: []    # "the recommended way of disabling federation"
trusted_key_servers: []
```
+ drop `federation` from listener resources (stops `/_matrix/federation` and `/_matrix/key`), no
8448, no `.well-known/matrix/server`. The `openid` resource must stay available for lk-jwt-service
(add it explicitly when `federation` is removed). Federation tester will fail by design.

### 5.4 LAN/VPN-only (NetBird) operation
- Clients need a **trusted** certificate. Best: Traefik **DNS-01** (`DNS_PROVIDER` already supported
  by `setup-traefik.sh`) for public names that resolve only in NetBird DNS to the peer IP — no
  public A record, no open ports. Hostnames appear in CT logs (wildcard hides them).
- Internal CA works on Element X Android (trusts user CAs); iOS with a full-trust profile CA
  **[UNVERIFIED]**. Self-signed without a CA is impractical on mobile.
- Push still needs outbound HTTPS to the vendor gateway.

### 5.5 Testing
```bash
curl -s  https://example.com/.well-known/matrix/server
curl -si https://example.com/.well-known/matrix/client | grep -iE 'content-type|access-control'
curl -s  https://matrix.example.com/_matrix/client/versions | jq .versions
curl -s  https://matrix.example.com/_matrix/federation/v1/version     # 404 when private
curl -s  https://matrix.example.com/_matrix/client/v1/auth_metadata   # MAS discovery [UNVERIFIED path]
# federation: https://federationtester.matrix.org/api/report?server_name=example.com
```

### 5.6 Traefik specifics
- Synapse router: `Host(matrix.<d>) && (PathPrefix(/_matrix) || PathPrefix(/_synapse/client) || PathPrefix(/_synapse/mas))`.
- Admin router: `Host(matrix.<d>) && PathPrefix(/_synapse/admin)` + `ipAllowList` (v3 name).
- Traefik sets `X-Forwarded-*` and passes paths through unchanged by default.
- **Pitfall:** Traefik v3 entrypoint `transport.respondingTimeouts.readTimeout` defaults to **60s**
  for the whole request body → large uploads on slow links are cut. Synapse's 50M default is usually
  fine; a larger `max_upload_size` needs the traefik entrypoint raised (`setup-traefik.sh` scope).
- No default body-size limit in Traefik (only with a `buffering` middleware).

---

## 6. Matrix Authentication Service (MAS)

### 6.1 What and why
OAuth 2.0/OIDC server for Matrix (MSC3861 family). Synapse delegates login, registration and
sessions to it; a compat layer keeps legacy `/login` (password) clients working.

- Element X: password login still works without MAS (element-meta #3176), but Element states it
  "will in future only support the new native OIDC authentication"; SSO in Element X **only** via
  MAS; QR-code login, account management and **Element Admin require MAS**; in-app registration
  likely needs MAS **[UNVERIFIED]**.
- Adding later = `mas-cli syn2mas` (Synapse stopped, PG only, password hashes + devices + tokens
  migrated, rollback easy only until users log in through MAS). **Fresh install → start with MAS.**

### 6.2 Facts
- Image `ghcr.io/element-hq/matrix-authentication-service:1.28.0` (tags without `v`). 1.27.1 was a
  security release (compromised TLS CAs removed).
- **Distroless** (`ENTRYPOINT ["/usr/local/bin/mas-cli"]`, no shell, no curl) → a `CMD curl`
  healthcheck is impossible; probe `/health` from outside (internal listener) or rely on Traefik.
  Runs as distroless `nonroot` (UID 65532 **[UNVERIFIED]** for this image) → file ownership.
- Port 8080 (web), internal listener for `health` (+ optionally `adminapi`, `prometheus`).
- Own role + DB (can share the postgres container). PG ≥ 13; pgBouncer only in session mode.
- `mas-cli config generate` creates **new random** signing keys (`secrets.keys`) and cookie
  encryption secret (`secrets.encryption`) on every run → generate **once**, never on re-run.
- Multiple config files: `--config a.yaml --config b.yaml` or `MAS_CONFIG=/a.yaml:/b.yaml` →
  template the non-secret layout, keep generated secrets in a separate mode-600 file.
- Requires Synapse ≥ 1.136. Synapse side (stable since `experimental_features.msc3861` was
  **removed in 1.157**, its presence now prevents startup):
  ```yaml
  matrix_authentication_service:
    enabled: true
    endpoint: http://mas:8080/
    secret_path: /data/secrets/mas_secret   # == MAS matrix.secret(_file)
  ```
  With MAS on: no `enable_registration`/`registration_requires_token` in Synapse; Synapse's
  registration-token admin API and user-creating `PUT /_synapse/admin/v2/users` are disabled
  (create users through MAS).

### 6.3 MAS config skeleton
```yaml
http:
  public_base: https://auth.example.com/
  listeners:
    - name: web
      resources: [{name: discovery}, {name: human}, {name: oauth}, {name: compat},
                  {name: graphql}, {name: assets}]
      binds: [{address: "[::]:8080"}]
    - name: internal
      resources: [{name: health}]
      binds: [{address: "[::]:8081"}]
database:
  uri: postgres://mas:<pw>@db/mas          # secret → the generated secrets file
matrix:
  kind: synapse
  homeserver: example.com                   # == Synapse server_name
  endpoint: http://synapse:8008
  secret_file: /secrets/mas_secret
passwords:
  enabled: true
  schemes: [{version: 1, algorithm: argon2id}]
  minimum_complexity: 3
account:
  password_registration_enabled: false      # invite-only team
  password_recovery_enabled: false          # needs email
email:
  transport: blackhole                       # default; smtp optional
```
`http.trusted_proxies` defaults to RFC1918 + loopback (covers the docker bridge).

### 6.4 Routing
Paths `^/_matrix/client/[^/]+/(login|logout|refresh)` on the **homeserver** host go to MAS (compat
layer); `auth.<d>` goes entirely to MAS. Traefik v3:
`PathRegexp(\`^/_matrix/client/[^/]+/(login|logout|refresh)\`)` with a higher `priority` than the
Synapse router **[UNVERIFIED — translated from the upstream nginx example]**. Clients discover MAS
via Synapse's `/_matrix/client/v1/auth_metadata` (MSC2965) **[UNVERIFIED]**.

### 6.5 User management
```bash
docker compose exec mas mas-cli manage register-user --yes alice --password '…' --admin
docker compose exec mas mas-cli manage issue-user-registration-token --usage-limit 5 --expires-in 604800
# also: promote-admin, set-password, lock-user, kill-sessions, list-admin-users
mas-cli config check | config sync [--prune] | doctor | database migrate
```
Without MAS (reference only): `register_new_matrix_user http://localhost:8008 -c /data/homeserver.yaml -u admin -p … -a`.

### 6.6 Upstream identity (optional)
MAS `upstream_oauth2.providers[]` (ULID `id`, `issuer`, `client_id`, `client_secret[_file]`,
`claims_imports.localpart: {action: require, template: "{{ user.preferred_username }}"}`); redirect
URI `https://auth.<d>/upstream/callback/<id>`. Samples exist for Keycloak, Authentik, Authelia,
Kanidm, GitLab, GitHub; **no Forgejo sample** (generic OIDC should work **[UNVERIFIED]**). Synapse's
legacy `oidc_providers` does **not** work with Element X.

---

## 7. Clients

### 7.1 Element Web
- `vectorim/element-web:v1.12.33` ≡ `ghcr.io/element-hq/element-web:v1.12.33` (same CI build).
  Non-root nginx, `/app/config.json` mount, `ELEMENT_WEB_PORT` (default 80); read-only possible with
  tmpfs `/tmp` and `/etc/nginx/conf.d`.
- **Separate domain** (`chat.<d>`) — upstream: "We do not recommend running Element from the same
  domain name as your Matrix homeserver" (XSS).
- Recommended headers: `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options: nosniff`,
  `X-XSS-Protection: 1; mode=block`, `Content-Security-Policy: frame-ancestors 'self'`.
- `config.json` (snake_case; camelCase is deprecated):
  ```json
  {
    "default_server_config": {"m.homeserver": {"base_url": "https://matrix.example.com",
                                               "server_name": "example.com"}},
    "disable_custom_urls": true,
    "disable_guests": true,
    "permalink_prefix": "https://chat.example.com",
    "show_labs_settings": false,
    "element_call": {"use_exclusively": true}
  }
  ```
  `element_call.use_exclusively: true` removes legacy 1:1/Jitsi calls (contradicts `disable: true`).
  Element Web v1.12.33 bundles `element-call-embedded` → no standalone Element Call deployment for
  in-app calls.

### 7.2 Element X
- Requires Simplified Sliding Sync — native in Synapse since **1.114** (use ≥ 1.120.1 because of
  CVE-2024-53867; any current version is fine). `matrix-org/sliding-sync` proxy is **archived**.
- iOS 26.10.8 / Android 26.10.1 current.
- Push: iOS → `https://matrix.org/_matrix/push/v1/notify`; Android FCM → same; Android
  UnifiedPush → `matrix.gateway.unifiedpush.org` or a self-hosted ntfy. Pushers registered with
  `event_id_only`. **Synapse needs outbound HTTPS to matrix.org even with federation off.**

---

## 8. Calls: MatrixRTC (Element Call) and TURN

### 8.1 What changed in Aug–Oct 2026 (most blog posts are stale)
- Element Call **v0.24.0** deprecated LiveKit discovery via `.well-known` `rtc_foci`; clients now
  read Synapse's `matrix_rtc.transports` at `/_matrix/client/unstable/org.matrix.msc4143/rtc/transports`.
  `.well-known` stays a fallback for older clients — still publish it.
- Synapse **1.161** deprecated `livekit_service_url` and added `url` (SFU WebSocket) mode, which
  requires lk-jwt-service to be registered as an **application service**.
- `msc3266_enabled` removed in 1.153, `msc4222_enabled` removed in 1.164 (now stable). The Element
  Call self-hosting doc still lists them → stale. Whether leftover keys are ignored or fatal is
  **[UNVERIFIED]** — don't set them.
- The `livekit` branch doc URL is 404; current guide: `element-call/docs/self_hosting.md` on `main`.

### 8.2 Components
| Component | Image | Role |
|---|---|---|
| LiveKit SFU | `livekit/livekit-server:v1.13.11` | media server (each room on one node) |
| lk-jwt-service | `ghcr.io/element-hq/lk-jwt-service:0.9.0` (now Rust) | issues LiveKit JWTs after validating the user's Matrix OpenID token |
| Element Call app | not needed | embedded in Element Web / X |

### 8.3 Synapse config
```yaml
experimental_features:
  msc4143_enabled: true        # MatrixRTC transports endpoint
  msc4502_enabled: true        # appservice is_joined lookups (lk-jwt AS mode)
  msc4512_enabled: true        # appservice proxy (lk-jwt AS mode)
max_event_delay_duration: 24h  # MSC4140 delayed events — without it calls get stuck
rc_message: {per_second: 0.5, burst_count: 30}
rc_delayed_event_mgmt: {per_second: 1, burst_count: 20}
matrix_rtc:
  transports:
    - type: livekit
      url: wss://rtc.example.com/livekit/sfu
      livekit_service_url: https://rtc.example.com/livekit/jwt   # deprecated, keep for older clients
app_service_config_files: [/data/appservices/lk-jwt.yaml]
```
`msc4354_enabled` (sticky events) appears in Element Call's dev config but not in the guide
**[UNVERIFIED need]**. The listener must keep the `openid` (or `federation`) resource.

### 8.4 lk-jwt-service
Env: `LIVEKIT_URL=wss://rtc.<d>/livekit/sfu` (public URL), `LIVEKIT_KEY`, `LIVEKIT_SECRET` (or
`*_FROM_FILE`), `LIVEKIT_FULL_ACCESS_HOMESERVERS=<server_name>` (**never `*`**),
`LIVEKIT_JWT_BIND=:8080`; AS mode: `LIVEKIT_HS_SERVER_NAME`, `LIVEKIT_AS_REGISTRATION_FILE` (or
`LIVEKIT_AS_TOKEN`/`LIVEKIT_HS_TOKEN`). Appservice registration:
```yaml
id: lk-jwt-service
as_token: <random>
hs_token: <random>
sender_localpart: _lk_jwt_service
namespaces: {users: [{exclusive: false, regex: "@.*:example\\.com"}]}
url: http://lk-jwt-service:8080
io.element.msc4502.scopes: ["urn:matrix:client:io.element.msc4502:rooms:is_joined"]
io.element.msc4512.proxy_prefix: rtc/livekit
io.element.msc4512.proxy_url: http://lk-jwt-service:8080
```
0.9.0 notes client support for the new endpoints is "still rolling out" → run both modes.

### 8.5 LiveKit
```yaml
port: 7880
rtc:
  tcp_port: 7881
  udp_port: 7882              # single-port UDP mux (port_range_* must be unset)
  use_external_ip: true        # or node_ip: <public/VPN IP>
turn: {enabled: false}
keys: {<LIVEKIT_KEY>: <LIVEKIT_SECRET>}   # secret ≥ 32 chars [UNVERIFIED minimum]
room: {auto_create: false}     # REQUIRED — else anyone can create rooms, bypassing lk-jwt access rules
webhook: {api_key: <LIVEKIT_KEY>, urls: [https://rtc.example.com/livekit/jwt/sfu_webhook]}
```
Routing on `rtc.<d>`: `/livekit/jwt` → lk-jwt `:8080` and `/livekit/sfu` → LiveKit `:7880`
(WebSocket), both with prefix stripping. 7881/tcp and the UDP media port(s) must be reachable
**directly** (not proxied). LiveKit recommends host networking for large UDP ranges; with the UDP
mux a single published port works in bridge mode.

### 8.6 TURN / coturn
- Group calls (and DMs with `use_exclusively`) go only through LiveKit; LiveKit has embedded TURN
  (TLS on 443/5349 needs its own IP/SNI because Traefik owns 443).
- coturn (`coturn/coturn:4.18.0`, host networking, 3478/5349 tcp+udp + relay range, `use-auth-secret`,
  `denied-peer-ip` private ranges, `no-tcp-relay`) is only needed for legacy 1:1 calls from old
  clients. Whether Element X still uses legacy TURN calls is **[UNVERIFIED]** (believed: no).
- **Recommendation:** no coturn; LiveKit ICE/TCP 7881 + UDP mux 7882; embedded TURN only if users
  sit behind strict firewalls.

### 8.7 Resources
CPU and bandwidth bound. Official benchmark: 16 vCPU ≈ 150×150 video at 85% CPU. For 5–20 people:
2 vCPU / 1–2 GB is plenty **[UNVERIFIED estimate]**; uplink is the limit (10-person video call ≈
20–50 Mbit/s outbound).

---

## 9. Firewall and ports

| Port | Purpose | When |
|---|---|---|
| 80/tcp, 443/tcp | Traefik (ACME HTTP-01, HTTPS) | always (already opened by traefik/firewall tasks) |
| 8448/tcp | federation without delegation | **never** in our design (delegate to :443) |
| 7881/tcp | LiveKit ICE/TCP fallback | calls enabled |
| 7882/udp | LiveKit UDP mux | calls enabled |
| 3478, 5349, relay range | coturn / LiveKit TURN | not in v1 |

**Docker-published ports bypass ufw INPUT rules** (DOCKER chain is evaluated first). ufw rules
document intent but do not protect container ports; only publish what must be public, everything
else via Traefik on the internal network.

---

## 10. Admin UIs

| UI | Version | Image | Notes |
|---|---|---|---|
| **Ketesa** (ex etkecc/synapse-admin) | v1.5.2 (2026-10-25) | `ghcr.io/etkecc/ketesa:v1.5.2` (port 8080) | drop-in for synapse-admin, MAS-aware, `/var/public/config.json` (`restrictBaseUrl`) |
| Synapse-Admin (original) | 0.11.4 (2026-03) | `awesometechnologies/synapse-admin` | slow updates |
| Element Admin | 0.1.18 (2026-10-22) | `oci.element.io/element-admin` | requires MAS admin API; early 0.x |

The admin UI runs in the browser and calls `/_synapse/admin` (and MAS admin API) directly → both the
UI and `/_synapse/admin` must be restricted to LAN/VPN (`ipAllowList`).

---

## 11. Operations

### 11.1 Backup
| Item | Back up? |
|---|---|
| PostgreSQL `synapse` DB (`pg_dump -Fc`, hot) | **yes** |
| PostgreSQL `mas` DB | **yes** |
| `<server_name>.signing.key` | **yes — identity** |
| `homeserver.yaml`, log config, appservice registrations, MAS config + secrets file, `.env` | yes |
| `media_store/local_content`, `local_thumbnails` | **yes** |
| `media_store/remote_*`, `url_cache*` | no (caches) |
| raw postgres data dir | no (use the dump) |

- Upstream dump: `pg_dump -Fc --exclude-table-data e2e_one_time_keys_json synapse`. If the table
  data was included, run `TRUNCATE e2e_one_time_keys_json;` **after restore and before starting
  Synapse** — reused one-time keys cause decryption failures.
- Restore into a **fresh** DB created with `--encoding=UTF8 --locale=C --template=template0`; never
  restore over an existing DB.
- Lost signing key: Synapse ≥ 1.67 creates a new one; add the old public key to `old_signing_keys`.

### 11.2 Upgrades
- Pin tags; read every `upgrade.md` section between versions; back up; bump; `up -d`.
- Schema migrations run at start ("Synapse will not start until database migrations are complete");
  background updates continue — check `/_synapse/admin/v1/background_updates/status` before the next
  jump. Rollback = restore the pre-upgrade dump.
- Recent breaking notes: 1.141 image → trixie/Py3.13; 1.157 MSC3861 removed; 1.163
  `limit_profile_requests_to_users_who_share_rooms` needs `require_auth_for_profile_requests`,
  `request_token_inhibit_3pid_errors` defaults true; 1.164 Python ≥ 3.11, `msc4222_enabled` removed.

### 11.3 Monitoring
`enable_metrics: true` + dedicated `type: metrics` listener (e.g. 9000, not published, not routed)
→ Prometheus `metrics_path: /_synapse/metrics`. Grafana dashboard `contrib/grafana/synapse.json`,
rules `contrib/prometheus/synapse-v2.rules`. MAS has a `prometheus` resource on its internal
listener.

---

## 12. Bridges and bots (v2+)

- **mautrix** bridges are all Go/bridgev2 now (whatsapp/signal/slack/telegram v0.2610.0 — telegram
  Python→Go migration only via v26.04–v26.09; discord still the older Go bridge v0.7.7). Images
  `dock.mau.dev/mautrix/<bridge>:<tag>` (`:latest` = newest commit, pin!). Flow: generate config →
  generate `registration.yaml` → `app_service_config_files` → restart Synapse; one DB per bridge.
  With MAS: bridges need appservice double-puppeting; encrypted bridges need Synapse ≥ 1.141 + MSC4190.
- **matrix-hookshot** v7.6.0 (`ghcr.io/matrix-org/matrix-hookshot`) — GitHub, GitLab, Jira, generic
  webhooks, RSS. **No native Forgejo** → generic webhooks (+ optional JS transformation). Ports: 9000
  webhooks (public), 9993 appservice (internal).
- **maubot** v0.6.0 (`dock.mau.dev/maubot/maubot`) — plugin bot framework, normal client bot.

Design consequence for v1: keep `app_service_config_files` pointing at a directory-backed list
(`/data/appservices/*.yaml`) so later appservices plug in without reworking the template.

---

## 13. Open / unverified items (must be closed during implementation)

| # | Item | How to close |
|---|---|---|
| U1 | Synapse DB password via `PGPASSWORD` env (no `password` in `args`) | spike in the VM; fallback `args.passfile` pointing at a mode-600 file |
| U2 | MAS DB credentials without inline password (`database.password_file` / separate fields?) | read MAS `reference/configuration.md`; fallback: generated mode-600 MAS secrets file (§6.2) |
| U3 | MAS container UID (distroless `nonroot` = 65532?) | `docker inspect` the image `Config.User` |
| U4 | Traefik `PathRegexp` + `priority` for MAS compat routes | VM test: `curl -X POST …/_matrix/client/v3/login` reaches MAS |
| U5 | Client discovery of MAS via `/_matrix/client/v1/auth_metadata` | `curl` on the running stack |
| U6 | Leftover `msc3266_enabled`/`msc4222_enabled` ignored vs fatal | don't set them; nothing to verify unless needed |
| U7 | `msc4354_enabled` needed for calls | test a 3-party call with/without |
| U8 | LiveKit secret min length | generate 64 chars; moot |
| U9 | Signing-key generation command in the image (`generate_signing_key` vs `generate` mode) | `docker run --rm --entrypoint … --help` |
| U10 | Element X in-app registration without MAS | moot — we run MAS |
| U11 | Whether Traefik permanent redirects are 301 or 308 | only relevant if the apex redirects |
| U12 | Element X uses legacy TURN 1:1 calls? | moot with `use_exclusively` + no coturn |
| U13 | iOS trust of profile-installed internal CA | only for the internal-CA variant (not planned) |
| U14 | Forgejo as MAS upstream OIDC provider | out of scope for v1 |
| U15 | `smtp_pass` `_path` variant in Synapse | out of scope for v1 (email off) |

---

## 14. Sources

**Matrix / spec**
- https://matrix.org/docs/chat_basics/matrix-for-im/
- https://matrix.org/ecosystem/servers/
- https://spec.matrix.org/latest/client-server-api/ (well-known, CORS)
- https://spec.matrix.org/latest/server-server-api/ (server name resolution, TLS)
- https://federationtester.matrix.org/
- https://areweoidcyet.com/

**Synapse**
- https://github.com/element-hq/synapse/releases · CHANGES.md · docs/upgrade.md · docs/deprecation_policy.md
- https://github.com/element-hq/synapse/blob/develop/docker/README.md · docker/Dockerfile · docker/start.py · contrib/docker/docker-compose.yml
- https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html
- https://element-hq.github.io/synapse/latest/postgres.html
- https://element-hq.github.io/synapse/latest/reverse_proxy.html · delegate.html · federate.html
- https://element-hq.github.io/synapse/latest/usage/administration/backups.html · admin_faq.html · database_maintenance_tools.html
- https://element-hq.github.io/synapse/latest/admin_api/purge_history_api.html · usage/administration/admin_api/registration_tokens.html
- https://element-hq.github.io/synapse/latest/metrics-howto.html · workers.html
- https://element-hq.github.io/synapse/latest/setup/turn/coturn.html
- https://github.com/element-hq/synapse/blob/develop/synapse/rest/well_known.py
- https://github.com/element-hq/synapse/issues/18993 · #19621 · #19652
- https://docs.element.io/latest/element-server-suite-classic/requirements-and-recommendations/

**Other homeservers**
- https://github.com/element-hq/dendrite · https://github.com/matrix-construct/tuwunel
- https://forgejo.ellis.link/continuwuation/continuwuity · https://gitlab.com/famedly/conduit

**Deployment references**
- https://github.com/element-hq/ess-helm (charts/matrix-stack/values.yaml @ 26.10.3)
- https://github.com/element-hq/ess-helm/security/advisories/GHSA-qwcj-h6m8-vp6q
- https://github.com/spantaleev/matrix-docker-ansible-deploy (docs/configuring-playbook-matrix-rtc.md, …-matrix-authentication-service.md)

**MAS**
- https://element-hq.github.io/matrix-authentication-service/setup/{installation,homeserver,general,database,reverse-proxy,migration}.html
- https://element-hq.github.io/matrix-authentication-service/reference/{configuration,cli/manage}.html
- https://github.com/element-hq/matrix-authentication-service (Dockerfile, docs/setup/sso.md, docs/topics/admin-api.md, releases, issue #4787)

**Clients and calls**
- https://github.com/element-hq/element-web (docs/install.md, docs/config.md, docs/labs.md)
- https://github.com/element-hq/element-x-ios · https://github.com/element-hq/element-x-android
- https://github.com/element-hq/element-meta/issues/3176 · #1915 · https://element.io/blog/element-x-ignition/
- https://github.com/element-hq/element-call/blob/main/docs/self_hosting.md · backend/ · releases v0.24.0, v0.28.0
- https://github.com/element-hq/lk-jwt-service (README, release 0.9.0)
- https://github.com/livekit/livekit/blob/master/config-sample.yaml
- https://docs.livekit.io/home/self-hosting/{deployment,ports-firewall,benchmark}/
- https://github.com/matrix-org/sliding-sync (archived)

**Admin, bridges, bots, misc**
- https://github.com/etkecc/ketesa · https://github.com/Awesome-Technologies/synapse-admin · https://github.com/element-hq/element-admin
- https://docs.mau.fi/bridges/general/docker-setup.html · https://mau.fi/blog/2026-10-mautrix-release/
- https://matrix-org.github.io/matrix-hookshot/latest/setup.html · https://docs.mau.fi/maubot/usage/setup/docker.html
- https://github.com/matrix-org/rust-synapse-compress-state
- https://github.com/docker-library/docs/blob/master/postgres/content.md (PGDATA change in 18)
- https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/ (readTimeout)
