# Task: `tasks/setup-matrix.sh` — fully self-hosted Matrix team chat (Synapse + MAS + Element, optional calls)

**Audience:** an implementation agent picking this up from scratch. The decisions are made here; if
one turns out to be wrong during the spikes in §9 (Phase 0), stop and record why rather than
silently deviating.
**Status:** implemented; see §11 for the spike answers and where the implementation deviates.
**Goal:** one idempotent, converge-on-rerun task that stands up a private Matrix homeserver for a
small team (5–50 users) behind the shared Traefik: Synapse + PostgreSQL + Matrix Authentication
Service (MAS) + Element Web + `.well-known` delegation, with opt-in voice/video calls (LiveKit +
lk-jwt-service), opt-in admin UI (Ketesa), backup integration and kwisatz CLI wiring.

**Technical basis:** `docs/research/2026-10-28-matrix-self-hosting.md` — section references `R§n`
below point there. Load the `karpathy-guidelines` skill before implementing. Read `AGENTS.md` and
`specification/project/conventions.md` (idempotency, converge policy, secrets & templating, stack
health verification, lint). Use `tasks/setup-nextcloud.sh` as the structural model (cleanup trap with
`STACK_CREATED_THIS_RUN`, `--help` before config, `_env_reuse` pattern, `wait_for_healthy` gate,
summary block) and `templates/nextcloud/docker-compose.traefik.yml` as the label model.

---

## 0. Decisions taken (override here before implementation starts)

| # | Decision | Alternative rejected | Reason |
|---|---|---|---|
| D1 | **Synapse** (`matrixdotorg/synapse:v1.164.0`), monolith, no workers | Tuwunel/continuwuity, Dendrite, Conduit | Only server with native SSS + MAS + MatrixRTC + Admin API (R§3). |
| D2 | **PostgreSQL 17** single container, two DBs (`synapse`, `mas`), C locale | PG18; SQLite | Repo standard; PG18 changed its data mount path (R§4.3). |
| D3 | **MAS always on** — no "without MAS" code path | MAS as optional flag | Element X SSO/QR-login/Element Admin need it, Element X is going OIDC-only, later migration is one-way (R§6.1). One path = half the test matrix. |
| D4 | **Traefik required** — no LAN/direct-port mode | nextcloud-style `*_TRAEFIK=false` | Element X needs trusted HTTPS; Matrix without TLS is not a supported deployment. LAN/VPN-only works via Traefik DNS-01 (R§5.4). |
| D5 | **Federation off** by default (`MATRIX_FEDERATION=false`), switchable | federation on | Private team server; no 8448; no public-room RAM blowups (R§5.3). |
| D6 | **Subdomain layout**: `matrix.` Synapse, `auth.` MAS, `chat.` Element Web, `rtc.` LiveKit/JWT, `admin.` Ketesa — all under `MATRIX_SERVER_NAME` by default | Element on the homeserver host | Upstream XSS advice (R§7.1); mirrors ESS defaults. |
| D7 | **Calls opt-in** (`MATRIX_RTC=false` default), LiveKit with **UDP mux** (one UDP port) in bridge networking, **no coturn** | host networking + UDP range; coturn | Smallest port footprint that works; coturn only serves legacy 1:1 calls (R§8.6). |
| D8 | **Push via Element's public gateway**, no Sygnal | own Sygnal | Impossible without own app builds; `event_id_only` leaks no content (R§7.2). |
| D9 | **Bridges, bots, email, upstream SSO, workers, state compressor: out of scope** | — | v2 candidates (R§12); template keeps `app_service_config_files` extensible. |
| D10 | One task script, optional components via **compose profiles** (`COMPOSE_PROFILES` in the project `.env`) | separate `setup-matrix-rtc.sh` | RTC changes Synapse config and `.well-known` — splitting would make two scripts render the same file. Profiles in `.env` also make the backup dispatcher's bare `docker compose up -d` start the right set. |

---

## 1. Target architecture

```
                       Traefik (proxy network, :443, Let's Encrypt)
   ┌───────────────┬───────────────┬───────────────┬───────────────┬────────────────┐
   │ <server_name> │ matrix.<d>    │ auth.<d>      │ chat.<d>      │ rtc.<d>        │ admin.<d> (allowlist)
   │ /.well-known/ │ /_matrix,     │ MAS           │ Element Web   │ /livekit/jwt → │ Ketesa
   │ matrix/*      │ /_synapse/    │               │               │   lk-jwt       │
   │ → wellknown   │ client|mas    │               │               │ /livekit/sfu → │
   │   (nginx)     │ → synapse     │               │               │   livekit:7880 │
   │               │ login|logout| │               │               │                │
   │               │ refresh → MAS │               │               │                │
   └───────────────┴───────────────┴───────────────┴───────────────┴────────────────┘
   internal network "matrix": db (postgres: synapse + mas DBs), synapse:8008, mas:8080/8081, ...
   published directly (RTC only): 7881/tcp (ICE/TCP), 7882/udp (UDP mux)
```

### 1.1 Services (`/srv/matrix/docker-compose.yml`, compose project `matrix`)

| Service | Image var → default | Container | Profile | Networks | Notes |
|---|---|---|---|---|---|
| `db` | `MATRIX_DB_IMAGE` → `postgres:17-alpine` | `matrix-db` | — | matrix | `POSTGRES_USER=synapse`, `POSTGRES_DB=synapse`, `POSTGRES_PASSWORD=${MATRIX_DB_PASSWORD}`, `POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C`; healthcheck `pg_isready`; volume `/srv/matrix/db:/var/lib/postgresql/data` |
| `synapse` | `SYNAPSE_IMAGE` → `matrixdotorg/synapse:v1.164.0` | `matrix-synapse` | — | matrix, proxy | `/srv/matrix/synapse:/data`; env `PGPASSWORD=${MATRIX_DB_PASSWORD}` (U1), `SYNAPSE_CONFIG_PATH=/data/homeserver.yaml`, `UID=991`, `GID=991`; image healthcheck (`/health` on 8008); `depends_on: db: service_healthy`; `restart: unless-stopped` |
| `mas` | `MAS_IMAGE` → `ghcr.io/element-hq/matrix-authentication-service:1.28.0` | `matrix-mas` | — | matrix, proxy | `command: ["server"]`, `MAS_CONFIG=/config/config.yaml:/secrets/mas-secrets.yaml` (exact split per U2); `/srv/matrix/mas/config.yaml:/config/config.yaml:ro`, `/srv/matrix/secrets/mas:/secrets:ro`; `PGPASSWORD=${MAS_DB_PASSWORD}` if U2 confirms sqlx honours it; no healthcheck possible (distroless) → readiness via §4 step 12 |
| `element` | `ELEMENT_IMAGE` → `vectorim/element-web:v1.12.33` | `matrix-element` | — | proxy | `/srv/matrix/element/config.json:/app/config.json:ro`; security-headers middleware |
| `wellknown` | `MATRIX_WELLKNOWN_IMAGE` → `nginx:<pinned>-alpine` (pin the current 1.x stable tag at implementation time) | `matrix-wellknown` | `wellknown` | proxy | serves `/srv/matrix/wellknown/{client,server}` with `default_type application/json`; only when `MATRIX_WELLKNOWN=traefik` |
| `livekit` | `LIVEKIT_IMAGE` → `livekit/livekit-server:v1.13.11` | `matrix-livekit` | `rtc` | matrix, proxy | `command: ["--config", "/etc/livekit.yaml"]`; ports `${LIVEKIT_TCP_PORT}:7881/tcp`, `${LIVEKIT_UDP_PORT}:7882/udp`; 7880 only via Traefik |
| `lk-jwt` | `LK_JWT_IMAGE` → `ghcr.io/element-hq/lk-jwt-service:0.9.0` | `matrix-lk-jwt` | `rtc` | matrix, proxy | env §1.4; `extra_hosts: ["${MATRIX_RTC_DOMAIN}:host-gateway"]` so it reaches LiveKit's *public* URL without hairpin NAT (R§3 MDAD lesson) |
| `admin` | `KETESA_IMAGE` → `ghcr.io/etkecc/ketesa:v1.5.2` | `matrix-admin` | `admin` | proxy | `/srv/matrix/admin/config.json:/var/public/config.json:ro`; router behind `ipAllowList` |

All images come from script-level `*_IMAGE` defaults (lint guard 2/3: no literal/untagged images in
templates). No `privileged:` anywhere (guard 1).

### 1.2 Host layout

```
/srv/matrix/
├── .env                      # 600 root — ALL generated string secrets + COMPOSE_PROFILES + MATRIX_SERVER_NAME
├── docker-compose.yml        # rendered, no secrets (literal ${VAR})
├── db/                       # postgres datadir (not backed up raw — dumps instead)
├── synapse/                  # → /data, owned 991:991
│   ├── homeserver.yaml       # rendered from fragments, no secrets
│   ├── log.config
│   ├── <server_name>.signing.key   # generated ONCE by Synapse's own tool, never overwritten
│   ├── appservices/lk-jwt.yaml     # RTC only (contains as/hs tokens → 600, 991)
│   ├── secrets/              # 700 991 — materialised from .env each run, mode 600
│   │   ├── registration_shared_secret
│   │   ├── macaroon_secret_key
│   │   ├── form_secret
│   │   └── mas_secret
│   └── media_store/
├── mas/config.yaml           # rendered layout, no secrets
├── secrets/mas/              # 700 <mas uid> — mas_secret, encryption, signing keys (U2/U3)
├── element/config.json
├── wellknown/{client,server} # MATRIX_WELLKNOWN=traefik only
├── livekit/livekit.yaml      # RTC only; contains the API key/secret → 600 (see §3 note)
└── admin/config.json         # admin profile only
```

### 1.3 Secrets model (how the repo rule maps onto Synapse/MAS)

The repo rule (*Secrets and templating*): secrets live in `/srv/<svc>/.env` (600), are read back before
generating, never rotate, and are never `envsubst`ed into generated files.

- **String secrets** (`MATRIX_DB_PASSWORD`, `MAS_DB_PASSWORD`, `SYNAPSE_REGISTRATION_SHARED_SECRET`,
  `SYNAPSE_MACAROON_SECRET`, `SYNAPSE_FORM_SECRET`, `MAS_SYNAPSE_SECRET`, `MAS_ENCRYPTION_SECRET`,
  `LIVEKIT_KEY`, `LIVEKIT_SECRET`, `LK_AS_TOKEN`, `LK_HS_TOKEN`, `MATRIX_ADMIN_PASSWORD`): `.env` is the
  single source of truth (`env_file_get` → generate only if empty → `env_file_write`).
- Synapse and MAS read secrets from **files**, not env (`*_path`, `secret_file`; R§4.1). The
  script **materialises** each needed secret from `.env` into its secret file on every run (`printf
  '%s' "$v" | sudo install -m 600 -o 991 -g 991 /dev/stdin <file>`; compare first with `sudo cmp`
  so unchanged files are not touched). The `.env` stays authoritative, and the generated YAML still
  holds no secrets.
- **Key material** (Synapse signing key; MAS private signing keys if U2 picks key files): file-only,
  generated **once** by the upstream tool, never overwritten when present, never derived by our own
  code (ESS CVE, R§2).
- **Unavoidable secret-bearing generated files** — the `livekit.yaml` `keys:` map and the
  `lk-jwt.yaml` appservice registration (tokens inline, there is no file indirection) — are written
  mode 600, owned by the consuming UID. These are the documented exceptions. List them in the
  script header and in `--help`.

### 1.4 lk-jwt-service env (RTC)

`LIVEKIT_URL=wss://${MATRIX_RTC_DOMAIN}/livekit/sfu`, `LIVEKIT_KEY=${LIVEKIT_KEY}`,
`LIVEKIT_SECRET=${LIVEKIT_SECRET}`, `LIVEKIT_FULL_ACCESS_HOMESERVERS=${MATRIX_SERVER_NAME}` (never `*`),
`LIVEKIT_JWT_BIND=:8080`, `LIVEKIT_HS_SERVER_NAME=${MATRIX_SERVER_NAME}`,
`LIVEKIT_AS_TOKEN=${LK_AS_TOKEN}`, `LIVEKIT_HS_TOKEN=${LK_HS_TOKEN}`, and — if U16 confirms the
format — `LIVEKIT_CS_API_URL_OVERRIDES=${MATRIX_SERVER_NAME}=http://synapse:8008` so OpenID
validation does not depend on public DNS/TLS.

---

## 2. Configuration surface (final — header comment and `--help` must match)

| Var | Default | Notes |
|---|---|---|
| `MATRIX_SERVER_NAME` | **required** | e.g. `example.com`. **Immutable** after first run (stored in `.env`; a different value on re-run is a hard error, §5). |
| `MATRIX_DOMAIN` | `matrix.${MATRIX_SERVER_NAME}` | Synapse public host (`public_baseurl`). May equal `MATRIX_SERVER_NAME`. |
| `MATRIX_AUTH_DOMAIN` | `auth.${MATRIX_SERVER_NAME}` | MAS `public_base` |
| `MATRIX_CHAT_DOMAIN` | `chat.${MATRIX_SERVER_NAME}` | Element Web |
| `MATRIX_RTC_DOMAIN` | `rtc.${MATRIX_SERVER_NAME}` | LiveKit + lk-jwt (RTC only) |
| `MATRIX_ADMIN_DOMAIN` | `admin.${MATRIX_SERVER_NAME}` | Ketesa (admin UI only) |
| `MATRIX_WELLKNOWN` | `synapse` if `MATRIX_DOMAIN == MATRIX_SERVER_NAME`, else `traefik` | `traefik` = nginx container on the apex; `synapse` = Synapse serves it; `external` = print the JSON for the operator to host elsewhere |
| `MATRIX_FEDERATION` | `false` | `true` adds the `federation` listener resource, publishes `.well-known/matrix/server`, sets `trusted_key_servers: matrix.org` |
| `MATRIX_RTC` | `false` | Calls (LiveKit + lk-jwt), adds profile `rtc` |
| `MATRIX_ADMIN_UI` | `false` | Ketesa, adds profile `admin` |
| `MATRIX_ADMIN_ALLOW_CIDRS` | `127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10` | `ipAllowList` for `/_synapse/admin` and the admin UI (100.64/10 = NetBird) |
| `MATRIX_ADMIN_USER` | `admin` | First MAS admin, created at first install only |
| `MATRIX_ADMIN_PASSWORD` | generated, stored in `.env` | Applied at first install only (like nextcloud); change with `mas-cli manage set-password` |
| `MATRIX_E2EE_DEFAULT` | `invite` | `encryption_enabled_by_default_for_room_type` (`all`/`invite`/`off`) |
| `MATRIX_MAX_UPLOAD` | `50M` | `max_upload_size`. Above ~100M see Traefik `readTimeout` (R§5.6) |
| `MATRIX_URL_PREVIEWS` | `true` | Always with the full IP blacklist + the docker network subnets |
| `MATRIX_METRICS` | `false` | Adds a `metrics` listener on 9000 (not published) + `prometheus.scrape=true` / `prometheus.port=9000` labels (monitoring stack opt-in, see `templates/monitoring/prometheus.yml`) |
| `LIVEKIT_TCP_PORT` / `LIVEKIT_UDP_PORT` | `7881` / `7882` | Published host ports (RTC) |
| `LIVEKIT_NODE_IP` | empty → `use_external_ip: true` | Set to the NetBird/LAN IP for VPN-only deployments |
| `PROXY_NETWORK` | `proxy` | Traefik's external network |
| `MATRIX_HOME` | `/srv/matrix` | |
| `WAIT_TIMEOUT` | `300` | health gate + readiness polls |
| `*_IMAGE` | see §1.1 | pinned; bump deliberately, read Synapse `upgrade.md` |

Flags: `--help`, `--interactive` (offer tear-down/re-create, converge is the default answer), `--force`
/ `MATRIX_FORCE=true` (re-create containers; **never** touches `db/`, `synapse/`, `secrets/`).

### DNS prerequisites (print in `--help` and the summary)
A/AAAA (or NetBird DNS records for VPN-only): `MATRIX_DOMAIN`, `MATRIX_AUTH_DOMAIN`, `MATRIX_CHAT_DOMAIN`,
+ `MATRIX_RTC_DOMAIN` (RTC), `MATRIX_ADMIN_DOMAIN` (admin UI), + `MATRIX_SERVER_NAME` when
`MATRIX_WELLKNOWN=traefik`. For VPN-only setups, Traefik must run with `DNS_PROVIDER` (DNS-01) because
HTTP-01 cannot reach the host.

---

## 3. Files to create / modify

### Create
| Path | Content |
|---|---|
| `tasks/setup-matrix.sh` | the task (§4) |
| `templates/matrix/docker-compose.yml` | all services from §1.1, with profiles. Secrets as literal `${VAR}`; layout values `envsubst`ed. Traefik labels per §3.1 |
| `templates/matrix/synapse/homeserver.base.yaml` | everything common (R§4.2–4.5): `server_name`, `public_baseurl`, `pid_file`, listener with `${SYNAPSE_LISTENER_RESOURCES}`, database (no password, U1), `signing_key_path`, the `*_path` secrets, `matrix_authentication_service` (`secret_path`), `report_stats: false`, `enable_registration: false`, `suppress_key_server_warning: true`, `max_upload_size`, URL-preview block + blacklist, `encryption_enabled_by_default_for_room_type`, `push.include_content: false`, `media_store_path`, `forgotten_room_retention_period: 28d`, `app_service_config_files: ${SYNAPSE_APPSERVICE_FILES}`, `log_config` |
| `templates/matrix/synapse/private.yaml` | `federation_domain_whitelist: []`, `trusted_key_servers: []` |
| `templates/matrix/synapse/federation.yaml` | `trusted_key_servers: [{server_name: matrix.org}]`, `media_retention.remote_media_lifetime: 14d`, `serve_server_wellknown: true` only in `synapse` well-known mode (render `${SYNAPSE_SERVE_SERVER_WELLKNOWN}`) |
| `templates/matrix/synapse/rtc.yaml` | R§8.3 block: `experimental_features` (msc4143/4502/4512), `max_event_delay_duration: 24h`, `rc_message`, `rc_delayed_event_mgmt`, `matrix_rtc.transports` (`url` + `livekit_service_url`), `extra_well_known_client_content` with `org.matrix.msc4143.rtc_foci` (used in `synapse` well-known mode) |
| `templates/matrix/synapse/metrics.yaml` | `enable_metrics: true` + metrics listener |
| `templates/matrix/synapse/log.config` | console logging at INFO (stdout → `docker logs`) |
| `templates/matrix/mas/config.yaml` | R§6.3 layout (`http`, `database` without password, `matrix`, `passwords`, `account`, `email: blackhole`), `secret_file` paths |
| `templates/matrix/element/config.json` | R§7.1 (`default_server_config`, `disable_custom_urls`, `disable_guests`, `permalink_prefix`, `show_labs_settings: false`, `element_call.use_exclusively: ${ELEMENT_CALL_EXCLUSIVE}`) |
| `templates/matrix/wellknown/client` · `server` · `nginx.conf` | R§5.1 JSON (client gets `rtc_foci` only when RTC — render two variants `client` / `client.rtc` and pick one); nginx with `default_type application/json` + CORS headers in nginx (avoid relying on Traefik overriding `Content-Type`) |
| `templates/matrix/livekit/livekit.yaml` | R§8.5 with `udp_port`, `room.auto_create: false`, `turn.enabled: false`, webhook → `http://lk-jwt:8080/sfu_webhook` (internal) |
| `templates/matrix/livekit/lk-jwt-appservice.yaml` | R§8.4 registration (tokens rendered → the mode-600 exception, §1.3) |
| `templates/matrix/admin/config.json` | Ketesa `{"restrictBaseUrl": "https://${MATRIX_DOMAIN}"}` |
| `README_MATRIX.md` | operator/user guide: DNS, first login, adding users (`mas-cli manage register-user` / registration tokens), onboarding text for the team (install Element X, **save your recovery key**), enabling calls, backup/restore, upgrade procedure, federation switch-on checklist |

### Modify
| Path | Change |
|---|---|
| `lib/docker-backup.sh` | add `matrix` to `bk_service_home` (`${MATRIX_HOME:-/srv/matrix}`), to the dump dispatcher (two dumps from `matrix-db`: `synapse` → `matrix-<ts>.dump`, `mas` → `matrix-<ts>.mas.dump`), and to the restore dispatcher (see §6), and to the "supported" lists/error messages |
| `tasks/setup-backup-client.sh` | the supported-services list in help/validation, if it is enumerated there |
| `machine-config.yml.example` | `setup-matrix:` block (`enabled: false`, description, commented env: `MATRIX_SERVER_NAME`, `MATRIX_RTC`, `MATRIX_FEDERATION`), placed **after** `setup-traefik`; add `matrix` to the `BACKUP_SERVICES` comment list |
| `src/kwisatz/data/prerequisites.yml` | `requires: setup-matrix: [setup-docker, setup-traefik]`, `host: setup-matrix: {docker: true}` |
| `tests/machine-config.test.yml` | `setup-matrix` ad-hoc entry (disabled; `MATRIX_SERVER_NAME: matrix.test`, `MATRIX_RTC: "true"`) |
| `AUTOMATIONS.md` | `setup-matrix.sh` section (features, ports, profiles, link to README_MATRIX.md); add `matrix` to the backup `--services` list |
| `CONTEXT.md` | terms: **homeserver**, **server_name**, **MAS**, **Element / Element X**, **MatrixRTC / LiveKit / lk-jwt-service**, **well-known delegation** |
| `README.md` | add Matrix to the services list line |
| `.tickets/` | one ticket per phase (§9), per repo workflow |

### 3.1 Traefik labels (sketch — verify in Phase 0; `$$` escaping as in the nextcloud template)

```yaml
# synapse
- "traefik.enable=true"
- "traefik.docker.network=${PROXY_NETWORK}"
- "traefik.http.routers.matrix.rule=Host(`${MATRIX_DOMAIN}`) && (PathPrefix(`/_matrix`) || PathPrefix(`/_synapse/client`) || PathPrefix(`/_synapse/mas`)${SYNAPSE_WELLKNOWN_RULE})"
- "traefik.http.routers.matrix.entrypoints=websecure"
- "traefik.http.routers.matrix.tls.certresolver=letsencrypt"
- "traefik.http.routers.matrix.service=matrix"
- "traefik.http.services.matrix.loadbalancer.server.port=8008"
- "traefik.http.routers.matrix-admin-api.rule=Host(`${MATRIX_DOMAIN}`) && PathPrefix(`/_synapse/admin`)"
- "traefik.http.routers.matrix-admin-api.entrypoints=websecure"
- "traefik.http.routers.matrix-admin-api.tls.certresolver=letsencrypt"
- "traefik.http.routers.matrix-admin-api.service=matrix"
- "traefik.http.routers.matrix-admin-api.middlewares=matrix-allowlist@docker"
- "traefik.http.middlewares.matrix-allowlist.ipallowlist.sourcerange=${MATRIX_ADMIN_ALLOW_CIDRS}"
# mas
- "traefik.http.routers.mas.rule=Host(`${MATRIX_AUTH_DOMAIN}`)"
- "traefik.http.routers.mas-compat.rule=Host(`${MATRIX_DOMAIN}`) && PathRegexp(`^/_matrix/client/[^/]+/(login|logout|refresh)`)"
- "traefik.http.routers.mas-compat.priority=1000"
- "traefik.http.services.mas.loadbalancer.server.port=8080"
# livekit (rtc)
- "traefik.http.routers.lk-sfu.rule=Host(`${MATRIX_RTC_DOMAIN}`) && PathPrefix(`/livekit/sfu`)"
- "traefik.http.routers.lk-sfu.middlewares=lk-sfu-strip@docker"
- "traefik.http.middlewares.lk-sfu-strip.stripprefix.prefixes=/livekit/sfu"
- "traefik.http.services.lk-sfu.loadbalancer.server.port=7880"
# lk-jwt (rtc): same with /livekit/jwt → 8080
```
- `${SYNAPSE_WELLKNOWN_RULE}` = ` || PathPrefix(\`/.well-known/matrix\`)` in `synapse` well-known mode, else empty.
- Element: HTTP→HTTPS redirect router on `web` (nextcloud pattern) + security headers middleware
  (`customFrameOptionsValue=SAMEORIGIN`, `contentTypeNosniff=true`, `browserXssFilter=true`,
  `contentSecurityPolicy=frame-ancestors 'self'`) + HSTS.
- Every router gets `entrypoints=websecure` + `tls.certresolver=letsencrypt` (check the resolver
  name in `templates/traefik/traefik.*.yml` first, and add a web→websecure redirect where the
  nextcloud template has one).

---

## 4. Script flow (`tasks/setup-matrix.sh`)

Skeleton and helper usage copied from `setup-nextcloud.sh` (colours, `info/success/warn/error/step`,
`source lib/helpers.sh`, trap). Check `lib/helpers.sh` before writing any new helper; only
`env_file_get`, `env_file_write` and `wait_for_healthy` are expected to be needed.

1. **Parse args** (`--help` before anything touches `.env`; `--interactive`, `--force`).
2. **Config + validation** — defaults (§2). `MATRIX_SERVER_NAME` required; derive domains; validate
   `MATRIX_WELLKNOWN ∈ {traefik,synapse,external}`, `MATRIX_E2EE_DEFAULT ∈ {all,invite,off}`, booleans.
3. **Pre-flight** — docker + compose v2, `openssl`, `envsubst`, `PROXY_NETWORK` exists (else: "run
   `kwisatz apply traefik` first"), warn if Traefik has no `DNS_PROVIDER` but a domain does not
   resolve publicly (informational only).
4. **Identity guard** — if `.env` exists and its `MATRIX_SERVER_NAME` differs from the requested one:
   **error (exit 1)**. Explain that `server_name` is immutable and that changing it means a new
   server (wipe `/srv/matrix`, by hand). This is a deliberate deviation from "print + exit 0":
   continuing with the old name would ignore the config, and the only fix is destructive.
5. **Existing stack** — converge by default; with `--interactive`, offer re-create (`down` without
   `-v`; bind mounts are never deleted).
6. **Directories** — create the §1.2 tree; `synapse/` → `991:991`; `secrets/` dirs 700; MAS secrets
   owner = MAS UID (U3).
7. **Secrets** — the `_env_reuse` pattern for every §1.3 string secret (`openssl rand -hex 32`;
   LiveKit key `openssl rand -hex 8` prefixed `lk`, secret 64 hex). Write `.env` (600) with backup
   on change (`sudo cmp` pattern). Also persist `MATRIX_SERVER_NAME` and
   `COMPOSE_PROFILES=<wellknown?,rtc?,admin?>` (comma list, may be empty).
8. **Materialise secret files** from `.env` (§1.3), touching only the files that changed.
9. **Signing key** — if `/srv/matrix/synapse/<server_name>.signing.key` is absent, generate it with
   the image's own tool (U9: `docker run --rm --entrypoint generate_signing_key … -o /data/…`, or a
   throwaway `generate` into a temp dir, keeping only the key). Never regenerate it, and never
   continue if the file exists but is empty: error.
10. **MAS key material** (U2) — generate once if absent; never overwrite.
11. **Render** — as the invoking user into `mktemp`, then `sudo install -m 644/600`:
    `homeserver.yaml` = `base` + (`private` | `federation`) + (`rtc`?) + (`metrics`?), each
    `envsubst` with an **explicit variable list** (`envsubst '${A} ${B}'`) so `$`-strings in YAML
    survive. Then `mas/config.yaml`, `element/config.json`, `wellknown/*`, `livekit/*`,
    `admin/config.json`, `docker-compose.yml`. Validate the JSON outputs with `jq empty` and
    `docker compose config -q` before `up`. Render the docker subnet of the `matrix` network into
    the URL-preview blacklist (inspect it on re-runs; on first run, fix the subnet in the compose
    `ipam` config, e.g. `MATRIX_NET_SUBNET=172.31.240.0/24`, so it is known up front).
12. **Bring up in order** (set `STACK_CREATED_THIS_RUN=1` before the first `up`, only if no
    stack was running):
    1. `docker compose up -d db` → `wait_for_healthy`.
    2. **Ensure the MAS role/DB** idempotently via `docker exec matrix-db psql -U synapse`: create
       role `mas` with `MAS_DB_PASSWORD` if missing, otherwise `ALTER ROLE … PASSWORD` to keep it
       in sync with `.env`; `CREATE DATABASE mas OWNER mas TEMPLATE template0 ENCODING 'UTF8'
       LC_COLLATE 'C' LC_CTYPE 'C'` if missing. Pass the password through `-v` / stdin, never on
       the command line.
    3. Also assert that the `synapse` DB has `C` collation (`SELECT datcollate …`). Error out with a
       clear message otherwise, because Synapse would refuse to start anyway.
    4. `docker compose up -d` (all services of the active profiles) → `wait_for_healthy
       "$WAIT_TIMEOUT" $(docker compose ps -q) || error …`.
    5. **Readiness polls** (bounded by `WAIT_TIMEOUT`):
       - Synapse: `docker exec matrix-synapse curl -fsS http://localhost:8008/health`.
       - MAS: `docker exec matrix-synapse curl -fsS http://mas:8081/health`. The Synapse
         container has curl; MAS is distroless.
       - Through Traefik:
         `curl -fsS --resolve ${MATRIX_DOMAIN}:443:127.0.0.1 https://${MATRIX_DOMAIN}/_matrix/client/versions`,
         plus the `.well-known/matrix/client` check (CORS header present).
       - The Traefik checks use `-k` only if a strict first attempt fails, and then print a
         certificate **warning**, which is the VM/no-ACME case.
13. **Bootstrap the admin** — on first install only: if `mas-cli manage list-admin-users` does not
    list `MATRIX_ADMIN_USER`, run
    `docker exec matrix-mas mas-cli manage register-user --yes "$MATRIX_ADMIN_USER" --password "$pw" --admin`.
    The password must not appear in `ps` output, so check whether `register-user` can read it from
    stdin (U17). On re-run, if the password in `.env` differs from what was applied, warn with the
    `set-password` command, as nextcloud does.
14. **`mas-cli config sync`** after every render (no `--prune`).
15. **ufw** (RTC only): `sudo ufw allow ${LIVEKIT_TCP_PORT}/tcp comment 'matrix livekit ice/tcp'`
    and `${LIVEKIT_UDP_PORT}/udp`. Print the note that docker-published ports bypass ufw INPUT
    (R§9). Never open 8448.
16. **External well-known mode** — print both JSON documents and the required CORS headers.
17. **Summary** — URLs, admin user, the location of the password (`.env`), DNS records, the next
    steps (`mas-cli manage register-user`, `issue-user-registration-token`), a pointer to
    README_MATRIX.md, and a reminder to add `matrix` to `BACKUP_SERVICES`. Clear
    `STACK_CREATED_THIS_RUN` only after this point.

---

## 5. Re-run / divergence behaviour (conventions: converge by default)

| Change on re-run | Behaviour |
|---|---|
| Nothing | Re-render: identical files leave containers untouched; `up -d` is a no-op; health gate runs; exit 0 |
| Image tag bump | `up -d` recreates the affected service; Synapse migrates its schema on start; the summary warns to read `upgrade.md` and to take a backup first |
| `MATRIX_RTC` / `MATRIX_ADMIN_UI` / `MATRIX_FEDERATION` / `MATRIX_METRICS` toggled | Converges: `COMPOSE_PROFILES` and `homeserver.yaml` are re-rendered, `up -d --remove-orphans` stops services that left the profiles, Synapse restarts because its config changed (compare checksums and run `docker compose restart synapse` when `homeserver.yaml` changed, since a bind-mounted file change does not recreate the container) |
| Domains (`MATRIX_DOMAIN`, …) changed | Converges (labels and config re-rendered). Warn that clients have the old URL cached |
| `MATRIX_SERVER_NAME` changed | **Hard error** (§4 step 4) |
| `MATRIX_ADMIN_PASSWORD` changed | Not applied: print the `mas-cli manage set-password` command (same as the nextcloud admin password row in conventions) |
| Secrets in `.env` | Never rotated. `MAS_DB_PASSWORD` is re-asserted with `ALTER ROLE` (harmless) |

Add a **`matrix`** bullet to the *Re-run policy* list in `specification/project/conventions.md`
covering the admin-password and server_name rows.

Also apply the same restart rule to MAS (`mas/config.yaml`) and LiveKit (`livekit.yaml`): if the
rendered file's checksum changed, restart that service.

---

## 6. Backup & restore integration (`lib/docker-backup.sh`)

- **Dump** (hot): `bk_pg_dump matrix-db synapse "${dump}.dump"` and `bk_pg_dump matrix-db mas
  "${dump}.mas.dump"`. The helper reads `POSTGRES_USER`/`POSTGRES_PASSWORD` from the container env,
  and since `synapse` is the superuser it can dump both DBs.
- **Restore**: handle `*.mas.dump` before the generic `*.dump`.
  1. Stop `synapse` and `mas`, but not `db`.
  2. Check whether `bk_pg_restore` drops and recreates the DB, and with which locale. The matrix
     DBs **must** be recreated with `TEMPLATE template0 ENCODING UTF8 LC_COLLATE 'C' LC_CTYPE 'C'`
     (R§11.1). Extend the helper with an optional locale argument rather than duplicating it.
  3. After the synapse restore, run `TRUNCATE e2e_one_time_keys_json;` before starting Synapse.
  4. Start the stack and run `bk_wait_running`.
- **Files**: `/srv/matrix` is covered by `/srv` in `BACKUP_PATHS`. Document recommended
  `BACKUP_EXCLUDE_REGEXES` for `^/srv/matrix/db/` (raw datadir, covered by the dump) and
  `^/srv/matrix/synapse/media_store/(remote_content|remote_thumbnail|url_cache)` (caches). Check
  how the nextcloud `db/` dir is handled today and copy that mechanism if one exists.
- The signing key, `.env`, and the secret files are therefore in the borg archive, which is
  encrypted. That is required: without the signing key and secrets a restore is not the same server.
- AUTOMATIONS/README backup notes: add `matrix` to the supported list.

---

## 7. Verification & tests

**Lint** (AGENTS.md): `shellcheck tasks/setup-matrix.sh lib/docker-backup.sh`; `yamllint` on every
template `.yml`/`.yaml` (render them first if `${…}` placeholders trip the linter, as the existing
templates do); `jq empty` on JSON templates; `tests/lint.sh` (image pin guards);
`uv run pytest` (prerequisites.yml / example config parse).

**VM test** (`tests/run-vm-tests.sh --scripts setup-docker,setup-traefik,setup-matrix`, with
`MATRIX_SERVER_NAME=matrix.test`, `MATRIX_RTC=true`). ACME cannot issue in the VM, so the checks
use `--resolve … -k`. Pass criteria:

1. First run exits 0, and all containers are running or healthy.
2. `curl -k --resolve matrix.test:443:127.0.0.1 https://matrix.test/_matrix/client/versions`
   returns JSON listing `v1.1x`. The `.well-known/matrix/client` response carries
   `Access-Control-Allow-Origin: *`.
3. `curl … https://matrix.test/_matrix/federation/v1/version` returns 404 (private mode).
4. `curl -k --resolve matrix.test:443:127.0.0.1 https://matrix.test/_synapse/admin/v1/server_version`
   is allowed from 127.0.0.1, and the router carries the allowlist middleware.
5. **Login smoke test through MAS compat:**
   `POST /_matrix/client/v3/login {"type":"m.login.password","identifier":{"type":"m.id.user","user":"admin"},"password":…}`
   returns an `access_token`. Then `createRoom` → `send` → `/sync` shows the event. This closes U4.
6. Run the script a second time: exit 0, and nothing changed:
   - the `sha256sum` of `.env`, the signing key and the secret files is identical;
   - no container was recreated (`docker inspect -f '{{.State.StartedAt}}'` is unchanged);
   - no `Recreate` appears in the `docker compose up` output.
7. Toggle `MATRIX_ADMIN_UI=true` and re-run: `matrix-admin` comes up, and the rest of the stack is
   unchanged apart from the labels.
8. Re-run with a different `MATRIX_SERVER_NAME`: exits 1 with the identity message, and nothing on
   disk changed.
9. RTC: `curl -k --resolve rtc.test:443:127.0.0.1 https://rtc.test/livekit/jwt/healthz` (check the
   real endpoint name, U18) returns 200; `ss -lunp` shows 7882 published; `ufw status` lists 7881
   and 7882.
10. Backup round trip:
    `setup-backup-client.sh --local … --services matrix`, then dump, then restore into the same VM.
    Login works afterwards with the same user and room, and the signing key is unchanged.

**Manual acceptance on a real domain** (record the results in the ticket):
- federationtester shows a failure by design when private, and passes when `MATRIX_FEDERATION=true`.
- Element Web login via MAS.
- Element X login on iOS and Android (via `.well-known` discovery).
- A 3-person video call from Element X and Element Web. This closes U7: test without
  `msc4354_enabled` first.
- A push notification arrives on a locked phone.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| The MatrixRTC config surface is still moving (transports and appservice mode are new; Element Call docs are stale) | RTC is opt-in, versions are pinned, both the `url` and `livekit_service_url` modes and the `.well-known` `rtc_foci` are published; re-check upstream docs at implementation time |
| A wrong `server_name` is permanent | Make it a required variable with no default, add the identity guard, and spell out the choice in the README |
| Docker-published LiveKit ports bypass ufw | Publish only the two required ports; document it; set `room.auto_create: false` so the SFU cannot be abused without a JWT |
| Loss of the signing key or secrets equals a different server | They are in the borg archive; the restore test proves it; the README states it |
| Users lose E2EE history on a new device or after a password reset | The README onboarding section covers the recovery key (R§2) |
| Push metadata (room and event IDs, timing) reaches matrix.org, Apple and Google | Accepted (D8); documented; `push.include_content: false` |
| Hairpin NAT: lk-jwt can't reach `wss://rtc.<d>` | `extra_hosts: host-gateway` (§1.1); U16 override |
| Traefik's 60 s `readTimeout` truncates big uploads | 50M default; documented; raising it is a `setup-traefik.sh` change, out of scope here |
| PostgreSQL 14 EOL and Synapse raising its minimum | Already on 17. A PG major upgrade is a separate, deliberate procedure (dump/restore), never automatic, following the nextcloud `PG_VERSION` follow rule |

---

## 9. Phases (one ticket each in `.tickets/`, one feature branch via `git worktree`, merged to `develop`)

**Phase 0 — spikes (≈ ½ day, in the VM, throwaway compose).** Close these before writing the
script and record the answers in the ticket:

| ID | Question | Fallback if the answer is "no" |
|---|---|---|
| U1 | Does Synapse connect when `PGPASSWORD` is set and `args.password` is omitted? | `args.passfile` → a mode-600 file materialised from `.env` |
| U2 | How can MAS get its DB password and keys without inline secrets? Options: `database.password` field vs `PGPASSWORD` (sqlx), `secrets.encryption_file`, `secrets.keys[].key_file`. Use the MAS configuration reference | Generate `mas-secrets.yaml` once (mode 600) with `mas-cli config generate`, extract its `secrets:`/`database` part, and document it as an exception |
| U3 | What UID does the MAS image run as (`docker inspect`)? | — |
| U4 | Do the Traefik `PathRegexp` + `priority` labels route compat login to MAS? | Use explicit `Path()` alternatives for r0/v3 |
| U5 | Is MAS discovered via `/_matrix/client/v1/auth_metadata`? | `.well-known` `org.matrix.msc2965.authentication` entry |
| U9 | Which command in the image generates the signing key? | `generate` into a temp dir and keep only the key |
| U16 | What is the `LIVEKIT_CS_API_URL_OVERRIDES` format? | `extra_hosts` for `MATRIX_DOMAIN` too |
| U17 | Can `mas-cli manage register-user` take the password without it showing in argv? | Accept the brief argv exposure inside the container and document it |
| U18 | What is the lk-jwt health endpoint? | Check the port is reachable from inside the network |

**Phase 1 — core.** `db`, `synapse`, `mas`, `element`, `wellknown`. Private mode, admin bootstrap,
health gates, re-run convergence, `--help`, the CLI wiring (machine-config example,
prerequisites.yml, test config), and AUTOMATIONS/CONTEXT entries. Done when VM tests 1–3, 5, 6 and
8 pass.

**Phase 2 — calls.** `livekit` and `lk-jwt`, `rtc.yaml`, the appservice registration, ufw rules,
`element_call.use_exclusively`. Done when VM test 9 passes and the manual 3-person call works.

**Phase 3 — operations.** Backup and restore dispatcher, the Ketesa admin UI with its allowlist,
the metrics fragment and monitoring labels, the federation toggle. Done when VM tests 4, 7 and 10
pass and federationtester passes with `MATRIX_FEDERATION=true`.

**Phase 4 — documentation and release.** README_MATRIX.md (operator and team onboarding), the
README services line, and a conventions.md re-run bullet. This is a **MINOR** release (new task
script), with release notes in `docs/releases/`.

**Later / v2 backlog (not in this plan):** matrix-hookshot for Forgejo/CI webhooks; Element Admin
once it is past 0.x; email (MAS + Synapse SMTP) for password recovery; MAS `upstream_oauth2` SSO
(Forgejo/Authentik); mautrix bridges; `synapse_auto_compressor`; coturn or LiveKit embedded TURN
for strict-firewall users; Synapse workers if the team ever exceeds a few hundred users.

---

## 10. Success criteria (whole feature)

1. `kwisatz apply matrix` on a fresh box with Docker and Traefik yields, within `WAIT_TIMEOUT`, a
   working private homeserver. A team member can log in with Element Web and Element X, chat in
   E2EE rooms and receive mobile push.
2. Re-running is a verified no-op (VM test 6), and the toggles converge without data loss.
3. With `MATRIX_RTC=true`, group and 1:1 calls work from Element X and Element Web.
4. Backup and restore round-trips in the VM: same identity, same users, same rooms.
5. Every new or changed file passes linting, and `tests/lint.sh` and `uv run pytest` are green.

---

## 11. Implementation notes (2026-10-28)

**Spike answers.** U1/U2: Synapse (libpq) and MAS (sqlx) both read the DB password from
`PGPASSWORD`; MAS takes `secrets.encryption_file` and `secrets.keys[].key_file`, so no generated
config holds a secret. U3: MAS runs as UID 65532. U4: the `PathRegexp` + `priority` compat route
works. U5: `/_matrix/client/v1/auth_metadata` advertises MAS. U9: `generate_signing_key -o`.
U16: `LIVEKIT_CS_API_URL_OVERRIDES` is `server_name=url`. U17: `register-user` takes the password
only on argv (accepted, documented). U18: lk-jwt has `/healthz` and an image healthcheck.
LiveKit reads its key pair from `LIVEKIT_KEYS`, and lk-jwt reads the appservice registration
file, so `livekit.yaml` holds no secret.

**Deviations from the plan above.**
- Route checks through Traefik only warn while no certificate exists. Traefik runs `sniStrict`,
  so before DNS/ACME are in place the TLS handshake is refused and `-k` cannot help.
- `/.well-known/matrix/server` is published whenever calls are on, also on a private server.
  lk-jwt validates OpenID tokens through federation server discovery, which
  `LIVEKIT_CS_API_URL_OVERRIDES` does not cover. lk-jwt's `extra_hosts` therefore also maps the
  homeserver host and the apex to the host gateway.
- The lk-jwt appservice registration uses `url: null`. lk-jwt 0.9.0 has no transaction endpoint,
  and the membership check and the proxy do not need it.
- The backup also writes `matrix-<ts>.identity.tar` (`.env`, signing key, secrets). Borg runs as
  a non-root user and cannot read those mode-600 files. `synapse/` is mode 755 so uploads are
  backed up.
- There is no fixed `ipam` subnet: the URL-preview blacklist already covers every docker default
  pool.
- `MATRIX_SERVER_NAME` defaults to the stored value on re-runs; it is required only on the first
  run.

