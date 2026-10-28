# Plan: Move the opencode automation to OpenCode 2.x

Date: 2026-10-28 · Status: **implemented** (see §9 for the verification log) · Affects: `tasks/setup-opencode.sh`, `templates/opencode-server/*`, `sync_models/agents/opencode.py`, `machine-config.yml`, `AUTOMATIONS.md`

## 1. What changed in OpenCode 2 (evidence)

| Fact | Evidence | Source |
|---|---|---|
| V2 is published under the npm package **`@opencode/cli`** (latest `2.2.0`). The old `opencode-ai` package tops out at **1.19.5** — it never ships 2.x | `npm view @opencode/cli dist-tags` → `latest: 2.2.0`; `npm view opencode-ai dist-tags` → `1.19.5`; no 2.x in `opencode-ai` versions | opencode.ai/v2/docs + npm registry |
| Install methods V2: `curl -fsSL https://opencode.ai/v2/install \| bash`, `brew install anomalyco/tap/opencode-v2`, `npm i -g @opencode/cli`, standalone tarballs `https://opencode.ai/update/api/latest/cli/opencode/opencode-linux-x64.tar.gz` | docs install tabs | opencode.ai/v2/docs |
| The npm package's **postinstall script picks the native binary**. It fails where lifecycle scripts are disabled (npm ≥12 `allowScripts=false`, `--ignore-scripts`) | issue #48884 | github.com/anomalyco/opencode/issues/48884 |
| GHCR images: versioned tags `ghcr.io/anomalyco/opencode:2.2.0` exist. The **`latest` tag still points at the 1.x line (1.19.5)** | `docker buildx imagetools inspect ghcr.io/anomalyco/opencode:2.2.0` OK; package page shows `latest` = 1.19.5 | ghcr.io/anomalyco/opencode |
| **Server auth breaking change**: `OPENCODE_SERVER_USERNAME` is **not supported any more** — the username is always `opencode`. Password via `OPENCODE_PASSWORD` (`OPENCODE_SERVER_PASSWORD` still honoured) | migration guide, "Server authentication" | opencode.ai/v2/docs/migrate-v1 |
| `opencode serve --hostname --port` still works (flags unchanged, plus `--cors`). Entrypoint of the image is `opencode` | `docker run … 2.2.0 serve --help` | verified locally |
| Readiness/identity endpoint is **`GET /api/info`** (Basic auth). Legacy `/global/health` still answers, but is not the documented contract | live test: `/api/info` → 200 `{"version":"2.2.0",…}`, 401 without auth; `-u admin:…` → **401**, `-u opencode:…` → 200 | verified locally against the 2.2.0 image |
| V2 adds a **shared per-user background service** (`opencode service set/start/status`, `opencode pair`); default client port 49374, localhost-only. `serve` remains the supervisor/foreground path | docs "Intro / Web" | opencode.ai/v2/docs/cli/web |
| Config locations unchanged; **V1 config format keeps working** (normalized in memory, source file untouched). Native V2 shape is optional | "Use your existing configuration" | opencode.ai/v2/docs/migrate-v1 |
| V2 renames in native config: `provider`→`providers`, `npm`→`package` (`aisdk:` prefix), `options.baseURL`→`settings.baseURL`; model `id`→`modelID`, `tool_call`/`modalities`→`capabilities.{tools,input,output}`, `variants` object→array of `{id,settings}`; `limit` keeps `{context,output}` | migration guide + `/models` docs + `Config.ModelEncoded` schema | opencode.ai/v2/docs |
| V1 model-level **`reasoning: true` is "accepted but unsupported"** in V2 (ignored with a warning). V2 expresses reasoning in `capabilities.reasoning` | "Accepted but unsupported fields"; `/models` `capabilities.reasoning` | opencode.ai/v2/docs |
| `tui.json(c)` (layered) → single global `~/.config/opencode/cli.json`, auto-migrated on first V2 TUI run | migration guide | opencode.ai/v2/docs/migrate-v1 |
| Session storage moved to **SQLite** `~/.local/share/opencode/opencode.db` (V1 used per-session files under `storage/`) | local box: `opencode.db` present, no `storage/`; agentsview records `file_path = ~/.local/share/opencode/opencode.db#ses_…` | local inspection |
| Three *intentional* breaking changes only: plugin API, server API/clients, terminal client config. Everything else is "compat bug if it breaks" | migration guide intro | opencode.ai/v2/docs/migrate-v1 |

State today (verified on this machine): CLI `opencode` = **v2.1.1** via `@opencode/cli`; our config `~/.config/opencode/opencode.json` is still **V1-shaped** (`provider` + `npm` + `options.baseURL` + `modalities`/`tool_call`/`reasoning` + `variants` object) and loads fine; `tui.json` present next to the auto-migrated `cli.json`; `agentsview 0.46.1` already ingests the V2 SQLite store (415 indexed opencode sessions).

## 2. What is wrong in our automation today (not just "old")

1. **`tasks/setup-opencode.sh:267` installs V1.** `sudo npm install -g opencode-ai --force` can never reach 2.x. Every "fresh" box gets the V1 line while our docs talk about "latest".
2. **No V1→V2 cutover.** Both use the `opencode` command; the migration guide says to remove the package-managed V1 install first. Our script does `npm install -g` over an existing `opencode-ai`, leaving two providers of one binary and a PATH lottery (which `opencode` wins depends on npm prefix ordering).
3. **`templates/opencode-server/opencode.service:8-9`** sets `OPENCODE_SERVER_USERNAME` (ignored in V2) — plus the unit's own health test (`setup-opencode.sh:483-484`) curls `--user ${OPENCODE_SERVER_USERNAME}:…`, i.e. `admin:…` → **guaranteed 401**. The service itself would still work; only our probe is wrong.
4. **The Docker volume is mounted in the wrong place.** Both templates mount `opencode_data:/data`, but the image stores everything under `/root/.local/{share,state,cache}/opencode` and `/root/.config/opencode` (verified: `docker run … debug paths`). Consequence: config + session DB live in the container's writable layer and are **lost on `down`/rebuild**. This is a pre-existing bug, and V2 makes it more visible (single SQLite DB).
5. **`_write_service_file` skips writing when the unit exists**, so a re-run never converges an already-installed unit. The V2 env change therefore does not reach an existing box by re-running `kwisatz apply` — against *Re-run policy: converge by default* in `specification/project/conventions.md`.
6. **Health contract**: we poll `/global/health`. It answers in V2 but is not the documented surface; `/api/info` is, and it is the only one that proves *which* server is up.
7. **`OPENCODE_IMAGE` default is pinned to `1.18.25`** and `warn_moving_image` correctly guards against drift — but nobody can bump the default without re-reading these notes.
8. **`sync_models/agents/opencode.py`** writes the V1 model shape. Loadable, so not a blocker, but two of its managed fields are dead weight in V2: `reasoning` (ignored with a warning) and `tool_call`/`modalities` (normalized into `capabilities`). Nothing writes `capabilities.reasoning`, so "this model can reason" is no longer expressed in V2 terms — only the `variants` with `reasoningEffort` survive, which is what actually matters.
9. `machine-config.yml:74-81` runs `setup-opencode` with `OPENCODE_SERVICE: true`, `OPENCODE_PORT: 8765` — i.e. the systemd path, the one with the 401 probe bug.

Unaffected / keep as-is: `setup-agent-docker-runner.sh`, `setup-agent-sandbox.sh` (they reference `~/.local/share/opencode` and `~/.config/opencode`, both still correct in V2); `agentsview` ingest (V2 store already understood); `lib/helpers.sh`.

## 3. Deliberately **not** doing this

- **No config-format rewrite.** V2 reads V1 config and conversion is optional and file-rewriting. `sync_models` must stay strictly additive; emitting native V2 means rewriting a file we do not own. Deferred to its own ticket.
- **No `opencode service set` / `opencode pair` in the systemd unit.** The background service is per-user and auto-starts; a server that a supervisor owns is `serve`. Keep `serve` under systemd.
- **No Docker web-UI pairing flow.** `opencode pair` writes pairing links, not what our Traefik mode needs. Keep Basic auth + reverse proxy.
- No new install modes beyond the two we already have (CLI, Docker) plus systemd. No brew/nix/pacman paths.

## 4. Decisions (resolved 2026-10-28)

1. **CLI install** — "cli install" chosen over the sha256-verified tarball. **Assuming the npm route (`npm i -g @opencode/cli@<pin>`); needs your confirmation**, because it inherits the postinstall-script failure mode (#48884) on npm ≥ 12 and puts the binary under whatever node prefix nvm gives — which is exactly the situation this machine is in (`opencode` resolves into `~/.nvm/.../bin`, not `/usr/local/bin`).
2. **Docker volume fix: in this change.** Accepted as a pure fix — the `:/data` mount has never held anything, so there is nothing to migrate.
3. **V1 goes away.** The script removes `opencode-ai` (and a 1.x binary on PATH) before installing V2; no side-by-side, no fallback to V1. "Start fresh" is read as *the binary is replaced*; `~/.config/opencode` and `~/.local/share/opencode` are **kept** (V2 reads V1 config, and deleting sessions is not this script's call). Say so if you want a `--purge` option.
4. **`OPENCODE_SERVER_USERNAME` deleted outright.** Not deprecated, not accepted, not read back. `OPENCODE_PASSWORD` becomes the single password env var (`OPENCODE_SERVER_PASSWORD` also honoured by opencode itself, so we write the one name).
5. **Pin `2.2.0`**, digest recorded in the comment.

## 5. Implementation steps

Each step has a gate; do not continue on a failed gate.

1. **Pin bump + docs comment** in `load_config()` (`setup-opencode.sh:70-79`): default `ghcr.io/anomalyco/opencode:<chosen>`, comment with the `imagetools inspect` digest and date. *Verify:* `docker buildx imagetools inspect ghcr.io/anomalyco/opencode:<chosen>` succeeds.
2. **CLI install path** (`install_opencode_cli`): always remove `opencode-ai` via `npm uninstall -g opencode-ai` (idempotent, no `if` needed for the package) and drop any 1.x binary; then install `@opencode/cli` pinned to `OPENCODE_VERSION` (new env, default `2.2.0`), **without** `--force`. Keep the `opencode.json` `{}` bootstrap. Note in the summary that V2 writes `~/.config/opencode/cli.json` on first TUI run. *Verify:* `opencode --version` reports `2.x` on a clean VM **and** on a VM that had `opencode-ai@1.18` installed beforehand — the second run is the one that proves §4.3 works.
3. **Auth env**: `OPENCODE_PASSWORD` is the only username/password knob. Auto-generated, read back from `/srv/opencode/.env` with `sudo sed` (or from the unit file in systemd mode) so a re-run never rotates it. `OPENCODE_SERVER_USERNAME` disappears from `load_config`, `print_config`, `maybe_generate_password`, both templates, and `usage()`. *Verify:* `grep -rn OPENCODE_SERVER_USERNAME tasks/ templates/` is empty; run twice against an existing stack and the password is byte-identical.
4. **Templates**: `env.template` emits `OPENCODE_PASSWORD`; `opencode.service` drops `OPENCODE_SERVER_USERNAME`, adds `OPENCODE_PASSWORD`; both compose templates mount `opencode_data:/root/.local/share/opencode` **and** `opencode_data:/root/.config/opencode` (two named volumes, or one on `/root/.local`) — decide in §4.2. *Verify:* `yamllint`, plus `docker compose config` renders and `docker run --rm -v … debug paths` shows the DB inside the mount.
5. **Health check**: replace `/global/health` with `GET /api/info`, `-u "opencode:${OPENCODE_PASSWORD}"`, accept 200 and parse `"version"`. Keep `wait_for_healthy` for container state. *Verify:* on a VM the probe passes with the right password and fails (non-zero) with a wrong one — a probe that cannot fail is not a gate.
6. **Converge the systemd unit**: change `_write_service_file` to render to a temp file and `diff` against the installed unit; install + `daemon-reload` + restart only on change (the `setup-agentsview.sh` pattern). *Verify:* second `kwisatz apply` on an existing box updates the unit and leaves a running service running.
7. **`sync_models/agents/opencode.py`**: keep writing the V1 shape (decision §3), but stop writing the ignored `reasoning` boolean and instead write `capabilities.reasoning = { supported: <catalog.reasoning> }` **only if** that is a valid V1-shape key — otherwise leave `reasoning` as-is and file a follow-up. *Verify:* `python3 -m ruff check`, then a real `sync-models` run against the live `opencode.json`, then `opencode` starts with no config warnings on stderr.
8. **Docs**: `machine-config.yml` opencode block (drop nothing that is there — `OPENCODE_PORT`/`OPENCODE_HOSTNAME`/`OPENCODE_SERVICE` are all still valid; add `OPENCODE_VERSION` only if you want it pinned there), `AUTOMATIONS.md` §`setup-opencode.sh` (install method, V1 teardown, pinned 2.2.0, `opencode`-as-username auth, volume layout), the script's `usage()`, and `docs/releases/vX.Y.Z.md`.

**Semver, stated plainly instead of decided silently:** by the repo's own rule (MAJOR = breaking `machine-config.yml` keys, removed/renamed `tasks/` scripts, breaking `kwisatz` CLI) this change touches **none** of the three — so it reads as **MINOR** (new `tasks/` behaviour + new `OPENCODE_VERSION`/`OPENCODE_PASSWORD` options). But it *is* a breaking change for anyone who set `OPENCODE_SERVER_USERNAME`, and the docker volume fix silently changes where state lives. My recommendation: ship **MINOR** and give the release note an explicit *Breaking* section; go **MAJOR** if you consider script-level env keys "config keys" in the sense of the rule.

## 6. Test plan

- `shellcheck tasks/setup-opencode.sh`, `yamllint templates/opencode-server/*.yml`, `ruff check sync_models/`, `jq` on nothing new.
- VM run from `tests/README.md`: CLI-only mode, `USE_DOCKER=true` direct mode, `OPENCODE_SERVICE=true` — three runs, **each executed twice** (idempotency + converge gate). The docker run must additionally prove persistence: create a session, `docker compose down && up -d`, session still there.
- Manual on this box after the change: `./kwisatz apply setup-opencode --dry-run`, then real run; `curl -u "opencode:$(sudo sed -n 's/^OPENCODE_PASSWORD=//p' /srv/opencode/.env)" http://localhost:8765/api/info`.
- Regression: `agentsview sync` still indexes opencode sessions after the upgrade (V2 SQLite path, already proven).

## 7. Open risks

- **Postinstall-script failure** if we go npm and the box has npm ≥12 defaults (issue #48884). This is the strongest argument for the tarball route.
- **GHCR `latest` is still 1.x.** Anyone overriding `OPENCODE_IMAGE=…:latest` silently gets V1. `warn_moving_image` already catches the moving tag; worth an explicit "latest is 1.x" note in the help text.
- **V1→V2 config coexistence**: our live `opencode.json` is V1-shaped. If anyone runs the built-in "ask opencode to migrate my config" prompt, our `sync_models` writes will land in a native-V2 file with a different shape — the adapter would then misread it. `OpencodeAdapter.detect()` already has a precedent for refusing on a shape mismatch; add a native-V2-shape warning if `providers` (plural) exists.
- **Plugins**: any V1 plugin present on the box silently does nothing in V2. We install none from this repo, but our `~/.config/opencode/plugins/` dir exists locally — worth one look before upgrading that box.

## 8. Sources

- https://opencode.ai/v2/docs/ · https://opencode.ai/v2/docs/migrate-v1/ · https://opencode.ai/v2/docs/cli/web · https://opencode.ai/v2/docs/models · https://opencode.ai/v2/docs/api (OpenAPI: `server.info` = `GET /api/info`)
- https://github.com/anomalyco/opencode/releases (v2.2.0, 2026-10-27) · https://github.com/anomalyco/opencode/pkgs/container/opencode
- https://github.com/anomalyco/opencode/issues/48884 (postinstall scripts disabled)
- https://anoma.ly/notes/opencode-2-0/ (2.0 overview)
- Local verification 2026-10-28: `opencode v2.1.1` installed; `ghcr.io/anomalyco/opencode:2.2.0` pulled and exercised (`debug paths`, `serve --help`, `/api/info` auth matrix).

## 9. Verification log (implemented 2026-10-28)

Changed: `tasks/setup-opencode.sh`, `templates/opencode-server/{docker-compose.direct.yml,docker-compose.traefik.yml,env.template,opencode.service}`, `AUTOMATIONS.md`, this plan.

| Gate | Result |
|---|---|
| `shellcheck tasks/setup-opencode.sh`, `bash -n`, `yamllint templates/opencode-server/*.yml` | pass |
| `bash tests/lint.sh` (template hardening guards: privileged, floating tags, untagged pulls, example configs) | pass |
| Rendered `docker-compose.direct.yml` via `envsubst` + `docker compose config` | no leftover `${...}`; volumes resolve to `/root/.local/share/opencode` + `/root/.config/opencode` |
| V2 stack from the rendered templates, `GET /api/info` with `-u opencode:<pw>` | **200** `{"version":"2.2.0",…}`; **401** without credentials |
| Persistence: marker written into the container's data dir, `docker compose down && up -d` | marker and non-empty `opencode.db` survive; readiness still 200 (stack torn down with `-v` afterwards) |
| Version string shape | `opencode --version` prints `opencode v2.2.0`, so the version gate greps the number out of the string rather than comparing a prefix (caught after the first draft of the check) |
| `grep -rn OPENCODE_SERVER tasks/ templates/` | only explanatory comments remain |

Two deviations from §5, both forced by the code:

1. **The systemd unit no longer hardcodes `/usr/local/bin/opencode`.** Once the npm install stopped using `sudo`, the binary lives wherever the invoking user's node prefix points (on this machine `~/.nvm/versions/node/v24.7.0/bin/opencode`), so `ExecStart` gets `${OPENCODE_BIN}`, resolved from PATH at install time and an error if not found.
2. **npm commands dropped `sudo`.** `setup-pi.sh` and `setup-deepseek-harness.sh` already install globally without sudo; forcing root would install V2 into a system prefix that loses to the user's nvm prefix on PATH — which is exactly the failure mode §4.3 removes V1 to avoid.

**Known behaviour on upgrade:** a stack that still has the old `OPENCODE_SERVER_PASSWORD` in `.env` (or in its unit) gets a **new** password on the first V2 run, because we only read back `OPENCODE_PASSWORD`. Nothing depends on the old value except a client's saved credentials, and the new one is printed once. Add a legacy fallback read only if you want zero rotation.
