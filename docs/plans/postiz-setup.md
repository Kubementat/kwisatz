# Plan: `tasks/setup-postiz.sh` — Postiz social-media scheduler (Docker Compose)

Date: 2026-09-30 (draft) — **implemented 2026-10-01** (see *Resolved open questions*)
Source: `~/main_vault/research/content-distribution-platforms-research-2026-09-30.md`
(Option A: Postiz self-hosted on Evobox + pi as author via Postiz MCP server)
Reference: official `gitroomhq/postiz-docker-compose` (checked 2026-09-30, `main` branch)

## Goal

New task script `tasks/setup-postiz.sh` + template dir `templates/postiz/` that deploys
**Postiz** (self-hosted social-media scheduler, 28+ platforms incl. LinkedIn, X, Reddit,
dev.to-adjacent networks) idempotently via Docker Compose, in the house style
(cf. `setup-planka.sh` / `setup-n8n.sh`):

1. `templates/postiz/docker-compose.yml` — Postiz app + PostgreSQL + Redis + Temporal stack,
   based on the official compose with kwisatz hardening (pinned tags, no secrets in the file,
   loopback-only debug ports, prefixed volumes).
2. `templates/postiz/dynamicconfig/development-sql.yaml` — required Temporal dynamic config
   (the official compose mounts this directory; without it Temporal does not come up).
3. `tasks/setup-postiz.sh` — env-var driven (all optional, sensible defaults), secrets in
   `POSTIZ_HOME/.env` (mode 600, generated once, reused on re-runs), Traefik integration
   opt-in, health-gated startup wait, post-install checklist output (admin org + API key +
   platform integrations are UI steps, not script steps).
4. Registration: `machine-config.yml.example` entry, `AUTOMATIONS.md` entry, README service
   list, `tests/machine-config.test.yml` entry.

Driver: the campaign "Make the Work Visible" (Quest D2) needs one queue where pi can push
the per-blog-post derivative set (LinkedIn DE / X EN / dev.to EN / Reddit staggered) with a
human approval gate. Postiz provides calendar, stagger, approval and an MCP server the pi
agent can drive directly.

## Decisions

| # | Decision |
|---|---|
| 1 | **Temporal is in the stack, not optional.** Postiz v2.12+ requires Temporal for cron/scheduled posting (`RUN_CRON=true`). We ship the official 6-container Temporal set (auto-setup + its postgres + elasticsearch + admin-tools + ui) unmodified in behaviour — proven > clever. |
| 2 | **Slim, but only where the official compose is already conservative:** drop `spotlight` (debug profile service), drop `temporal-admin-tools` interactive tty container (keep the image pull? no — drop it entirely; `docker exec temporal temporal …` covers CLI needs). `temporal-ui` stays, bound to **127.0.0.1:18080** only (official uses 8080; offset to avoid common collisions, still reachable via SSH tunnel / LAN proxy if ever needed). |
| 3 | **Secrets live in `POSTIZ_HOME/.env`** (default `/srv/postiz`, mode 600): `JWT_SECRET`, `POSTGRES_PASSWORD`, `TEMPORAL_POSTGRES_PASSWORD`. Generated once with `openssl rand`, reused on re-runs; explicit env overrides honoured. The rendered `docker-compose.yml` contains only `${VAR}` placeholders (planka convention, `--env-file` at runtime). |
| 4 | **All images pinned** (no `latest`), matching the official compose as of 2026-09-30: `ghcr.io/gitroomhq/postiz-app:v2.24.0` (**pin recorded 2026-10-01** — newest GHCR multi-arch release tag, matching GitHub release v2.24.0 of 2026-09-22), `postgres:17-alpine` (Postiz DB), `postgres:16` (Temporal DB), `redis:7.2`, `elasticsearch:7.17.27`, `temporalio/auto-setup:1.28.1`, `temporalio/ui:2.34.0`. |
| 5 | **Traefik opt-in** (house pattern): `POSTIZ_TRAEFIK=true POSTIZ_DOMAIN=postiz.example.com` adds the traefik labels + joins `PROXY_NETWORK` (default `proxy`) and removes the published port; default mode publishes `HTTP_PORT` (4007, official default) on 0.0.0.0 for LAN use. `MAIN_URL`/`FRONTEND_URL`/`NEXT_PUBLIC_BACKEND_URL` are derived from the mode (https://domain vs http://localhost:port + LAN IP). |
| 6 | **Social platform credentials are NOT in the compose/env template.** They are per-account integrations created in the Postiz UI after first login (LinkedIn, X, dev.to, Reddit…). The script prints a post-install checklist instead. Rationale: UI-owned OAuth connections are the supported Postiz flow and keep the template platform-agnostic. |
| 7 | **Hard startup gate:** wait for `postiz` healthcheck *and* `GET /api/health`-equivalent to return <500 (healthcheck from the official compose) within `WAIT_TIMEOUT` (default **300 s** — ES+Temporal need longer than the 180 s house default). Non-zero exit + actionable hint on failure. |
| 8 | **Registration stays open by default** (`DISABLE_REGISTRATION=false`); the printed checklist tells the user to set `POSTIZ_DISABLE_REGISTRATION=true` in `.env` + `docker compose up -d postiz` after creating the admin org. |
| 9 | **Backups:** out of scope for v1, but volumes are named (`postiz_*`) and the plan links the existing `lib/docker-backup.sh` pattern as the follow-up to add (postgres volume dump) once the stack is trusted. |
| 10 | **VM test suite:** add `setup-postiz` to `tests/machine-config.test.yml` (like `setup-agent-sandbox`). |

## Design

### File layout

```
templates/postiz/
  docker-compose.yml            # rendered values via ${VAR} placeholders, no secrets
  dynamicconfig/
    development-sql.yaml        # Temporal dynamic config (verbatim from official repo)
tasks/setup-postiz.sh           # env-var driven, idempotent
```

### Task script structure

```
step "Setting up Postiz"
  1. preflight                    docker + compose present (helpers), port/domain mode resolution
  2. create POSTIZ_HOME           default /srv/postiz
  3. write .env (mode 600)        JWT_SECRET / POSTGRES_PASSWORD / TEMPORAL_POSTGRES_PASSWORD
                                  — generate once, reuse on re-runs, allow explicit overrides
  4. render docker-compose.yml    from template (envsubst-style substitution of derived values:
                                  MAIN_URL, FRONTEND_URL, NEXT_PUBLIC_BACKEND_URL, BACKEND_INTERNAL_URL,
                                  TEMPORAL_ADDRESS, image pins, traefik labels block, HTTP_PORT)
  5. copy dynamicconfig/          into POSTIZ_HOME (required by the ./dynamicconfig volume mount)
  6. docker compose up -d         --env-file POSTIZ_HOME/.env
  7. wait for healthy             WAIT_TIMEOUT (default 300 s), then app-level HTTP check
  8. print post-install checklist (below)
```

### Environment variables (all optional, defaults in `--help`)

| Var | Default | Notes |
|---|---|---|
| `POSTIZ_HOME` | `/srv/postiz` | data + compose + .env |
| `HTTP_PORT` | `4007` | ignored when `POSTIZ_TRAEFIK=true` |
| `POSTIZ_TRAEFIK` | `false` | opt-in Traefik routing |
| `POSTIZ_DOMAIN` | — | required with `POSTIZ_TRAEFIK=true` |
| `PROXY_NETWORK` | `proxy` | Traefik's external network |
| `POSTIZ_IMAGE` | `ghcr.io/gitroomhq/postiz-app:v2.24.0` | pinned at implementation (2026-10-01) |
| `POSTGRES_IMAGE` | `postgres:17-alpine` | Postiz DB |
| `TEMPORAL_POSTGRES_IMAGE` | `postgres:16` | Temporal DB |
| `REDIS_IMAGE` | `redis:7.2` | |
| `ES_IMAGE` | `elasticsearch:7.17.27` | Temporal visibility |
| `TEMPORAL_IMAGE` | `temporalio/auto-setup:1.28.1` | |
| `TEMPORAL_UI_IMAGE` | `temporalio/ui:2.34.0` | |
| `TEMPORAL_UI_PORT` | `18080` | loopback-only |
| `WAIT_TIMEOUT` | `300` | |
| `OPENAI_API_KEY` | — | optional, Postiz AI features (forwarded as `${OPENAI_API_KEY:-}`) |

### Compose service set (final)

| Service | Image | Exposed | Volumes |
|---|---|---|---|
| `postiz` | postiz-app | `HTTP_PORT:5000` (or traefik labels on 5000) | `postiz-config:/config`, `postiz-uploads:/uploads` |
| `postiz-postgres` | postgres:17-alpine | internal | `postiz_pgdata` |
| `postiz-redis` | redis:7.2 | internal | `postiz-redis-data` |
| `temporal-elasticsearch` | elasticsearch:7.17.27 | internal (9200) | `temporal-elasticsearch-data` |
| `temporal-postgresql` | postgres:16 | internal (5432) | `temporal-postgres-data` |
| `temporal` | temporalio/auto-setup:1.28.1 | `127.0.0.1:7233` (official parity) | `./dynamicconfig` mount |
| `temporal-ui` | temporalio/ui:2.34.0 | `127.0.0.1:18080` | — |

- Networks: `postiz-network` (app+db+redis) and `temporal-network` (temporal set); `postiz`
  joins both (official layout). Traefik mode additionally joins `PROXY_NETWORK`.
- `restart: always` everywhere, healthchecks verbatim from the official compose;
  `depends_on` with `condition: service_healthy` chain (postgres→redis→temporal→postiz).
- ES resources capped as official (`ES_JAVA_OPTS=-Xms256m -Xmx256m`, disk watermarks) —
  relevant on the Spark/Strix-Halo class of machines.
- Everything `container_name:`-prefixed `postiz-*` / `temporal-*` to avoid collisions with
  other kwisatz stacks on the same host.

### Fixed Postiz env (in compose, not secrets)

`MAIN_URL`, `FRONTEND_URL`, `NEXT_PUBLIC_BACKEND_URL` (derived, §Decisions 5),
`BACKEND_INTERNAL_URL=http://localhost:3000`, `TEMPORAL_ADDRESS=temporal:7233`,
`IS_GENERAL=true`, `DISABLE_REGISTRATION=false` (overridable via
`POSTIZ_DISABLE_REGISTRATION`), `RUN_CRON=true`, `STORAGE_PROVIDER=local`,
`UPLOAD_DIRECTORY=/uploads`, `NEXT_PUBLIC_UPLOAD_DIRECTORY=/uploads`, `API_LIMIT=30`.

### Post-install checklist printed by the script

1. Open the UI (`https://<domain>` or `http://<host>:4007`), create organization + admin user.
2. Set `POSTIZ_DISABLE_REGISTRATION=true` in `POSTIZ_HOME/.env`, `docker compose up -d postiz`.
3. Create **Integrations** in the UI: LinkedIn (Share-on-LinkedIn app, `w_member_social`),
   X (API key, pay-per-use), dev.to (API token — or keep dev.to on the GitHub-Action
   syndication path if preferred), Reddit (OAuth app; **new tokens need Reddit approval** —
   see research doc §2; until approved, Reddit stays manual).
4. **Create a Postiz API key** (Account settings) → configure the **Postiz MCP server** in
   pi (`docs.postiz.com/mcp`) so the agent can queue posts:
   `POSTIZ_API_URL=http(s)://<host>:4007/api` + key. This is the automation hook the
   campaign pipeline uses — tracked as a follow-up task, not part of this script.
5. (Follow-up) Add postgres volume to the backup rotation (`lib/docker-backup.sh` pattern).

### Registration touchpoints

- `machine-config.yml.example` — `setup-postiz:` block (alphabetical, after `setup-planka`):
  `enabled: false`, description, empty `env`/`args`.
- `AUTOMATIONS.md` — entry under the web-applications section (n8n/Planka neighbours) with
  the env var list summary.
- `README.md` — add Postiz to the "30+ services" bullet list.
- `tests/machine-config.test.yml` — `setup-postiz` case (default disabled; enabled-true run
  in the VM test).

## Verification (acceptance criteria)

1. `shellcheck tasks/setup-postiz.sh` clean; `bash -n` passes.
2. Fresh VM test (test suite): `setup-postiz` enabled → all 7 containers `healthy` within
   `WAIT_TIMEOUT`; `curl -fsS http://127.0.0.1:4007/` returns HTTP < 500;
   `docker compose -f /srv/postiz/docker-compose.yml ps` shows no restart loops.
3. Idempotency: re-run `setup-postiz.sh` → no secret regeneration, no data loss,
   `docker compose` converges (diff of rendered compose empty apart from nothing).
4. Traefik mode: `POSTIZ_TRAEFIK=true POSTIZ_DOMAIN=…` → no published app port,
   labels present, site reachable via domain, TLS via existing Let's Encrypt setup.
5. Teardown sanity: `docker compose down -v` on the test VM removes stack + volumes
   without touching other stacks' volumes (prefix check).
6. Smoke the product, not just the process: create a test post in the UI scheduled 5 min
   out to a dummy/empty integration → it appears in the calendar (proves Temporal +
   `RUN_CRON` actually work — this is the capability the whole install exists for).

## Out of scope / follow-ups

- Platform OAuth app creation (LinkedIn/X/Reddit/dev.to) — UI checklist, human steps
  (Reddit token approval has an unknown turnaround; do it early).
- pi ↔ Postiz MCP wiring (the actual posting automation) — separate task in the vault
  campaign, consumes the API key from checklist step 4.
- Postgres volume backup rotation (§Decision 9).
- R2/S3 storage instead of local uploads (only if uploads outgrow the disk).
- Postiz version upgrade procedure (document in AUTOMATIONS.md entry: bump pin,
  `docker compose pull && up -d`, migrations run on boot).

## Open questions (resolved at implementation, 2026-10-01)

1. **Postiz app image tag** — pinned to **`ghcr.io/gitroomhq/postiz-app:v2.24.0`**
   (newest GHCR release tag at implementation; `v2.24.0` multi-arch, matching GitHub
   release v2.24.0 published 2026-09-22; `-amd64`/`-arm64` arch tags also exist).
2. **`API_LIMIT`** — kept at **30** (req/h for the public API). Fine for our cadence
   (a few posts per month, agent-driven); no evidence self-hosted builds lift it
   automatically. Revisit only if the MCP-driven posting volume grows.
3. **`temporal` port 7233** — kept **loopback-only** (`127.0.0.1:7233`). A future
   multi-host agent setup would need it opened via ufw then.

## Addendum 2026-10-01 — admin bootstrap + HTTP cookie fix (post-implementation)

Driven by the first real deploy: the UI login returned 200 but the session was lost on
reload (auth cookie flagged `Secure` over plain HTTP). Research:
`docs/research/postiz-auto-config-2026-09-30.md` (all findings verified against the
v2.24.0 source).

1. **`NOT_SECURED: 'true'` in the direct (HTTP) template** — without it browsers refuse
   to store the auth cookie over http://, so every login silently bounces back to
   `/auth/login`. Traefik (HTTPS) mode keeps the Secure flag.
2. **The script bootstraps org + admin user via the API** (supersedes checklist step 1
   and Decision 8): Postiz has no env-var seed, init script, or CLI. `POST
   /api/auth/register` (`email`, `password`, `company`, `provider: LOCAL`) creates a NEW
   organization with a SUPERADMIN user and an auto-generated public API key; without an
   SMTP provider the user is auto-activated. The script: login-first →
   register-fallback (400 "Email already exists" / "Registration is disabled" = already
   exists), then reads the API key from `GET /api/user/self` into `POSTIZ_API_KEY` in
   the `.env` (the MCP-server hook). New env vars: `POSTIZ_ADMIN_EMAIL` (default: the
   machine user's email), `POSTIZ_ADMIN_ORG` (default: `my organization`),
   `POSTIZ_ADMIN_PASSWORD` (secret, auto-generated, `.env`).
   `POSTIZ_DISABLE_REGISTRATION` now defaults to `true`: Postiz's `canRegister()` still
   allows exactly the first registration while the org count is 0, so the bootstrap
   works and all later signups are locked out by the app itself.
