# Feature Plan: Central version management (`versions.yml` + self-hosted Renovate)

## Goal

Every upstream version kwisatz installs (docker images, GitHub releases, PyPI packages,
git commits) is pinned in **one file**, `versions.yml` at the repo root. Task scripts read
their defaults from it. A self-hosted Renovate checks that one file on a schedule, keeps a
Dependency Dashboard issue on Forgejo (the "what is outdated" overview), and opens bump
PRs against `develop`. Nobody has to track ~60 upstreams by hand.

Success criteria:

- `grep` for a version literal in `tasks/*.sh` finds nothing a test does not allowlist;
  every pin lives in `versions.yml`.
- `renovate --platform=local` against the repo lists every entry of `versions.yml` with
  its current and latest version.
- A scheduled Renovate run on the target host opens a PR on Forgejo for an outdated entry
  and keeps the Dependency Dashboard issue current.
- Overrides keep working unchanged: `OPENWEBUI_IMAGE=… ./tasks/setup-openwebui.sh`,
  `env:` in `machine-config.yml`, `kwisatz apply --env`.

## Decisions (agreed)

- **Format:** YAML (comments carry the "why" of a pin or a hold).
- **Floating tags get pinned** to today's exact release (`latest`, `traefik:v3`,
  `forgejo:14`, `stable`, runtime "resolve latest" defaults). Scripts still accept
  `latest` as an explicit override where they do today.
- **Holds** (pins whose next major breaks persisted data) are a comment in `versions.yml`
  plus an `allowedVersions` rule in `renovate.json`; a test keeps the two in sync.
- **Runner:** self-hosted Renovate against Forgejo (primary remote), PRs to `develop`.
- Env var names do not change → no breaking config change → **MINOR** release.

## Design

### `versions.yml`

One entry per installed component, keyed by a stable kebab-case name:

```yaml
openwebui:
  datasource: docker              # docker | github-releases | github-tags | pypi | git-refs
  package: ghcr.io/open-webui/open-webui
  version: v0.11.1
  # digest: sha256:…              # optional; Renovate keeps it current
  # versioning: regex:…           # optional; for odd tag schemes (NGC YY.MM-py3, tensorfold)

temporal-postgres:
  datasource: docker
  package: postgres
  version: "16"
  # HELD <17: data volume is tied to the major, upgrade needs pg_upgrade
```

Fields map 1:1 to Renovate's dependency fields (`datasource`, `packageName`,
`currentValue`, `currentDigest`, `versioning`), so one generic manager reads them all.

### Script side — `lib/helpers.sh`

```bash
kw_version openwebui   # -> v0.11.1
kw_image   openwebui   # -> ghcr.io/open-webui/open-webui:v0.11.1[@sha256:…]
kw_pin     hermes digest
```

- Reads `versions.yml` next to `lib/` (repo root), via system `python3` + PyYAML
  (`python3 -I`, scripts already strip the venv). `yq` is not used: Ubuntu's `yq`
  package changed implementation between releases. Missing key / missing PyYAML →
  loud error, non-zero exit.
- Script lines keep their override semantics, only the default moves:

  ```bash
  OPENWEBUI_IMAGE="${OPENWEBUI_IMAGE:-$(kw_image openwebui)}"
  : "${N8N_IMAGE:=$(kw_image n8n)}"
  ```

- Composed refs stay composed in the script (vllm `-rocm`, vllm-omni suffixes, Matrix
  postgres major derived from `db/PG_VERSION`): the file holds the base version.
- `--help` texts that print defaults print the value from the file.

### Renovate side — `renovate.json`

- One `customManagers` entry, `customType: "jsonata"`, `fileFormat: "yaml"`,
  `managerFilePatterns: ["/^versions\\.yml$/"]`, a JSONata expression emitting
  `{depName: key, packageName, datasource, currentValue, currentDigest, versioning}` per
  entry.
- Built-in managers stay on for `pyproject.toml`/`uv.lock` (kwisatz's own Python deps);
  all other managers off (`enabledManagers`), so the bot only touches what we declare.
- `packageRules`: one `allowedVersions` rule per HELD entry; majors behind
  Dependency Dashboard approval; group the matrix stack and the netbird trio
  (server/dashboard/client must move together).
- Base branch `develop`; Dependency Dashboard on.
- **Verify in step 1** with `renovate --platform=local` that the jsonata/yaml manager and
  the option names (`baseBranches` vs `baseBranchPatterns`, `managerFilePatterns`) match
  the Renovate version we pin — do not trust this plan's spelling.

### Runner — `tasks/setup-renovate.sh` (new task)

- `/srv/renovate/` with `.env` (mode 600): `RENOVATE_TOKEN` (Forgejo bot account PAT),
  `RENOVATE_GITHUB_COM_TOKEN` (read-only, for changelogs and GitHub API rate limits).
  Secrets read back before generating/prompting, per conventions.
- Non-secret config rendered from `templates/renovate/config.js`: `platform: forgejo`,
  endpoint, `repositories: [denkfabrik/kwisatz]`.
- systemd `renovate.service` (oneshot `docker run --rm renovate/renovate:<from
  versions.yml>`) + `renovate.timer` (daily, `RENOVATE_SCHEDULE` overridable).
  Renovate pins itself through `versions.yml` too.
- Health: run once at the end of the script and fail if the run fails.
- `--help`, idempotent, converge on re-run; entry in `machine-config.yml.example`,
  `AUTOMATIONS.md`.

### Local check without PRs — `utilities/check-versions.sh`

Runs the pinned Renovate image with `--platform=local --dry-run=lookup` on the working
tree and prints `key  current → latest` for every entry. Needs only docker (and optionally
a GitHub token for rate limits). Useful before a release and for agents.

### Guard tests — `tests/unit/test_versions.py`

1. Schema: every entry has `datasource`, `package`, `version`; datasource in the allowed
   set; keys kebab-case.
2. Every `kw_image|kw_version|kw_pin <key>` used in `tasks/`/`lib/` exists in the file,
   and every entry is used somewhere (no dead pins).
3. No hard-coded pins in `tasks/*.sh`: regex for image refs with a tag/digest and
   `*_VERSION|_TAG|_REF|_COMMIT` defaults with a literal value; small explicit allowlist
   (e.g. minimum-requirement values like `STRIX_MIN_KERNEL`, `HSA_OVERRIDE_GFX_VERSION`).
4. Every entry whose comment says `HELD` has a matching `allowedVersions` rule in
   `renovate.json`, and vice versa.

## Inventory (what moves into `versions.yml`)

Docker images — full ref in a default var:

| key | current | script | note |
|---|---|---|---|
| openwebui | ghcr.io/open-webui/open-webui:v0.11.1 | setup-openwebui | |
| prometheus, grafana, node-exporter, cadvisor | v3.13.2, 13.1.1, v1.12.1, v0.60.5 | setup-monitoring | |
| synapse, mas, element, livekit, lk-jwt, ketesa, matrix-wellknown (nginx) | see script | setup-matrix | group |
| matrix-postgres | postgres:17-alpine | setup-matrix | HELD; script keeps PG_VERSION logic |
| opencode | ghcr.io/anomalyco/opencode:1.18.25 | setup-opencode | |
| postiz, temporal, temporal-ui, postiz-redis | v2.24.0, 1.28.1, 2.34.0, 7.2 | setup-postiz | |
| postiz-postgres, temporal-postgres | 17-alpine, 16 | setup-postiz | HELD |
| elasticsearch | 7.17.27 | setup-postiz | HELD <8 (Temporal) |
| nextcloud | nextcloud:34-apache | setup-nextcloud | HELD: one major at a time |
| nextcloud-postgres, nextcloud-redis | 17-alpine, 7-alpine | setup-nextcloud | postgres HELD |
| planka | :latest → pin | setup-planka | floating |
| planka-postgres | 16-alpine | setup-planka | HELD |
| omnigent-postgres | 16-alpine (template default) | templates/omnigent/docker-compose.direct.yml | HELD; default moves to script |
| forgejo | :14 → pin exact | setup-forgejo | floating |
| forgejo-postgres | postgres:14 (inline compose) | setup-forgejo | HELD |
| traefik | v3 → pin; n8n's v3.7.12 shares the key | setup-traefik, setup-n8n | floating |
| socket-proxy | v0.5.0@sha256 | setup-traefik | digest |
| n8n | 2.37.4 | setup-n8n | |
| concourse, kestra, dagu | 8.3.0, v2.0.0, 2.16.2 | resp. scripts | |
| excalidraw | :latest → pin by digest | setup-excalidraw | upstream publishes no semver tags |
| omnigent-server | :latest → pin | setup-omnigent | floating |
| nvidia-smoke | ubuntu:24.04 | setup-nvidia-container | |
| renovate | new | setup-renovate | |

Docker images — split or composed:

| key | current | script | note |
|---|---|---|---|
| netbird-server, netbird-dashboard, netbird-client | 0.77.1, v2.91.1, 0.77.1 | setup-netbird | group |
| gufo | 0.8.1 + digest | both setup-gufo-* | one key, two scripts |
| vllm | v0.27.1 (+ `-rocm` image) | setup-vllm | composed |
| vllm-omni | latest → pin | setup-vllm-omni | composed, floating |
| ngc-pytorch | 25.10-py3 | setup-colqwen (Dockerfile ARG) | regex versioning |
| tensorfold-27b-prebuilt | v0.6.0-fb91a0019fdc | setup-tensorfold-spark-qwen38-27b | regex versioning; local build tag follows it |

GitHub releases / tags:

| key | current | script |
|---|---|---|
| agentsview (kenn-io/agentsview) | 0.44.0 | setup-agentsview |
| orca (stablyai/orca) | latest → pin | setup-orca |
| llama-swap (mostlygeek/llama-swap) | latest → pin | setup-llama-swap |
| neovim | stable → pin | setup-neovim |
| ollaya | empty=latest → pin | setup-ollaya |
| whispering (EpicenterHQ/epicenter) | resolved at runtime → pin | setup-whispering |
| llama-cpp (ggml-org/llama.cpp) | latest → pin | setup-llama-cpp |
| ace-step (github-tags) | v0.1.8 | setup-music-gen |
| nanobot (HKUDS/nanobot) | latest tag at runtime → pin | setup-nanobot |
| nvm (nvm-sh/nvm) | 0.40.4 | setup-basics |

PyPI: `colpali-engine` 0.3.13 (setup-colqwen), `laya` 0.3.19 (setup-laya).

Git commits (`git-refs`, digest follows the branch head): hermes, tensorfold-flash recipe,
tensorfold-27b recipe, omnivoice (`master` → pin commit).

Not tracked by Renovate (entry kept in `versions.yml`, `datasource: custom`, excluded):
LM Studio `0.4.6-1` (vendor download site, no API Renovate knows).

## Out of scope (v1) — listed so it is a decision, not an oversight

- **Unpinned installs** that always take latest today: `npm -g` opencode-ai,
  @earendil-works/pi-coding-agent, @colbymchenry/codegraph, @deepseek-ai/dsh, hunkdiff;
  `uv tool install omnigent`; pip pyasynchat, pynvim; torch wheels. Pinning them is a
  follow-up (Renovate has npm/pypi datasources, same file).
- apt packages and the uv installer script.
- Minimum-requirement values (`STRIX_MIN_KERNEL`, `HSA_OVERRIDE_GFX_VERSION`, node major
  for dsh) — these are constraints, not installs.
- Models in `models.yml` / HF model repos.
- `VIRT_RUNNER_BRANCH` (own repo, branch selector).

## Steps

Work in a worktree branch `feature/central-version-management`.

1. **Skeleton + proof.** `versions.yml` with 3 entries (openwebui, agentsview, hermes —
   one per datasource kind), `kw_*` helpers, `renovate.json`, `utilities/check-versions.sh`.
   → verify: local Renovate dry-run lists the 3 deps with lookups; shellcheck, jq.
2. **Guard tests** (schema, key usage, no-hard-coded-pins in report mode, HELD sync).
   → verify: pytest passes; the hard-coded-pins test lists the remaining ~60 literals.
3. **Migrate scripts**, one commit per service family, pinning floating tags to the
   current upstream release at migration time.
   → verify per family: shellcheck, `--help` correct, `bash -n`; the hard-coded-pins
   list shrinks; at the end flip the test from report mode to failing.
4. **Holds + grouping** in `renovate.json`. → verify: HELD sync test; dry-run shows
   no major proposal for held entries.
5. **`tasks/setup-renovate.sh`** + templates + `machine-config.yml.example` entry.
   → verify: VM test (`tests/README.md`): install, first run succeeds, re-run converges,
   timer active; against Forgejo, the Dependency Dashboard issue appears.
6. **Docs:** `AUTOMATIONS.md`, `CONTEXT.md` (term "version pin"),
   `specification/project/conventions.md` (rule: pins live in `versions.yml`, read with
   `kw_*`), AGENTS.md core-facts line.
7. **VM tests** for a sample of migrated tasks covering each pattern (full ref, split
   tag + digest, composed, github release, pypi, git commit).

## Risks

- **Re-runs must pick up a bumped pin.** No script reads image tags back from
  `/srv/<svc>/.env` today (only secrets), but netbird writes its tags there; verify each
  migrated script re-renders the version and `docker compose up -d` converges.
- **Pinning floating tags changes behaviour:** re-runs stop drifting to newer upstreams;
  updates now arrive only via Renovate PRs. Call this out in the release notes.
- **PyYAML on bare hosts:** confirm `python3-yaml` on the test VM image (fresh Ubuntu
  server and desktop); if absent, `setup-basics` installs it and `kw_*` errors with that
  hint.
- **GitHub API rate limits** for ~15 GitHub lookups: the read-only token in the runner.
- **Merging Renovate PRs ≠ tested:** there is no CI that runs the VM tests, so PRs are
  reviewed and VM-tested by hand before merging; no automerge in v1.
