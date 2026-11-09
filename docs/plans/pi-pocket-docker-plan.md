# Plan: `tasks/setup-pi-pocket.sh` — Pi Pocket (pi-pocket) in Docker, optional Traefik route

Date: 2026-11-09 (plan only — nothing implemented)
Target repo for the service: <https://github.com/TannerMidd/pi-pocket>
Local facts read from the installed copy: `/home/verfeinerer/.nvm/versions/node/v24.7.0/lib/node_modules/pi-pocket/docs/docker.md`
(that install ships only `docs/`; `docker/Dockerfile` and `docker-compose.yml` exist only in the git repo).

## 1. Goal

One new task script, `tasks/setup-pi-pocket.sh`, that deploys **Pi Pocket** idempotently with
Docker Compose in the house style (`setup-planka.sh`, `setup-omnigent.sh`, `setup-postiz.sh`):

1. Source is cloned at a pinned tag into `${PI_POCKET_HOME}/src` and built into a local image
   (upstream publishes no container image — cf. `setup-nanobot.sh`, which builds locally).
2. All state lives in bind mounts under `/srv/pi-pocket`, so the image stays disposable.
3. The container runs as `1000:1000` with a writable `HOME`; Chromium runs with `--no-sandbox`.
4. Traefik routing is opt-in (`PI_POCKET_TRAEFIK=true` + `PI_POCKET_DOMAIN`), default mode
   publishes the port for LAN access.
5. Registration and docs follow the existing contract (`machine-config.yml.example`,
   `AUTOMATIONS.md`, `tests/machine-config.test.yml`, `versions.yml`).

## 2. Non-goals

- No published/upstream container image, no multi-arch build, no image registry push.
- No `tailscale` or `tailscale-serve` access mode: the image has no `tailscale` binary
  (`docs/docker.md` *Access and ports*). Host-side Tailscale/NetBird stays the way to reach it.
- No `cloudflare` tunnel configuration. `cloudflared` exists in the image, but the script does
  not drive it in v1; document it as a manual `.env` step (open question O-3).
- No backup integration (`lib/docker-backup.sh`) in v1 — `pocket.sqlite` is a single file in a
  bind mount; the follow-up is trivial and linked, not built here.
- No host-side (systemd) install; `setup-pi.sh` already installs the native `pi` CLI.
- No changes to Pi Pocket's source, and no version-management of `~/.pi/agent/models.json`.
- No UI/first-login automation: the owner sign-in link is credential material a human opens.

## 3. Facts that drive the design (from `docs/docker.md`)

| Fact | Consequence for the script |
|---|---|
| Image is built from the repo root; `docker/Dockerfile` + `docker-compose.yml` live in the git repo | the script clones the source and runs a local build |
| `PI_POCKET_PORT` (default `8787`) is the port on both sides; `PI_POCKET_BIND` is the host address the port is published on | one port knob, one bind knob |
| `PI_POCKET_ACCESS` default `lan`; `local` does not work behind a published port | script pins `lan`, rejects `local` |
| `PI_POCKET_DATA` (`/data`), `PI_POCKET_EXTENSIONS`, `PI_POCKET_THEMES` (under `/data`), `PI_POCKET_PI_DIR` (`/home/node/.pi`), `PI_POCKET_WORKSPACE` (`/workspace`) are bind mounts, nested on purpose | five host directories, created and owned by the script |
| The printed login link names the **container's own** `172.x` address | the script rewrites the host part before printing, and Traefik mode is what gives a stable, reachable URL |
| Compose defaults to root; `user: "1000:1000"` + writable `HOME=/home/node` is the documented non-root recipe; `no-new-privileges` + Chromium `--no-sandbox` are the real limits | `user:` line, `HOME`, `chown -R 1000:1000`, `security_opt` |
| Image contains `git`, `gh`, `ripgrep`, `fd`, `cloudflared`, Chromium | no extra host tools needed; provider keys go through env |
| Pi sign-ins live in `<pi-dir>/agent/auth.json`, not the database | sharing `~/.pi` is an explicit opt-in, not the default |
| Anyone who steers a session runs commands inside the container as its user | never publish on a public interface; default `0.0.0.0` is LAN-only and says so |

## 4. New and changed files

New:
- `tasks/setup-pi-pocket.sh` — the task script.
- `templates/pi-pocket/docker-compose.direct.yml` — LAN mode (published port).
- `templates/pi-pocket/docker-compose.traefik.yml` — proxy network + labels, loopback publish.
- `templates/pi-pocket/README.md` — short note on what each variable means (optional, matches some template dirs).

Changed:
- `versions.yml` — one new `pi-pocket` entry (source ref pin, not an image tag).
- `machine-config.yml.example` — a `setup-pi-pocket` key, `enabled: false`, with the env keys documented.
- `tests/machine-config.test.yml` — same key; see step 8 for the build-cost decision.
- `AUTOMATIONS.md` — new `#### setup-pi-pocket.sh` entry under **AI & LLM Services**, next to `setup-pi.sh` (line ~380).
- `README.md` — one line in *Service Setup Scripts* naming the operator guide only if a guide is written; otherwise no change (the service list lives in `AUTOMATIONS.md`).
- `README_TRAEFIK.md` — the "Adding Applications to Traefik" section gains Pi Pocket as a WebSocket example (one paragraph, no new files).
- `docs/plans/pi-pocket-docker-plan.md` — this file.

Deliberately **not** touched: `lib/helpers.sh` (every needed helper already exists),
`tests/lint.sh` (no allowlist needed — see §7), `renovate.json` (no `# HELD` rule).

## 5. Configuration contract

Data root: `PI_POCKET_HOME` (default `/srv/pi-pocket`). Layout:

```
/srv/pi-pocket/
├── .env                       # mode 600, secrets + layout, written by the script
├── docker-compose.yml         # rendered from templates/pi-pocket/docker-compose.<mode>.yml
├── .built-ref                 # the git ref the current image was built from
├── src/                       # git checkout at the pinned tag (build context)
├── data/                      # -> /data
├── data/extensions/           # -> /data/extensions
├── data/themes/               # -> /data/themes
├── data/pi/                   # -> /home/node/.pi
└── workspace/                 # -> /workspace
```

Environment variables (all optional, `--help` documents all of them):

| Variable | Default | Notes |
|---|---|---|
| `PI_POCKET_HOME` | `/srv/pi-pocket` | house `*_HOME` convention |
| `PI_POCKET_IMAGE` | `pi-pocket:$(kw_version pi-pocket)` | built locally, never pulled |
| `PI_POCKET_PORT` | `8787` | host side and container side |
| `PI_POCKET_BIND` | `0.0.0.0` (direct) / forced `127.0.0.1` (Traefik) | `docs/docker.md` semantics |
| `PI_POCKET_ACCESS` | `lan` | `local` is rejected with an error |
| `PI_POCKET_TRAEFIK` | `false` | opt-in |
| `PI_POCKET_DOMAIN` | empty | required when `PI_POCKET_TRAEFIK=true` |
| `PROXY_NETWORK` | `proxy` | same default as every other script |
| `PI_POCKET_PI_DIR` | `${PI_POCKET_HOME}/data/pi` | set it to `$HOME/.pi` to share host sign-ins/skills (see §6) |
| `PI_POCKET_WORKSPACE` | `${PI_POCKET_HOME}/workspace` | projects Pi edits |
| `PI_POCKET_EXTRA_BINDS` | empty | `docker-compose` volume fragment, one per `--volume`; for extra project folders |
| `PI_POCKET_BROWSER_ARGS` | `--no-sandbox` | required for uid 1000 without user-ns setup |
| `WAIT_TIMEOUT` | `240` | stack bring-up (`wait_for_healthy`) |
| `FORCE` | `false` | rebuild the image even when the ref marker matches |

Provider keys (for example `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) are **not** script variables:
they are plain `.env` keys the operator adds by hand. The compose file carries them only as
`${ANTHROPIC_API_KEY:-}` placeholders.

## 6. Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Build the image from a pinned git checkout (`${PI_POCKET_HOME}/src`), tag it `pi-pocket:<tag>`, record the ref in `.built-ref`, and rebuild only on a change or `FORCE=true`. | No upstream image. `docker compose up --build` on every run would rebuild every re-run; a marker makes re-runs converge in seconds. |
| 2 | `user: "1000:1000"`, `HOME=/home/node`, `security_opt: no-new-privileges:true`, `PI_POCKET_BROWSER_ARGS=--no-sandbox`. | The documented non-root recipe; `no-new-privileges` + `--no-sandbox` are the actual limit on a browser breakout, not the uid. |
| 3 | Five separate bind mounts, nested under `${PI_POCKET_HOME}/data`, created by the script and `chown -R 1000:1000`-ed. | Matches the upstream layout (mounts are nested on purpose) and keeps the host `~/.pi` out of the picture unless asked for. |
| 4 | Default `PI_POCKET_PI_DIR` is **isolated** (`/srv/pi-pocket/data/pi`). Sharing the host's `$HOME/.pi` is an explicit opt-in. | Sharing gives the container the host's `auth.json`, skills and session history, and writes sessions there. A container that runs arbitrary commands must not inherit that silently. |
| 5 | Direct mode publishes `${PI_POCKET_BIND}:8787`; Traefik mode joins `PROXY_NETWORK` and publishes `127.0.0.1:${PI_POCKET_PORT}:8787`. | Loopback publish keeps the health poll and the login-link rewrite working, and keeps the port off the LAN where Traefik already answers. |
| 6 | Login-link handling: after a successful start, grep the logs for `/login?token=`, replace the address part with the resolved public URL, print it once with a warning. | The raw link names the container IP (`172.x`), which nothing off-host can open. This is the only user-facing fix for it that needs no upstream change. |
| 7 | Re-runs converge: reuse `.env`, re-render the compose file, `docker compose up -d`, never tear down; `--interactive` may ask. | *Re-run policy* in `specification/project/conventions.md`. |
| 8 | Secrets stay out of the rendered file: `.env` (mode 600) via `--env-file`, `${VAR}` literal in templates. Provider keys use `:-` defaults so compose does not warn when absent. | *Secrets and templating* in `specification/project/conventions.md`. |
| 9 | Router/service name is `pipocket`, no dots and no hyphen. | Traefik splits label keys on `.`, and house examples use plain names (`planka`, `omnigent`). |
| 10 | Two compose templates (`direct`, `traefik`), selected by mode, rendered with `envsubst` on an explicit variable list, written as the invoking user, installed with `sudo install -m 644`. | House convention (planka/openwebui/postiz); no inline templates in the script. |
| 11 | Nothing local to this host goes into committed files. Local paths (a vault, a project folder) reach the container only through `PI_POCKET_EXTRA_BINDS` or the operator's own `machine-config.yml`. | Public repository rule in `AGENTS.md`. |
| 12 | v1 ships `lan` and Traefik modes only. `cloudflare` is a documented manual `.env` path, and the script errors if `cloudflare` is requested together with Traefik. | Two tunnel paths for one service invites a broken setup. |

## 7. Files, in detail

### 7.1 `versions.yml`

```yaml
pi-pocket:
  # no published container image: the script clones this tag and builds it
  # (cf. setup-nanobot.sh). The digest is the commit the tag points at.
  datasource: github-tags
  package: TannerMidd/pi-pocket
  version: "v0.28.0"
  digest: "<commit-sha-of-the-tag>"
```

`tests/unit/test_versions.py` is what makes this shape mandatory: every `kw_* <key>` must name
an entry (and every entry must be used), fields must be quoted strings, and a bare 40-character
SHA anywhere in `tasks/*.sh` is a finding. So the script reads both values from `versions.yml`:

```bash
PI_POCKET_SRC_REF="${PI_POCKET_SRC_REF:-$(kw_version pi-pocket)}"   # tag, overridable
PI_POCKET_SRC_SHA="$(kw_pin pi-pocket digest)"                      # for the dirty-check hint
PI_POCKET_IMAGE="${PI_POCKET_IMAGE:-pi-pocket:${PI_POCKET_SRC_REF#v}}"
```

Step 1 below confirms the tag and the commit SHA against the real repo before this file is
committed — the placeholder values here must not survive.

**Template lint:** `tests/lint.sh` guards 1–3 check `templates/` for `privileged:` and for
floating/untagged images. `image: ${PI_POCKET_IMAGE}` satisfies guards 2 and 3 (the value begins
with `$`), and there is no privileged container, so **no lint allowlist change is needed**. Do
not write `build:` with an inline path that carries a literal tag either.

### 7.2 `templates/pi-pocket/docker-compose.direct.yml`

```yaml
# Generated by setup-pi-pocket.sh on ${GENERATED_DATE}.
# Secrets are resolved at runtime from ${PI_POCKET_HOME}/.env (--env-file):
# every ${VAR} here is a literal token, never a substituted value.
---
name: pi-pocket

services:
  pi-pocket:
    image: ${PI_POCKET_IMAGE}
    build:
      context: ${PI_POCKET_SRC}
      dockerfile: docker/Dockerfile
    container_name: pi-pocket
    restart: unless-stopped
    user: "1000:1000"
    environment:
      HOME: /home/node
      PI_POCKET_DATA: /data
      PI_POCKET_EXTENSIONS: /data/extensions
      PI_POCKET_THEMES: /data/themes
      PI_POCKET_PI_DIR: /home/node/.pi
      PI_POCKET_WORKSPACE: /workspace
      PI_POCKET_PORT: 8787
      PI_POCKET_ACCESS: ${PI_POCKET_ACCESS:-lan}
      PI_POCKET_BROWSER_ARGS: ${PI_POCKET_BROWSER_ARGS:---no-sandbox}
      # Optional provider keys, resolved from .env at runtime; empty when unset.
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
    ports:
      - "${PI_POCKET_BIND}:${PI_POCKET_PORT}:8787"
    volumes:
      - ${PI_POCKET_DATA_DIR}:/data
      - ${PI_POCKET_EXTENSIONS_DIR}:/data/extensions
      - ${PI_POCKET_THEMES_DIR}:/data/themes
      - ${PI_POCKET_PI_DIR}:/home/node/.pi
      - ${PI_POCKET_WORKSPACE_DIR}:/workspace
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:8787/').then(r=>process.exit(r.ok||r.status===302?0:1)).catch(()=>process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s
    networks:
      - pi-pocket

networks:
  pi-pocket:
    external: false
```

`templates/pi-pocket/docker-compose.traefik.yml` is the same service plus:

```yaml
    labels:
      - 'traefik.enable=true'
      - 'traefik.docker.network=${PROXY_NETWORK}'
      - 'traefik.http.routers.pipocket.rule=Host(`${PI_POCKET_DOMAIN}`)'
      - 'traefik.http.routers.pipocket.entrypoints=websecure'
      - 'traefik.http.routers.pipocket.tls.certresolver=letsencrypt'
      - 'traefik.http.services.pipocket.loadbalancer.server.port=8787'
    ports:
      - "127.0.0.1:${PI_POCKET_PORT}:8787"
    networks:
      - pi-pocket
      - ${PROXY_NETWORK}

networks:
  pi-pocket:
    external: false
  ${PROXY_NETWORK}:
    external: true
```

Pi Pocket speaks WebSockets on the same port; Traefik proxies upgrade requests without extra
labels, and the app needs no `X-Forwarded` knob that is not already handled. If a later test
shows a `426`/`502` on the socket, the fix is a router `transportName`, not a new label set —
record what you found in this plan and in the script's comments.

### 7.3 `tasks/setup-pi-pocket.sh` — skeleton

Follow the `setup-planka.sh` layout exactly: header comment, `usage()`, `set -euo pipefail`,
`source "${LIB_PATH}"`, argument parse (`--interactive`, `-h`), config block, pre-flight,
secrets, existing-stack check, directories, render, build, start, health gate, summary.

```bash
# ── CONFIGURATION
PI_POCKET_HOME="${PI_POCKET_HOME:-/srv/pi-pocket}"
PI_POCKET_SRC="${PI_POCKET_SRC:-${PI_POCKET_HOME}/src}"
PI_POCKET_SRC_REF="${PI_POCKET_SRC_REF:-$(kw_version pi-pocket)}"
PI_POCKET_IMAGE="${PI_POCKET_IMAGE:-pi-pocket:${PI_POCKET_SRC_REF#v}}"
PI_POCKET_PORT="${PI_POCKET_PORT:-8787}"
PI_POCKET_BIND="${PI_POCKET_BIND:-0.0.0.0}"
PI_POCKET_ACCESS="${PI_POCKET_ACCESS:-lan}"
PI_POCKET_TRAEFIK="${PI_POCKET_TRAEFIK:-false}"
PI_POCKET_DOMAIN="${PI_POCKET_DOMAIN:-}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
PI_POCKET_PI_DIR="${PI_POCKET_PI_DIR:-${PI_POCKET_HOME}/data/pi}"
PI_POCKET_WORKSPACE_DIR="${PI_POCKET_WORKSPACE_DIR:-${PI_POCKET_HOME}/workspace}"

ENV_FILE="${PI_POCKET_HOME}/.env"
COMPOSE_FILE="${PI_POCKET_HOME}/docker-compose.yml"
BUILT_REF_FILE="${PI_POCKET_HOME}/.built-ref"

# ── PRE-FLIGHT
command -v docker >/dev/null || error "Docker is not installed — run setup-docker.sh first."
docker info >/dev/null 2>&1 || error "Docker daemon is not running."
command -v git >/dev/null    || error "git is not installed — run setup-basics.sh first."
command -v envsubst >/dev/null || error "envsubst is not installed — apt-get install gettext-base."
case "$PI_POCKET_ACCESS" in
  lan)     ;;
  local)   error "PI_POCKET_ACCESS=local cannot work with a published port — use lan." ;;
  *)       error "Unsupported PI_POCKET_ACCESS '${PI_POCKET_ACCESS}' (v1 supports lan)." ;;
esac
if [[ "$PI_POCKET_TRAEFIK" == "true" ]]; then
  ensure_proxy_network || error "Traefik proxy network '${PROXY_NETWORK}' not found."
  [[ -n "$PI_POCKET_DOMAIN" ]] || error "PI_POCKET_DOMAIN must be set when PI_POCKET_TRAEFIK=true."
  ensure_traefik_running   # house helper; exits 1 when the traefik container is not running
  PI_POCKET_BIND="127.0.0.1"
  PUBLIC_URL="https://${PI_POCKET_DOMAIN}"
else
  PUBLIC_URL="http://$(detect_lan_ip || echo localhost):${PI_POCKET_PORT}"
fi
ss -lnt | awk '{print $4}' | grep -qE "[:.]${PI_POCKET_PORT}\$" \
  && warn "Port ${PI_POCKET_PORT} already has a listener — check for another service."
```

`detect_lan_ip` is the local helper already used by `setup-planka.sh` — copy it, do not add it
to `lib/helpers.sh` for one user.

Source checkout and image build:

```bash
step "Preparing the source checkout at ${PI_POCKET_SRC_REF}"
if [[ -d "${PI_POCKET_SRC}/.git" ]]; then
  if [[ -n "$(git -C "$PI_POCKET_SRC" status --porcelain)" ]]; then
    error "${PI_POCKET_SRC} has uncommitted changes. Commit or remove them, then re-run."
  fi
  git -C "$PI_POCKET_SRC" fetch --tags --quiet origin || error "git fetch failed"
else
  sudo mkdir -p "$PI_POCKET_SRC" && sudo chown "$(id -u):$(id -g)" "$PI_POCKET_SRC"
  git clone --quiet https://github.com/TannerMidd/pi-pocket "$PI_POCKET_SRC"
fi
git -C "$PI_POCKET_SRC" checkout --quiet --detach "$PI_POCKET_SRC_REF" \
  || error "cannot check out ${PI_POCKET_SRC_REF} (network, or the tag was removed)"
# Refusing a mismatch against versions.yml's digest is a warning, never a failure:
# the digest is a hint that the tag was moved under us.
[[ "$(git -C "$PI_POCKET_SRC" rev-parse HEAD)" == "$(kw_pin pi-pocket digest)" ]] \
  || warn "${PI_POCKET_SRC_REF} is not the commit pinned in versions.yml — verify deliberately."

step "Building the image (only when the ref changed)"
if [[ "$FORCE" == "true" ]] || [[ ! -f "$BUILT_REF_FILE" ]] \
   || ! docker image inspect "$PI_POCKET_IMAGE" >/dev/null 2>&1 \
   || [[ "$(cat "$BUILT_REF_FILE")" != "$PI_POCKET_SRC_REF" ]]; then
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" build  # or: docker build -t ...
  printf '%s\n' "$PI_POCKET_SRC_REF" > "$BUILT_REF_FILE"
else
  info "Image ${PI_POCKET_IMAGE} is current for ${PI_POCKET_SRC_REF}; skipping the build (FORCE=true to rebuild)."
fi
```

Directories, secrets, render, start, health gate:

```bash
step "Creating host directories under ${PI_POCKET_HOME}"
sudo mkdir -p "${PI_POCKET_HOME}/data/extensions" "${PI_POCKET_HOME}/data/themes" \
              "${PI_POCKET_HOME}/data/pi" "${PI_POCKET_HOME}/workspace"
sudo chown -R 1000:1000 "$PI_POCKET_HOME" || warn "could not chown ${PI_POCKET_HOME}"
# Never wipe an existing data/pi: refuse to overwrite a non-empty dir with a new mount target.

# The .env holds this script's layout keys plus anything the operator added by hand
# (provider keys). Reuse what is there, never rotate it. env_file_get reads one key,
# env_file_write installs a whole file with mode 600 from stdin.
if [[ -f "$ENV_FILE" ]]; then
  info "Found ${ENV_FILE} — reusing its values."
  PI_POCKET_ACCESS="${PI_POCKET_ACCESS:-$(env_file_get "$ENV_FILE" PI_POCKET_ACCESS)}"
  PI_POCKET_BROWSER_ARGS="${PI_POCKET_BROWSER_ARGS:-$(env_file_get "$ENV_FILE" PI_POCKET_BROWSER_ARGS)}"
  _keep="$(grep -vE '^(PI_POCKET_ACCESS|PI_POCKET_BROWSER_ARGS)=' "$ENV_FILE")"   # operator lines
fi
cat <<EOF | env_file_write "$ENV_FILE"
PI_POCKET_ACCESS=${PI_POCKET_ACCESS}
PI_POCKET_BROWSER_ARGS=${PI_POCKET_BROWSER_ARGS}
${_keep:-}
# Add provider keys here by hand, for example: ANTHROPIC_API_KEY=sk-…
EOF

# Render with an explicit variable list — layout only, no secrets.
TEMPLATE_FILE="templates/pi-pocket/docker-compose.${_mode}.yml"
export PI_POCKET_IMAGE PI_POCKET_SRC PI_POCKET_PORT PI_POCKET_BIND PROXY_NETWORK \
       PI_POCKET_DOMAIN PI_POCKET_DATA_DIR PI_POCKET_EXTENSIONS_DIR PI_POCKET_THEMES_DIR \
       PI_POCKET_PI_DIR PI_POCKET_WORKSPACE_DIR GENERATED_DATE
envsubst '<the same list>' < "$TEMPLATE_FILE" > "$_tmp"
sudo install -m 644 -o "$(id -u)" -g "$(id -g)" "$_tmp" "$COMPOSE_FILE"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d
mapfile -t _ids < <(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps -q)
wait_for_healthy "${WAIT_TIMEOUT:-240}" "${_ids[@]}" \
  || error "Pi Pocket stack did not come up"

# HTTP readiness, then the login-link rewrite (decision 6).
link="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs --no-log-prefix 2>/dev/null \
        | grep -m1 '/login?token=' || true)"
```

The readiness poll loops on `curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PI_POCKET_PORT}"`
until `200|302`, bounded by a fixed `MAX_WAIT`, the same shape as `setup-openwebui.sh`.

The link rewrite (keep it readable and comment it as *a cosmetic fix for a container-internal address*):

```bash
if [[ -n "$link" ]]; then
  path="${link#*://}"; path="/${path#*/}"          # drop scheme + any host, keep /login?token=...
  success "Owner sign-in link (one use per browser, treat it as a password):"
  echo "    ${PUBLIC_URL}${path}"
  warn "The raw log line names the container's own address; ${PUBLIC_URL} is where it is reachable."
fi
```

The summary block prints: mode, `PUBLIC_URL`, `https://<domain>` in Traefik mode, the five
mount paths, `$ENV_FILE`, `$COMPOSE_FILE`, and the useful commands (`up -d`, `down`, `logs -f`,
`exec -it pi-pocket bash`). It also prints the two warnings this service earns: state and
provider keys live in the bind mounts, and anyone who steers a session runs commands as uid 1000.

`--help` must list every variable above plus `--interactive`, `FORCE`, `WAIT_TIMEOUT`
(*Help / Usage parameter* in `AGENTS.md`).

### 7.4 `machine-config.yml.example` / `tests/machine-config.test.yml`

Same key in both (`tests/lint.sh` guard 5 requires every example key to name a real script):

```yaml
  setup-pi-pocket:
    enabled: false
    description: Install Pi Pocket (pi-pocket) in Docker, built from the pinned tag
    env:
      PI_POCKET_PORT: "8787"
      # PI_POCKET_TRAEFIK: "true"
      # PI_POCKET_DOMAIN: "pi.example.com"
      # PI_POCKET_PI_DIR: /srv/pi-pocket/data/pi   # set to $HOME/.pi to share host sign-ins
    args: []
```

`machine-config.yml` (the tracked local file) may carry a matching disabled block; keep any
host-specific paths out of it.

## 8. Implementation steps

1. **Verify the pin.** Run
   `git ls-remote --tags https://github.com/TannerMidd/pi-pocket` and
   `git ls-remote https://github.com/TannerMidd/pi-pocket refs/tags/<tag>` to get the tag list and
   the commit that the chosen tag points at. Read `docs/docker.md`, `docker/Dockerfile` and `docker-compose.yml`
   in the checked-out source: confirm the mount variables, the internal port, the entrypoint's
   Chromium lock cleanup, and that no public-URL variable exists (O-1).
2. Add the `pi-pocket` entry to `versions.yml`; run `uv run pytest tests/unit/test_versions.py`
   and `utilities/check-versions.sh`.
3. Write `templates/pi-pocket/docker-compose.direct.yml` and `...traefik.yml`; run
   `yamllint templates/pi-pocket/*.yml` and `tests/lint.sh` (expect no new allowlist entries).
4. Write `tasks/setup-pi-pocket.sh` from the `setup-planka.sh` skeleton; `shellcheck` it; run
   `./tasks/setup-pi-pocket.sh --help` and read the whole output.
5. Register: `machine-config.yml.example`, `tests/machine-config.test.yml`, `AUTOMATIONS.md`
   entry under **AI & LLM Services** (near `setup-pi.sh`, and cross-link the two — the container
   and the native `pi` CLI read the same `agent/` folder only if the operator points
   `PI_POCKET_PI_DIR` at it).
6. Manual smoke test on this machine:
   `PI_POCKET_HOME=/tmp/pi-pocket-test ./tasks/setup-pi-pocket.sh` (isolated root, nothing
   under `/srv`), then the same command again to prove convergence, then `down -v`-free cleanup
   (`down`, remove the temp root). Do not test in the real `/srv/pi-pocket` on the first pass.
7. Traefik smoke test on a host where `setup-traefik.sh` ran:
   `PI_POCKET_TRAEFIK=true PI_POCKET_DOMAIN=<test-domain> ./tasks/setup-pi-pocket.sh`, then
   `curl -sI "https://<test-domain>/login?token=…"` for 200/302 and a WebSocket connect.
8. VM suite: add the key to `tests/machine-config.test.yml`. Because the image build downloads
   Node, Chromium and the npm dependencies, the first run is long; keep the entry `enabled: false`
   with the ad-hoc command in the surrounding comment block, the way `setup-hermes` and
   `setup-matrix` are handled:
   `tests/run-vm-tests.sh --scripts setup-docker,setup-traefik,setup-pi-pocket`.
   Run that once before merge (twice, to prove idempotency) and note the wall-clock in the PR.
9. Docs: the `README_TRAEFIK.md` WebSocket note, and the `AUTOMATIONS.md` paragraph. Update
   `docs/releases/` only at release time, not here.
10. Final gate, in order: `shellcheck tasks/setup-pi-pocket.sh` · `yamllint templates/pi-pocket` ·
    `tests/lint.sh` · `uv run pytest` · the VM run of step 8.

## 9. Data, user and mount decisions for this host

- Host: an Ubuntu server with rootful Docker Engine (`setup-docker.sh`), user uid 1000. So
  `user: "1000:1000"` + `chown -R 1000:1000 /srv/pi-pocket` is the correct recipe; nothing in
  the container writes as root.
- `HOME=/home/node` inside the container is writable because the image's `node` user is uid 1000.
- SELinux is not in play on this host; if a future host is, the plan is to add `:Z` to the bind
  mounts rather than to disable enforcement. Note it as a follow-up only.
- Do **not** default `PI_POCKET_PI_DIR` to `$HOME/.pi`: this host's `~/.pi/agent` holds real
  provider sign-ins, skills, and the session history that `agentsview` indexes. Sharing is a
  per-operator decision, documented and opt-in.
- `PI_POCKET_EXTRA_BINDS` is how you hand the container one project folder (read-write) without
  widening the whole workspace. Never put a path that belongs to this host in a template or an
  example config.

## 10. Acceptance criteria

1. `./tasks/setup-pi-pocket.sh --help` lists every supported variable and runs with no side effects.
2. First run creates `/srv/pi-pocket` with the five directories, a 600 `.env`, and a rendered
   `docker-compose.yml` that contains **no** secret values and no `:latest` image.
3. After the run: `docker ps` shows `pi-pocket` healthy; `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8787`
   returns `200` or `302`; the script printed exactly one rewritten sign-in link with the host's
   address, never the `172.x` address.
4. Re-running the script changes nothing: no rebuild (marker hit), no data loss, same `.env`
   secrets, stack ends healthy, exit code 0.
5. `PI_POCKET_TRAEFIK=true PI_POCKET_DOMAIN=<domain>` gives a working `https://<domain>` with a
   valid certificate, the port is not published on the LAN, and a WebSocket session survives a
   Traefik reload.
6. `shellcheck`, `yamllint`, `tests/lint.sh`, `uv run pytest`, and the VM run of step 8 pass;
   `git status` shows only the files in §4.
7. Two people can share a session (the documented Pi Pocket feature) through the service without
   the script getting in the way: a second invite link opened from a phone reaches the same URL.

## 11. Tests to add or change

- `tests/machine-config.test.yml`: the disabled `setup-pi-pocket` key (step 8).
- No new unit test is required; `test_versions.py` already covers the pin, `tests/lint.sh`
  already covers the templates. A unit test is worth adding only if the login-link rewrite needs
  a fixture.
- Manual, on this host: `tests/README.md` VM path for `setup-docker,setup-traefik,setup-pi-pocket`,
  plus the two-run idempotency check.

## 12. Risks

| Risk | Mitigation |
|---|---|
| The image build makes the VM test much slower (Node + Chromium download) and can blow the 15–30 min suite budget | marker-gated rebuild; the test entry stays disabled with the ad-hoc command documented; measure before merge |
| Upstream has no container image, so we own the build forever, including its Chromium/npm layers | pin the tag in `versions.yml`; Renovate opens the bump PR; the script rebuilds only on a ref change |
| The login link cannot be rewritten reliably if upstream changes the log line, and there is no public-URL variable | keep the rewrite pattern-matched and non-fatal; print the raw line as a fallback. Track O-1 upstream |
| Running arbitrary commands as uid 1000 is the real threat model: a stolen session is code execution on the host's files | never publish publicly, `no-new-privileges`, `--no-sandbox` documented, provider keys live in `.env` (600) not in the image, and `AGENTS.md`-style "public project" hygiene in the printed warning |
| Sharing `$HOME/.pi` writes container sessions into the host's session store and mixes two Pi installs | opt-in, printed warning, and the default stays isolated |
| Docker rootless (not the case here, but possible on a future host) changes every `chown` assumption | detect with `docker info`; warn that rootless needs the host folder pre-owned |
| A moved upstream tag makes the image disagree with `versions.yml` | warn with the two SHAs side by side; never auto-`FORCE` |
| Port 8787 is a common choice | `ss` pre-flight warning; `PI_POCKET_PORT` moves both sides |
| WebSocket failure behind Traefik (TLS termination, idle timeout) | test it in step 7; record the fix here rather than inventing labels |

## 13. Open questions

- **O-1** — Does pi-pocket have (or will it accept) a public-origin variable so invite links and
  login links are correct without rewriting? If yes, decision 6 becomes one `environment:` line.
- **O-2** — Is an upstream container image planned? If yes, switch `datasource` to `docker`, drop
  the clone/build, and keep the mounts as they are.
- **O-3** — Should `cloudflare` mode be a third template in v2 (`PI_POCKET_ACCESS=cloudflare`,
  no published port)? It duplicates Traefik as a way in; decide by operator demand.
- **O-4** — Which folder should be the workspace default on this host: the neutral
  `/srv/pi-pocket/workspace`, or a shared tree that several agents already work in? The second
  is what makes the service useful here, but it must come from the operator's own config, not
  from this repo.
- **O-5** — Should `gh` inside the container mount a host `~/.config/gh` for authenticated `gh`
  runs? Not in v1; note it when someone asks for repos from the container.
- **O-6** — Is `docs/plans` the right home for the follow-up that adds `lib/docker-backup.sh`
  support (`pocket.sqlite` + `data/pi`)?
