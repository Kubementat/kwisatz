# Feature: Load-Balanced Inference Requests (Private LLM Gateway)

**Status:** Ready for implementation
**Date:** 2026-11-02
**Target branch:** feature branch off `develop` (git worktree, per `AGENTS.md`)
**Semver impact:** MINOR — new task, new optional config file, no breaking keys
**Source plan:** “Private LLM gateway (LiteLLM) in front of all llama-swap boxes” (2026-11-02)
**Supersedes:** `2026-10-26-home-lab-llm-routing-load-balancing-architecture.md` (denkbot)

---

## 1. Overview

Add one private, OpenAI- and Anthropic-compatible endpoint — the **gateway** — in front of the
existing llama-swap boxes. Agents (pi, opencode, Claude Code, Hermes, Open WebUI, n8n) use one
base URL and one key; the gateway chooses the box that serves each request.

The gateway is **LiteLLM Proxy** in one Docker container on **evobox**, at `/srv/llm-gateway`,
listening on port `4000`. It keeps its own model groups, session pins, per-deployment capacity
caps, retries and cooldowns. llama-swap remains the per-box front door and is unchanged in
behavior; the gateway is a routing layer in front of it.

### 1.1 Requirements

| ID | Requirement |
|----|-------------|
| R1 | Agents never choose a machine. They name one public model. |
| R2 | Every turn of a session lands on the box that served turn 1, so the box’s prefix cache is reused. |
| R3 | New sessions go to a box with free capacity, weighted by the box’s real capacity. |
| R4 | A box that is busy, offline or swapping is not chosen for new sessions. |
| R5 | Nothing is exposed to the internet. Reachability is LAN, NetBird and the libvirt bridge only. |

### 1.2 Non-goals

Kubernetes; vLLM/SGLang migration; KV-event-aware routing; a custom router; exposing anything
publicly; per-agent virtual keys (that needs a database — §2.2 C8); a database, Redis, or the
LiteLLM admin UI in v1; TLS on the LAN (NetBird already encrypts remote traffic).

---

## 2. Research verification

The draft plan was checked against the current LiteLLM documentation (stable image
`ghcr.io/berriai/litellm:v1.106.6`, released 2026-10-28), the llama-swap README and this
repository. The following is normative: where it disagrees with the draft plan, this section
wins.

### 2.1 Verified capabilities

| Claim | Status | Evidence |
|-------|--------|----------|
| `optional_pre_call_checks: ["session_affinity"]` pins a session to a deployment | Verified | LiteLLM Routing → Session Affinity |
| `deployment_affinity_ttl_seconds` bounds idle time; default `3600` | Verified | same page |
| Recognised session sources: `x-litellm-session-id`, `x-litellm-trace-id`, `x-<vendor>-session-id`, `metadata.session_id`, OpenCode `x-session-id`/`x-parent-session-id`, Codex `session-id`/`thread-id` | Verified | same page; the draft’s “plain `x-session-id` may not match” is wrong |
| `x-litellm-model-id` returns `model_info.id` | Verified | LiteLLM Response Headers |
| `max_parallel_requests` is a hard per-deployment, **per-worker** cap; overflow is an immediate `429`, no queue | Verified | LiteLLM Routing → Max Parallel Requests |
| That `429` does **not** trigger cooldown; retries/fallbacks may route to a peer | Verified | same page |
| A session pinned to a saturated deployment does **not** yield to a peer | Verified as the documented state; open issue `#45868` requests a yield option | Routing docs + GitHub issue |
| `weight` is honoured by `simple-shuffle`; `order` is a priority tier evaluated **before** the weighted pick | Verified | Routing → Weighted Deployments / Ordering |
| `enable_weighted_failover` retries within the same group, excluding the failed deployment; requires `simple-shuffle` | Verified | Routing → Weighted Failover |
| `session_affinity_repin_on_failover` moves a successful session to its replacement | Present in current docs; **verify on v1.106.6** | Routing → Keep the replacement |
| `/health/liveliness` and `/health/readiness` exist; liveliness needs no auth | Verified | LiteLLM Health |
| `timeout` is total request time; `stream_timeout` is **first-chunk** time | Verified | LiteLLM Timeouts |
| `/v1/messages` translates an Anthropic request to an OpenAI-compatible backend | Verified | Anthropic Unified API |
| `LITELLM_TELEMETRY_DISABLED=true` and `litellm_settings.turn_off_message_logging: true` | Verified | Telemetry / Logging docs |
| `--num_workers` defaults to `1` | Verified | LiteLLM CLI |
| llama-swap exposes `/health`, `/running`, `/metrics`, `/v1/models`, `/api/models/unload[/:id]`, Anthropic `/v1/messages` | Verified | llama-swap README |
| llama-swap `ttl: 0` means never auto-unload; `matrix` allows concurrent models | Verified | llama-swap README + repo templates |

### 2.2 Corrections to the draft plan

These are the substantive corrections. Each one is already reflected in the behaviors and
tests below.

**C1 — `order: 2` is failover-only, not “lower weight”.**
LiteLLM filters by `order` before the weighted pick. A laptop at `order: 2` receives **no new
sessions** while any `order: 1` deployment is healthy; its `weight` is ignored at that tier.
The draft simultaneously says “lower weight” and “order: 2”, which cannot both be true.
Resolution: **laptop defaults to failover-only (`best_effort: true` ⇒ `order: 2`)**. To give
the laptop a share of new sessions, set `best_effort: false`, `order: 1` and a low `weight`
(e.g. `1` against dgx `5` / evobox `1`). The renderer warns when `order > 1` and `weight > 1`.

**C2 — a pinned session at its cap gets `429`; it does not spill to a peer.**
`max_parallel_requests` is a hard cap and a session pin narrows the candidates to one
deployment before the strategy runs. The documented behavior has no “yield” option (open issue
`#45868`). Consequences:
- A **new** session that hits a full box is retried/failed over to a peer when
  `enable_weighted_failover: true` is set (this is why it is in the rendered config).
- A **pinned** session that opens a second concurrent turn against a 1-slot Gufo box gets
  `429`, and the agent must retry. `num_retries` may re-hit the same pinned target, so it can only add
  latency before the same `429`; T4 records the real behavior on the pinned image.
- Mitigations, in order: document client retry; raise the Strix cap to `2` and let Gufo queue
  internally; or add Postgres + per-agent keys and accept coarser affinity (out of scope v1).

**C3 — UFW does not filter Docker-published ports.**
Docker installs its own `nat`/`filter` rules; `ufw allow from <cidr> to any port 4000` does not
restrict a container published with `ports:`. The draft’s “UFW allow_from” would create a
false sense of security. Resolution: the **address binding is the primary exposure control**;
source restriction is enforced in Docker’s `DOCKER-USER` chain, managed by a tagged oneshot
systemd unit so it survives Docker restarts and reboots. UFW remains the host firewall for
every other service. This is the single documented exception to the repo’s “UFW only” rule,
because UFW cannot see this traffic path. See Behavior 6.

**C4 — render secrets before rendering config, not after.**
The renderer must validate that every referenced `api_key_env` exists. The draft’s order
(render → create `.env`) makes that impossible. Resolution: pre-flight → ensure `.env` →
validate/render → compose → start.

**C5 — `api_key_env` is optional.**
The repo’s llama-swap template ships `apiKeys` commented out and `setup-llama-swap.sh` does not
generate a key. A backend may legitimately need no key. The renderer omits `api_key` when the
field is absent, and only validates env names that are present.

**C6 — do not enable `deployment_affinity` with a shared master key.**
On the proxy, `deployment_affinity` pins by **caller** — the virtual key, or the authenticated
user. All agents share the master key, so enabling it would pin every headerless client to one
box. Virtual keys require a database. Resolution: `session_affinity` only; clients that send no
session header lose affinity (documented degradation), they are not pinned globally.

**C7 — do not enable LiteLLM background health checks.**
A LiteLLM health check issues a completion against the deployment. Against llama-swap that
loads (and may swap) a model, defeating D5 and causing multi-minute cold loads. Resolution:
no background health checks; use request failures + cooldown, and `--check` only probes
`/health` or `/v1/models` **on the backend**, never a completion. For the same reason nothing
may probe the gateway's own `/health` for monitoring — only `/health/liveliness` (which checks
the process, not the deployments).

**C8 — no database means no per-agent virtual keys and no admin UI.**
`master_key` + static `model_list` works without a database. Virtual keys, spend tracking and
the admin UI do not. Resolution: v1 uses one master key; per-agent keys are a future feature
that adds Postgres (and should be a separate spec).

**C9 — the compose file cannot loop over addresses.**
A static template cannot emit a variable-length `ports:` list. Resolution: the renderer emits a
`compose.ports.yml` override; the static `docker-compose.yml` has no `ports:`. Compose is
invoked with both files.

**C10 — publishing on a missing address fails the container.**
Docker refuses to bind an address that is not assigned to a local interface. `192.168.122.1`
is absent when libvirt is off; the NetBird address is absent when NetBird is down. Resolution:
pre-flight verifies every address with `ip -o addr`; missing addresses are a hard error unless
`GATEWAY_ALLOW_MISSING_ADDRESSES=true`, which skips them with a warning.

**C11 — a single-box model on the same box still evicts the shared model.**
D5 protects the *shared group* from being routed to a box that does not keep the model
resident. It does not stop an operator from requesting a swappable single-box model on a box
that also serves the shared group; that request will unload the shared model for every session
pinned there. Resolution: the renderer warns when a backend is both in a shared group and in a
single-deployment model. T6 asserts **no cross-box swap**, not “no unload on the correct box”.

**C12 — Spark `PARALLEL=5` is a design default, not current state.**
`templates/tensorfold-spark-qwen38-flash/serve.env` does not set `PARALLEL`; the design note
`docs/plans/tensorfold-qwen3.8-flash-next.md` does. P0 verifies the live value on dgx and either
sets `PARALLEL=5` explicitly or adjusts the gateway cap to the observed value.

### 2.3 Decisions carried over

D1 LiteLLM as the router; D2 session affinity as the cache strategy; D3 each box keeps its own
model ids; D4 hard per-deployment caps equal to engine parallelism; D5 only resident models in
shared groups; D6 private-only exposure; D7 laptop is best-effort; D8 direct `:9292` is the
break-glass path. The corrections above refine D4/D6/D7 but do not change their intent.

### 2.4 Current state (verified in the repo)

| Box | llama-swap | Flash Next id | Engine | Parallel | Readiness |
|-----|-----------|---------------|--------|----------|-----------|
| dgx (DGX Spark) | `:9292` | `qwen3.8-flash-next`; aliases `Qwen3.8-Flash-Next`, `qwen3.8-flash`, `qwen3.8` | TensorFold v0.6.1, proxy `:8888` | design `PARALLEL=5`; **P0 verify** | `/health` |
| evobox (Strix Halo) | `:9292` | `qwen3.8-flash-next-gufo`; aliases `Qwen3.8-Flash-Next-GGUF`, `qwen3.8-flash-gufo` | Gufo, fixed port | `GUFO_SESSIONS=1` (task default) | `/v1/models` |
| laptop (Strix Halo) | `:9292` on NetBird IP | assume same as evobox — **P0 verify** | Gufo | assume `1` — **P0 verify** | `/v1/models` |

Relevant repo files:

- `tasks/setup-llama-swap.sh`, `templates/llama-swap/config.yaml` (`apiKeys` and `peers` are
  commented out; `LLAMA_SWAP_LISTEN_ADDR` defaults to `0.0.0.0:9292`)
- `templates/tensorfold-spark-qwen38-flash/{models-entry.yml,serve.env}`
- `templates/gufo-strix-halo-qwen38-flash/{models-entry.yml,serve.env}`
- `tasks/sync-models.py`, `sync_models/agents/{pi,opencode}.py`, `models.yml.example`
- `tasks/configure-firewall.sh` (`FIREWALL_EXTRA_PORTS` only; no source CIDRs)
- `templates/monitoring/prometheus.yml` (Docker SD by label; llama-swap is systemd, so it is
  **not** currently scraped)
- `templates/hermes/hermes-egress.nwfilter.xml`, `tasks/setup-hermes.sh` (auto-allowlists
  `HERMES_LLM_BASE_URL` when the host is the libvirt gateway or an IPv4)
- `lib/helpers.sh` (`env_file_get`, `env_file_write`, `wait_for_healthy`)

### 2.5 Repo integration constraints

- `setup-llm-gateway` must be added to `machine-config-inference.yml.example` or
  `tests/lint.sh` guard 5 fails (every example key must name an existing task).
- Templates must keep `${...}` image placeholders; `tests/lint.sh` guard 2 rejects `:latest`
  and untagged images.
- New shell must pass ShellCheck; new Python must pass `ruff`; YAML must pass `yamllint`.
- Secrets are never substituted into generated files: the LiteLLM config contains
  `os.environ/NAME`, never a value. `/srv/llm-gateway/.env` is mode `600`, owned by root.

---

## 3. Architecture

```text
 pi   opencode   Claude Code   Hermes VM   Open WebUI   n8n
  \       |          |            |            |        /
   \      |          |            |            |       /
        one base URL + one key (OpenAI /v1, Anthropic /v1/messages)
                          |
                          v
              +---------------------------+
              |  gateway (LiteLLM)        |
              |  evobox:4000              |
              |  - model groups           |
              |  - session affinity       |
              |  - per-deployment caps    |
              |  - retries / cooldowns    |
              +---------------------------+
                 |          |          |
        LAN      |          |          |  NetBird (failover)
                 v          v          v
            dgx:9292   evobox:9292  laptop:9292
            TensorFold    Gufo         Gufo
              :8888
```

### 3.1 Request flow

1. A client sends `POST /v1/chat/completions` (or `/v1/messages`) with a public model name and
   the gateway master key.
2. LiteLLM authenticates the key and resolves the public name to its model group.
3. The `session_affinity` pre-call check looks up a pin for `(session id, model group)`. A hit
   narrows the candidates to the pinned deployment.
4. On a miss, `simple-shuffle` picks an `order: 1` deployment using `weight`; the first
   successful response creates the pin.
5. The request goes to that box’s llama-swap at `http://<box>:9292/v1`, with the backend’s own
   model id. llama-swap loads the model if needed and proxies to TensorFold or Gufo.
6. `x-litellm-model-id` on the response names the deployment that served it.

### 3.2 Failure and saturation behavior

- **Box offline:** the request fails; retries/`enable_weighted_failover` try a peer. Repeated
  failures cool the deployment down (`allowed_fails`, `cooldown_time`). The pin is kept; with
  `session_affinity_repin_on_failover: true` a successful replacement becomes the new pin while
  the original is still cooled down.
- **New session, target at cap:** immediate `429`; with `enable_weighted_failover` the retry may
  re-pick a peer (T4 confirms on the pinned image). The new session pins to whichever deployment
  succeeds.
- **Pinned session, target at cap:** immediate `429`; there is no yield (C2). The client must
  retry, or the cap must be raised.
- **Box swapping:** not directly observable by LiteLLM. Protection comes from D5: shared groups
  contain only models the box keeps resident. A box that is swapping a single-box model is not
  a candidate for the shared group because it is not in that group.

### 3.3 Placement and break-glass

- The gateway runs on **evobox**, which is also a backend. It is a single point of failure by
  design; D8 keeps `http://<box>:9292/v1` working unchanged.
- Stopping the gateway is `cd /srv/llm-gateway && docker compose -f docker-compose.yml -f
  compose.ports.yml down` (manual, not part of a normal task run). Re-pointing an agent to `:9292`
  must not require a config regeneration.
- Without Redis, pins live in the single proxy worker’s memory. A gateway restart or
  `--force` recreate drops all pins; sessions re-pin on their next turn (one cold prefill each).
  This is acceptable for v1 and is documented in `README_LLM_GATEWAY.md`.

---

## 4. Configuration

### 4.1 `gateway.yml` (user-owned, gitignored)

Default location: `<repo>/gateway.yml`, overridable with `GATEWAY_YML`. The committed example is
`gateway.yml.example`. It contains **no secret values**, only environment-variable names.

```yaml
version: 1

listen:
  port: 4000
  # Every address the port is published on. Never 0.0.0.0 or ::.
  # Each address must be assigned to a local interface at apply time.
  addresses:
    - 192.168.178.57      # evobox LAN
    - 100.64.0.10         # evobox NetBird (placeholder; P0: `ip -4 addr show wt0`)
    - 192.168.122.1       # libvirt bridge, for the Hermes VM
  # Source CIDRs allowed to reach the published port. Enforced in DOCKER-USER (C3).
  allow_from:
    - 192.168.178.0/24
    - 100.64.0.0/10
    - 192.168.122.0/24

affinity_ttl_seconds: 7200
request_timeout_seconds: 1200

backends:
  dgx:
    base_url: http://192.168.178.104:9292/v1
    api_key_env: LLAMA_SWAP_KEY_DGX       # optional; omit when the box has no apiKeys
  evobox:
    base_url: http://192.168.178.57:9292/v1
    api_key_env: LLAMA_SWAP_KEY_EVOBOX
  laptop:
    base_url: http://100.64.0.20:9292/v1
    api_key_env: LLAMA_SWAP_KEY_LAPTOP
    best_effort: true                     # ⇒ order 2 (failover only, C1)

models:
  # Shared group: every backend must keep this model resident (ttl: 0 / matrix).
  - name: qwen3.8-flash-next
    aliases: [qwen3.8-flash]              # optional; rendered as model_group_alias
    deployments:
      - backend: dgx
        model: qwen3.8-flash-next
        id: dgx-qwen3.8-flash-next
        max_parallel: 5                   # = TensorFold PARALLEL
        weight: 5
        order: 1
        resident: true
      - backend: evobox
        model: qwen3.8-flash-next-gufo
        id: evobox-qwen3.8-flash-next
        max_parallel: 1                   # = GUFO_SESSIONS
        weight: 1
        order: 1
        resident: true
      - backend: laptop
        model: qwen3.8-flash-next-gufo
        id: laptop-qwen3.8-flash-next
        max_parallel: 1
        weight: 1
        resident: true

  # Single-box model: one deployment; not load-balanced. On evobox this evicts
  # Flash Next while it runs (C11) — deliberate, and warned about by the renderer.
  - name: qwen3.8-27b
    deployments:
      - backend: evobox
        model: qwen3.8-27b-gufo
        id: evobox-qwen3.8-27b
        max_parallel: 1
        resident: false
```

### 4.2 Field reference

| Field | Required | Default | Meaning |
|-------|----------|---------|---------|
| `version` | yes | — | Must be `1`. |
| `listen.port` | no | `4000` | Host and container port; `LLM_GATEWAY_PORT` must match it when set (§4.2.1). |
| `listen.addresses` | yes | — | IPv4 addresses to publish on. Empty, `0.0.0.0`, `::`, hostnames and duplicates are rejected. |
| `listen.allow_from` | yes | — | IPv4 CIDRs allowed to reach the port. `0.0.0.0/0`/`::/0` rejected. |
| `affinity_ttl_seconds` | no | `7200` | Idle TTL of a session pin. |
| `request_timeout_seconds` | no | `1200` | Rendered as both `timeout` and `stream_timeout`; must exceed the backend's llama-swap `healthCheckTimeout` (dgx 900). |
| `backends.<name>.base_url` | yes | — | OpenAI-compatible base, normally `http://host:9292/v1`. http/https, no credentials, no query. |
| `backends.<name>.api_key_env` | no | — | Env var in `/srv/llm-gateway/.env`. When omitted, no `api_key` is sent upstream. |
| `backends.<name>.best_effort` | no | `false` | When true, deployment defaults to `order: 2` and receives no new sessions (C1). |
| `models[].name` | yes | — | Public model id agents use. Unique; `[A-Za-z0-9._/-]+`. |
| `models[].aliases` | no | `[]` | Extra public names rendered as `model_group_alias`. Must not collide with a public name. |
| `models[].deployments[].backend` | yes | — | Must name a configured backend. |
| `models[].deployments[].model` | yes | — | The box’s own llama-swap model id, sent upstream. |
| `models[].deployments[].id` | no | `<backend>-<model>` | Stable `model_info.id`; unique across the file. |
| `models[].deployments[].max_parallel` | no | `1` | Hard cap, equal to engine parallelism. |
| `models[].deployments[].weight` | no | `1` | `simple-shuffle` weight for the first request of a session. |
| `models[].deployments[].order` | no | `1` | Priority tier; lower is tried first; `order > 1` is failover-only. |
| `models[].deployments[].resident` | no | `true` | Operator assertion that the box keeps the model loaded (`ttl: 0`/matrix). |

#### 4.2.1 Port precedence

`listen.port` is the single source of truth. The task reads it with
`render-llm-gateway-config.py --config gateway.yml --print-port`, exports the value as
`LLM_GATEWAY_PORT` for compose interpolation and for the `--port` argument, and passes the same
value to the renderer. When `LLM_GATEWAY_PORT` is already set in the environment it must equal
`listen.port`; a mismatch is exit 1 rather than a silent divergence, and `--check` prints the
effective port.

### 4.3 Validation rules

The renderer validates the whole file and reports **all** errors in one run (like
`sync-models.py`), then exits non-zero without writing anything:

1. `version == 1`; unknown top-level/backend/model/deployment keys are errors; duplicate YAML
   keys are errors.
2. `listen.addresses` non-empty, valid IPv4, unique, no `0.0.0.0`/`::`; `listen.allow_from`
   non-empty, valid CIDRs, no default route, unique.
3. Backend names unique and shell/JSON safe; `base_url` valid; `api_key_env` matches
   `[A-Za-z_][A-Za-z0-9_]*`; every referenced name exists and is non-empty in `.env`.
4. Public model names unique; aliases unique and not equal to any public name; at least one
   deployment per model.
5. Every deployment’s `backend` exists; `model` non-empty; `id` unique; `max_parallel >= 1`;
   `weight >= 1`; `order >= 1`; `resident` boolean.
6. A shared group (more than one deployment) must have `resident: true` on every deployment
   (D5). A single-deployment model may be `resident: false`.
7. `best_effort: true` with an explicit `order: 1` is an error; `order > 1` with `weight > 1`
   is a warning (the weight is ignored at that tier).
8. Warning: a backend appears both in a shared group and in a single-deployment model (C11).
9. Warning: an alias equals a backend’s model id or another model’s upstream id; the operator
   may still intend it, but the collision should be visible.
10. Output is deterministic: model and deployment order follow the document; generated ids are
    stable; the same input byte-for-byte produces the same output.

### 4.4 Secrets: `/srv/llm-gateway/.env`

Mode `0600`, owner `root`. Rendered from `templates/llm-gateway/env.template`; existing values
are **read back and kept** (`env_file_get` / `env_file_write`), never rotated on a re-run.

```dotenv
# Generated once by setup-llm-gateway.sh; never overwrite a non-empty value.
LITELLM_MASTER_KEY=sk-...
# One per backend that requires a key; optional for boxes without apiKeys.
LLAMA_SWAP_KEY_DGX=...
LLAMA_SWAP_KEY_EVOBOX=...
LLAMA_SWAP_KEY_LAPTOP=...
```

- `LITELLM_MASTER_KEY` is generated as `sk-` + 64 hex characters when absent or empty.
- A referenced `*_api_key_env` that is missing or empty is a hard error listing every missing
  name and the file path; values are never printed.
- Unknown keys already present in `.env` are preserved.
- The LiteLLM config holds `os.environ/NAME` only; no secret is ever written into `config.yaml`.

### 4.5 Rendered LiteLLM configuration

Generated at `/srv/llm-gateway/config.yaml` (mode `0644`, root-owned) by
`tasks/render-llm-gateway-config.py`; the file says “generated, do not edit”.

```yaml
model_list:
  - model_name: qwen3.8-flash-next
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: http://192.168.178.104:9292/v1
      api_key: os.environ/LLAMA_SWAP_KEY_DGX
      max_parallel_requests: 5
      weight: 5
      order: 1
      timeout: 1200
      stream_timeout: 1200
    model_info:
      id: dgx-qwen3.8-flash-next
  - model_name: qwen3.8-flash-next
    litellm_params:
      model: openai/qwen3.8-flash-next-gufo
      api_base: http://192.168.178.57:9292/v1
      api_key: os.environ/LLAMA_SWAP_KEY_EVOBOX
      max_parallel_requests: 1
      weight: 1
      order: 1
      timeout: 1200
      stream_timeout: 1200
    model_info:
      id: evobox-qwen3.8-flash-next
  # ... laptop (order 2, no new sessions) ...

router_settings:
  routing_strategy: simple-shuffle
  optional_pre_call_checks: ["session_affinity"]
  deployment_affinity_ttl_seconds: 7200
  num_retries: 2
  allowed_fails: 3
  cooldown_time: 30
  enable_weighted_failover: true          # verify on v1.106.6
  session_affinity_repin_on_failover: true # verify on v1.106.6
  # Optional, only when gateway.yml declares aliases:
  model_group_alias:
    qwen3.8-flash: qwen3.8-flash-next

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  background_health_checks: false   # C7: a check would issue a completion

litellm_settings:
  turn_off_message_logging: true
```

Deliberately **absent**: `deployment_affinity` (C6), background health checks (C7), a database,
Redis, fallbacks across model groups, and any `api_key` literal.

### 4.6 Docker Compose

`templates/llm-gateway/docker-compose.yml` is static; `compose.ports.yml` is rendered from
`listen.addresses` (C9).

```yaml
services:
  llm-gateway:
    image: ${LLM_GATEWAY_IMAGE}
    container_name: llm-gateway
    restart: unless-stopped
    env_file: .env
    environment:
      LITELLM_TELEMETRY_DISABLED: "true"
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    command:
      - --config
      - /app/config.yaml
      - --port
      - "${LLM_GATEWAY_PORT}"
      - --num_workers
      - "1"
    healthcheck:
      test:
        - CMD-SHELL
        - >-
          python -c "import urllib.request;
          urllib.request.urlopen('http://127.0.0.1:${LLM_GATEWAY_PORT}/health/liveliness')"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

```yaml
# compose.ports.yml — generated; do not edit
services:
  llm-gateway:
    ports:
      - "192.168.178.57:4000:4000"
      - "100.64.0.10:4000:4000"
      - "192.168.122.1:4000:4000"
```

Invocation: `cd /srv/llm-gateway && docker compose -f docker-compose.yml -f compose.ports.yml up -d`
(compose reads `.env` automatically, and the service also declares `env_file: .env`).

The task `envsubst`s `LLM_GATEWAY_IMAGE` and `LLM_GATEWAY_PORT` into the installed
`/srv/llm-gateway/docker-compose.yml` (the template keeps the `${...}` placeholders so
`tests/lint.sh` guard 2 still sees a non-floating reference); `compose.ports.yml` is already
literal. Runtime commands therefore need no interpolation environment, and `docker compose down`
works from the project directory.

`--num_workers 1` is explicit: `max_parallel_requests` and session pins are per worker, so a
second worker would double every cap and split the pin cache.

### 4.7 `machine-config-inference.yml.example`

Add a disabled entry after `setup-monitoring`:

```yaml
  setup-llm-gateway:
    enabled: false
    description: Private LiteLLM gateway in front of the llama-swap boxes
    env:
      LLM_GATEWAY_PORT: '4000'
      LLM_GATEWAY_DIR: /srv/llm-gateway
      LLM_GATEWAY_IMAGE: ghcr.io/berriai/litellm:v1.106.6
      GATEWAY_YML: gateway.yml
    args: []
```

`LLM_GATEWAY_IMAGE` is a placeholder in the template and a pinned default in the task; the pin
is `v1.106.6` (latest stable at 2026-10-28). Re-verify the tag at implementation time and record
a digest in the release notes if the tag moves.

---

## 5. Behaviors

The task follows the repo’s shape: shebang + `set -euo pipefail`, sources `lib/helpers.sh`,
colourful `step/info/success/warn/error` output, non-interactive by default, `--help` kept
current. Exit codes follow the repo's `die`: `0` success/healthy, `1` for any failure
(configuration, pre-flight or health). The message says which kind it was.

### Behavior 1: Pre-flight and argument parsing

**Description.** Validate the host and inputs before changing anything; never prompt.

**Flags.** `--check`, `--force`, `--interactive`, `--help`, `--render-only`, `--warm`.

**Environment (defaults).**

| Variable | Default | Purpose |
|----------|---------|---------|
| `LLM_GATEWAY_DIR` | `/srv/llm-gateway` | Generated project directory. |
| `LLM_GATEWAY_PORT` | `<listen.port>` | Effective port; must equal `listen.port` when set (§4.2.1). |
| `LLM_GATEWAY_IMAGE` | `ghcr.io/berriai/litellm:v1.106.6` | Pinned image. |
| `GATEWAY_YML` | `<repo>/gateway.yml` | Routing config. |
| `WAIT_TIMEOUT` | `180` | Bounded health/smoke wait, seconds. |
| `GATEWAY_WARM` | `false` | Warm shared-group models after start. |
| `GATEWAY_STRICT_BACKENDS` | `false` | Fail when a required backend is unreachable. |
| `GATEWAY_ALLOW_MISSING_ADDRESSES` | `false` | Skip unassigned listen addresses with a warning. |
| `GATEWAY_ALLOW_NO_SOURCE_FILTER` | `false` | Allow address-binding-only exposure (C3). |

**Happy path.**

1. `--help` prints usage, every variable above, endpoints and break-glass note, then exits 0.
2. Docker Engine and Compose v2 are present; `python3` (or the repo `uv` environment) can run
   the renderer; `curl`, `envsubst` (gettext-base), `iptables` and the `DOCKER-USER` chain exist.
3. `GATEWAY_YML` exists and is readable. When absent: copy `gateway.yml.example` next to it,
   print what to edit (addresses, backends, model ids, env names), and exit 1.
4. Every `listen.addresses` entry is assigned to a local interface (`ip -o -4 addr show`);
   every `listen.allow_from` entry is a valid CIDR.
5. The effective port is read from `gateway.yml` (`--print-port`) and must match
   `LLM_GATEWAY_PORT` when that variable is set. The port is free on each address, or already
   held by the `llm-gateway` container.
6. Each non-`best_effort` backend answers a bounded `GET /health` or `GET /v1/models` with the
   configured key. Unreachable backends are a warning; with `GATEWAY_STRICT_BACKENDS=true` they
   are an error.
7. `--check` short-circuits to Behavior 7; `--render-only` short-circuits to Behavior 3.

**Error cases.**

- Missing Docker/Compose/iptables/DOCKER-USER → exit 1 with the exact remediation
  (`setup-docker.sh`, `systemctl start docker`, enable Docker’s iptables management).
- A listen address is not assigned → exit 1 naming the address and interface hint; unless
  `GATEWAY_ALLOW_MISSING_ADDRESSES=true`, which warns and continues.
- A missing `gateway.yml` is never silently generated from defaults.
- Unknown flag → exit 1 with `--help`.

**Edge cases.**

- NetBird down (`100.64.0.10` absent) or libvirt off (`192.168.122.1` absent): the default is a
  hard error, because Docker would fail to bind anyway; the skip flag exists for laptops and
  temporary teardown.
- Port held by a foreign process → exit 1 with `ss -ltnp` output.
- Re-run on a healthy install: no prompts, no changes beyond convergence.

### Behavior 2: Ensure secrets before rendering

**Description.** Create or preserve `/srv/llm-gateway/.env` and prove every referenced key
exists before a config is rendered (C4).

**Happy path.**

1. Create `LLM_GATEWAY_DIR` (root-owned, `0755`) and `.env` (`0600`, root) from
   `templates/llm-gateway/env.template` when absent.
2. Read existing values with `env_file_get`. Generate `LITELLM_MASTER_KEY` as
   `sk-` + 64 hex characters only when absent or empty; never overwrite a non-empty value.
3. Parse `gateway.yml`, collect every `api_key_env`, and verify each is present and non-empty
   in `.env`. Missing names are reported together with the file path and an example line.
4. Write atomically (`mktemp` + `sudo install -m 600`); print the path and key **names**, never
   values.

**Error cases.**

- Missing upstream key(s) → exit 1 listing all of them; no render, no container change.
- `.env` unreadable or wrong owner/mode → fix to `0600`/root or exit 1 with the exact `chmod`
  and `chown` commands.
- A key value contains a newline → exit 1 (would break `env_file` parsing).

**Edge cases.**

- Empty `.env` → treated as fresh; master key generated; referenced keys still required.
- Unknown keys in `.env` → preserved verbatim.
- `--force` and `--interactive` never rotate the master key or upstream keys.

### Behavior 3: Validate and render

**Description.** One Python renderer validates `gateway.yml` + `.env` and atomically writes the
LiteLLM config and the compose port override. It reports all errors at once.

**Happy path.**

1. Invoke `tasks/render-llm-gateway-config.py --config "${GATEWAY_YML}" --env-file
   "${LLM_GATEWAY_DIR}/.env" --out-dir "${LLM_GATEWAY_DIR}" --port "${LLM_GATEWAY_PORT}"`.
   The same script's `--print-port` mode emits only the effective port, which the task uses
   before rendering (Behavior 1, step 5).
2. Validate per §4.3; on success write `config.yaml` (`0644`) and `compose.ports.yml` (`0644`)
   through temp files and `install`, so a partial file is never visible.
3. `config.yaml` contains only `os.environ/NAME` references; `compose.ports.yml` contains one
   `"<address>:<port>:<port>"` entry per listen address, in document order.
4. `--render-only` performs the same validation and writes the files, then exits without
   touching Docker.
5. Output is deterministic; a second run on unchanged input leaves both files byte-identical.

**Error cases.**

- Any validation error → exit 1, print every error with a JSON/YAML path, write nothing.
- Duplicate YAML keys, unknown keys, wrong `version` → exit 1 (strict loader).
- A `0.0.0.0`/`::` address or `0.0.0.0/0` source → exit 1 with the offending line.
- A shared group with `resident: false` → exit 1 (D5).
- A duplicate deployment `id`, public name or alias → exit 1.

**Edge cases.**

- Warnings (backend in a shared and a single model; `order > 1` with `weight > 1`) print but do
  not fail.
- An existing `config.yaml` is replaced only after a successful render; a failed render leaves
  the old file and the running container untouched.
- The renderer is importable by pytest without starting Docker.

### Behavior 4: Render addresses and compose

**Description.** Turn `listen.addresses` into explicit Docker port bindings, never a wildcard.

**Happy path.**

1. Render `compose.ports.yml` from the validated address list (C9).
2. Validate the merged compose file with `docker compose config`.
3. Assert no rendered entry contains `0.0.0.0`, `::` or an empty address.
4. The static compose file has no `ports:` key; only the override publishes.

**Error cases.**

- An address disappeared between pre-flight and render → exit 1 before `up`.
- Compose interpolation or merge error → exit 1 with the `docker compose config` output.

**Edge cases.**

- Multiple addresses are allowed; each is a separate binding.
- Loopback (`127.0.0.1`) is allowed for host-local clients; it is still explicit.
- IPv6 is out of scope in v1; IPv6 addresses and CIDRs are rejected rather than half-supported.

### Behavior 5: Converge the stack and prove it is healthy

**Description.** Start or reconcile the container, then prove LiteLLM answers and lists every
public model. Do not cold-load models unless explicitly asked.

**Happy path (fresh install).**

1. `cd "${LLM_GATEWAY_DIR}" && docker compose -f docker-compose.yml -f compose.ports.yml up -d`.
2. Poll `GET /health/liveliness` from inside the container (`docker compose exec -T llm-gateway
   python -c …`) or the container's health status for `WAIT_TIMEOUT`; fail on timeout with
   `docker compose logs --tail=100`. Do not assume the port is reachable on `127.0.0.1` — it is
   published only on the configured addresses.
3. Smoke test `GET /v1/models` with `Authorization: Bearer $LITELLM_MASTER_KEY`; assert every
   public `models[].name` is present. Aliases are allowed to appear but are not required.
4. With `GATEWAY_WARM=true` (or `--warm`), send one `max_tokens: 1` completion per shared-group
   deployment, bounded by `WAIT_TIMEOUT`; log which box served each (`x-litellm-model-id`).
   Warm failures are warnings unless `GATEWAY_STRICT_BACKENDS=true`.
5. Print the endpoint URLs per address, the env-file path, the agent-wiring command
   (`sync-models.py --agents-only`) and the break-glass note.

**Happy path (existing install).**

1. Re-render, then converge by *what actually changed*:
   - `config.yaml` changed → `docker compose restart llm-gateway`. It is a bind mount, so the
     container's compose config hash does not change and `up -d` alone would leave the old
     config running.
   - `docker-compose.yml`, `compose.ports.yml`, `.env` or `LLM_GATEWAY_IMAGE` changed → `docker
     compose up -d --force-recreate llm-gateway` (env vars and port bindings are fixed at
     creation).
   - Nothing changed → leave the container running.
2. No `down`, never `down -v`.
3. Re-run health and smoke tests; report “converged, no change” when nothing was recreated.
   A `restart` or `--force-recreate` drops every session pin (no Redis, §3.3); that is expected
   and the README says so.

**Error cases.**

- Health timeout → exit 1; print container status and logs; do not print a success summary.
- `/v1/models` missing a public name → exit 1 naming it and the rendered `model_list`.
- `docker compose up -d` failure is never swallowed with `|| true`.

**Edge cases.**

- Backends down: the gateway still starts (it does not need them for `/v1/models`); `--check`
  reports them.
- No shared-group model is warmed by default, so a fresh install does not spend ten minutes
  loading 90 GB unasked.
- A container started by this run is stopped on a later failure in the same run (cleanup trap),
  but a container that was already running is never stopped by the trap.

### Behavior 6: Private exposure and source filtering

**Description.** Publish only on explicit private addresses and enforce the source CIDRs through
Docker’s forwarding hook, because UFW cannot filter published ports (C3).

**Happy path.**

1. `ss -ltnp` shows `<address>:<port>` for each configured address and no `0.0.0.0:<port>` or
   `[::]:<port>`.
2. Install a tagged custom chain `KWISATZ-LLM-GATEWAY` and a jump from `DOCKER-USER`, inserted at
   the head of that chain so a pre-existing `ACCEPT` cannot shadow it:
   - `ESTABLISHED,RELATED` → `RETURN`;
   - each `allow_from` CIDR to TCP `<port>` → `RETURN`;
   - all other TCP `<port>` → `DROP`;
   - everything else → `RETURN` (other containers are untouched).
3. Install `llm-gateway-firewall.service` (oneshot, `After=docker.service`,
   `Requires=docker.service`, `PartOf=docker.service`, `RemainAfterExit=yes`) that re-applies the
   chain after boot or a Docker restart. The task also applies it immediately.
4. Re-running the task flushes and rebuilds only `KWISATZ-LLM-GATEWAY` and ensures exactly one
   jump at the head of `DOCKER-USER`; duplicate rules are impossible.

**Error cases.**

- `DOCKER-USER` absent (Docker iptables management disabled) → exit 1 with the Docker
  remediation; `GATEWAY_ALLOW_NO_SOURCE_FILTER=true` downgrades this to a loud warning and relies
  on address binding only.
- `iptables` fails → exit 1; do not report success.
- An `allow_from` CIDR is invalid or a default route → exit 1 before any rule is changed.

**Edge cases.**

- Docker restart: the unit is `PartOf=docker.service`, so the chain is re-applied.
- Reboot: the unit is enabled.
- A second gateway on another host is independent; the chain name is per host.
- UFW rules for port 4000 are **not** added; `README_LLM_GATEWAY.md` explains why. `ufw` stays
  authoritative for every host-network service.

### Behavior 7: `--check`

**Description.** Report state without changing anything; exit 0 only when everything passes.

**Checks (each prints a labelled PASS/FAIL line; secrets masked).**

1. `gateway.yml` parses and validates; warnings are shown.
2. Every referenced env key is present and non-empty.
3. Rendered `config.yaml` and `compose.ports.yml` match a fresh render (drift check).
4. Container `llm-gateway` is running and healthy.
5. `GET /health/liveliness` and authenticated `GET /v1/models` succeed; every public model is
   listed.
6. Each non-`best_effort` backend answers `/health` or `/v1/models` within a bounded timeout.
7. Every listen address is assigned and the port is bound only there; no `0.0.0.0`/`::`.
8. `KWISATZ-LLM-GATEWAY` exists with the expected allow/drop rules and exactly one
   `DOCKER-USER` jump.
9. `llm-gateway-firewall.service` is enabled/active.

With `GATEWAY_ALLOW_NO_SOURCE_FILTER=true`, checks 8 and 9 report `WARN` instead of `FAIL`; the
rest still decide the exit code.

**Exit codes.** `0` all pass; `1` one or more failures, including an unreadable config or env
file.

**Edge cases.**

- `--check` never sends a completion, so it never loads a model.
- A stopped gateway is reported as such (not an error in the script’s own syntax); exit 1.
- It works before first install: config/env checks run, runtime checks report “not installed”
  and exit 1.

### Behavior 8: `--force`, `--interactive`, cleanup

**Happy path.**

- `--force`: re-render, `up -d --force-recreate llm-gateway`, re-apply the firewall chain; never
  rotate secrets and never `down -v`.
- `--interactive`: show the diff between the rendered files and the installed ones; prompt
  before recreating. The default answer is “converge, do not recreate”. `y` is the only path
  that recreates.
- A cleanup trap stops the container only when this run started it and the run then fails;
  otherwise it leaves a pre-existing service alone.

**Error cases.**

- `--interactive` on a non-TTY → exit 1 (do not hang).
- `--force` with an invalid config → exit 1 before touching the container.

### Behavior 9: Documentation, observability and break-glass

**Happy path.**

1. `README_LLM_GATEWAY.md` documents setup, `gateway.yml`, secrets, verification, agent wiring,
   break-glass, troubleshooting, key rotation and the no-affinity degradation for headerless
   clients.
2. `AUTOMATIONS.md` gains a `setup-llm-gateway.sh` section; `CONTEXT.md` gains **gateway**,
   **deployment**, **session pin**, **resident model**; `README.md` lists the service.
3. P3 observability: add static Prometheus targets for each backend’s llama-swap `/metrics`
   (systemd, not a container, so the existing Docker SD does not find it) and, if enabled, the
   gateway `/metrics` with a bearer token. Grafana panels show requests, in-flight, swaps and
   cached-token ratio. The current `templates/monitoring/prometheus.yml` does not scrape
   llama-swap today; this is a P3 change, not a P1 blocker.
4. Break-glass: direct `http://<box>:9292/v1` with that box’s key remains documented and tested;
   `docker compose down` (both files, manual) removes the gateway without touching llama-swap.

**Error cases.**

- A documentation example that names a nonexistent task or config key is a review blocker.
- Monitoring must not put the master key in `prometheus.yml`; use a file/env reference and mode
  `0600`, or skip gateway scraping in P3.

**Edge cases.**

- Gateway restart drops pins (no Redis). Document the resulting one cold prefill.
- Generated config drift is caught by `--check`, not silently overwritten by a read-only
  operation.

---

## 6. Client wiring

### 6.1 `models.yml` provider

`sync-models.py` already writes pi/opencode provider configs from `models.yml`. Add a `gateway`
provider (the key is a secret; `models.yml` is gitignored):

```yaml
providers:
  - name: gateway
    baseUrl: http://192.168.178.57:4000/v1      # or the NetBird address off-LAN
    apiKey: sk-<LITELLM_MASTER_KEY>
    models:
      - name: qwen3.8-flash-next
        type: remote
        agent:
          contextWindow: 262144
          maxTokens: 32768
          reasoning: true
          input: [text, image]
```

Then `./tasks/sync-models.py --agents-only`. Keep the existing `local`/`dgx` provider entries for
break-glass, clearly commented, or remove them once the gateway is trusted.

### 6.2 Session-header coverage

Affinity exists only when the client sends a recognised session id. LiteLLM’s current list
(verified) is `x-litellm-session-id`, `x-litellm-trace-id`, any `x-<vendor>-session-id`,
`metadata.session_id`, Codex `session-id`/`thread-id`, and OpenCode `x-session-id` /
`x-parent-session-id`. Vendor-style session ids must be at least 8 characters using letters,
digits, hyphens or underscores; a shorter value is ignored.

| Client | Expected header | P1/P2 action |
|--------|-----------------|--------------|
| opencode 2.2.0 | `x-session-id` (OpenCode header) | Verify with `docker logs`/access log and T3; no config change expected. |
| Claude Code | `x-claude-code-session-id` | Verify on `/v1/messages`; no config change expected. |
| Codex | `session-id` or `thread-id` | Verify; outside the P1 set. |
| pi | none documented | Check whether `~/.pi/agent/models.json` supports per-provider headers. If not, pi gets no affinity: each request is a new session and may land on either box. Document this; do not enable `deployment_affinity` (C6). |
| Open WebUI, n8n, Hermes | none documented | Same as pi: no affinity unless the app forwards a stable session header. Verify per app; document the degradation. |
| curl / tests | `x-litellm-session-id` | The deterministic T3/T4/T5 mechanism. |

A client with no session header still works; it simply loses prefix-cache locality. The only
fix without client cooperation is per-client virtual keys plus `deployment_affinity`, which
requires Postgres (C8) and is out of scope for v1.

### 6.3 Hermes VM

Set `HERMES_LLM_BASE_URL=http://192.168.122.1:4000/v1`, `HERMES_LLM_MODEL=qwen3.8-flash-next`
and `HERMES_LLM_API_KEY=<master key>`. `setup-hermes.sh` auto-adds the endpoint to the egress
allowlist when the host is the libvirt gateway or an IPv4; verify the rendered
`hermes-egress.nwfilter.xml` contains the `192.168.122.1:4000` accept rule before the private
`drop` rules. The VM reaches the gateway over the bridge, never the LAN.

### 6.4 Claude Code (optional)

LiteLLM’s `/v1/messages` translates to an OpenAI-compatible upstream. Point Claude Code at the
gateway root (no `/v1`):

```bash
export ANTHROPIC_BASE_URL=http://192.168.178.57:4000
export ANTHROPIC_AUTH_TOKEN=sk-<master key>
export ANTHROPIC_MODEL=qwen3.8-flash-next
```

Verify streaming and one tool call in P2. If translation of tool blocks is lossy on the pinned
version, keep Claude Code on a direct llama-swap endpoint and document that; this is not a P1
gate.

---

## 7. Tests

### 7.1 Renderer unit tests (`tests/unit/test_llm_gateway_render.py`)

Run with `uv run pytest`. Import the renderer directly (no Docker, no network) and compare YAML
structures, not strings, except for the golden-file test.

| ID | Input | Expected |
|----|-------|----------|
| U1 | `gateway.yml.example` + fixture env | Valid; `config.yaml` and `compose.ports.yml` match golden files. |
| U2 | `0.0.0.0` and `::` addresses; `0.0.0.0/0` in `allow_from` | Exit 1; both errors reported together; nothing written. |
| U3 | Deployment names an unknown backend | Exit 1 naming the model/deployment/backend. |
| U4 | Duplicate public name, alias or deployment `id` | Exit 1 listing all duplicates. |
| U5 | `max_parallel: 0`, `weight: 0`, `order: 0` | Exit 1 per field. |
| U6 | Two referenced env keys missing/empty | Exit 1 listing both, no secret values in output. |
| U7 | Shared group with `resident: false` | Exit 1 (D5). |
| U8 | `best_effort: true` with explicit `order: 1`; `order: 2` with `weight: 2` | Error / warning respectively. |
| U9 | Same input rendered twice | Byte-identical outputs. |
| U10 | Any valid input | Rendered config contains `os.environ/...` and no value from `.env`. |
| U11 | Duplicate YAML key, unknown key, `version: 2` | Exit 1 with the path. |
| U12 | Three addresses | `compose.ports.yml` has exactly three bindings, in document order, no wildcard. |
| U13 | Backend in both a shared and a single-deployment model | Warning emitted; exit 0. |
| U14 | Missing `api_key_env` on one backend | Valid; no `api_key` line for that deployment. |
| U15 | `--print-port` on a valid file | Prints only the effective port (`listen.port`) and exits 0. |

### 7.2 Manual/integration protocol (P1–P2)

Run on evobox with the three boxes reachable. Use `$KEY` for the master key and `$G` for the
gateway base URL.

**T1 — Private exposure.**
`ss -ltnp | grep :4000` shows only the configured addresses; `docker compose config` shows the
same bindings; `iptables -S KWISATZ-LLM-GATEWAY` shows the allow CIDRs and the drop rule; from a
non-allowed network (phone hotspot) `curl --max-time 5 $G/v1/models` times out. Pass: no
wildcard listener, no external answer.

**T2 — Authentication.**
`curl -s -o /dev/null -w '%{http_code}' $G/v1/models` → `401`;
`curl -s -H "Authorization: Bearer $KEY" $G/v1/models` → `200` and lists every public model.

**T3 — Stickiness.**
Send five turns with `-H "x-litellm-session-id: t3-fixed"`; every response carries the same
`x-litellm-model-id`. On TensorFold turns 2–5 show rising `cached=` (engine log) or rising
`usage.prompt_tokens_details.cached_tokens`. Pass: same deployment for all five.

**T4 — Capacity.**
(a) Six concurrent **new** sessions with distinct ids: all `200`; no more than one in flight on
evobox at a time; dgx serves at least three (random 5:1). (b) Pin a session to evobox (repeat
until `x-litellm-model-id` is evobox), then send two concurrent turns: record whether the second
is `429`, served by dgx, or queued. Expected: `429` (C2); document the observed behavior and
the client retry setting. If `num_retries` only re-hits the same pinned box, set it to `0` for
fast failure and let the client retry.

**T5 — Failover.**
Stop evobox’s llama-swap; a pinned evobox session’s next turn succeeds on dgx (one cold
prefill) within `num_retries`. Restart evobox; after `cooldown_time`, new sessions can land on
evobox again. With `session_affinity_repin_on_failover`, the old session stays on dgx until the
affinity TTL; without it, it returns to evobox. Record which behavior the pinned image has.

**T6 — Swap safety (cross-box).**
Send ten requests for a single-deployment model; every `x-litellm-model-id` is that deployment;
the other boxes’ `/running` does not list that model. On the correct box, a swappable model may
evict the shared resident model (C11); that is expected and must be stated in the README.

**T7 — Idempotency and secrets.**
Run the task twice. Pass: master key and upstream keys unchanged; config and ports hashes
unchanged; container not recreated; exactly one firewall jump; no duplicate rules; second run
prints “converged”.

**T8 — Break-glass.**
Stop the gateway; direct `http://<box>:9292/v1/chat/completions` with that box’s key still
answers. Restart the gateway; agents work again.

**T9 — Header coverage.**
For each client in §6.2, run two turns and inspect the gateway/llama-swap logs for the session
id and the same `x-litellm-model-id`. Record “affinity” or “no affinity” per client in the
README. This is a P2 exit criterion for pi/Open WebUI/n8n.

**T10 — Anthropic endpoint (optional).**
`POST $G/v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01` returns a translated
completion; Claude Code streams and completes one tool call. If it fails, document direct
`:9292` as the Claude Code path.

### 7.3 Quality gates

- `shellcheck tasks/setup-llm-gateway.sh`
- `uv run ruff check tasks/render-llm-gateway-config.py tests/unit/test_llm_gateway_render.py`
- `yamllint templates/llm-gateway/ gateway.yml.example machine-config-inference.yml.example`
- `uv run pytest`
- `tests/lint.sh` (including guard 5: the example key names the new task)
- VM integration/idempotency for the new task where the VM can satisfy the address/backends
  contract; otherwise the unit + manual protocol above is the acceptance gate and the spec says
  why.

---

## 8. Rollout phases

| Phase | Scope | Exit criterion |
|-------|-------|----------------|
| **P0** | Inventory all three boxes: `GET /v1/models` and `/running` (authed), the live `ttl` of each model, `PARALLEL` on dgx, `GUFO_SESSIONS` on evobox/laptop, whether `apiKeys` is set, the NetBird IP (`ip -4 addr show wt0`), `192.168.122.1`, and the laptop model id. Fill `gateway.yml`. | Renderer validates with no D5 (`resident`) errors; any C11 eviction warnings are reviewed and accepted explicitly; caps match observed engine parallelism. |
| **P1** | Renderer + task + compose on evobox; Flash Next group with dgx + evobox; one agent repointed. | T1–T6 pass, including the recorded pinned-429 behavior. |
| **P2** | Laptop joins as failover (`best_effort: true`); all agents + Hermes migrated; header coverage recorded; README/AUTOMATIONS/CONTEXT updated. | Two agents started without thinking land on different boxes and stay sticky for a full work session; every client’s affinity status is documented. |
| **P3** | Observability: Prometheus targets for llama-swap `/metrics` and (optionally) gateway `/metrics`; Grafana panels; one week of data. | Decide whether weights/caps need tuning or `GUFO_SESSIONS=2` is worth testing (memory-tight with ~94 GB weights). |

**P0 commands (sketch).**

```bash
for h in 192.168.178.104 192.168.178.57 <laptop-netbird-ip>; do
  curl -s -H "Authorization: Bearer $KEY" "http://$h:9292/v1/models" | jq -r '.data[].id'
  curl -s -H "Authorization: Bearer $KEY" "http://$h:9292/running" | jq .
done
ip -4 addr show wt0        # evobox NetBird address
ip -4 addr show virbr0     # 192.168.122.1
```

---

## 9. Risks and mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Pinned session at cap gets `429` (C2) | A second concurrent turn on a 1-slot box fails | Document client retry; raise Strix cap to 2 and let Gufo queue; per-agent keys + Postgres later. |
| `order: 2` misread as “low weight” (C1) | Laptop never gets new sessions | `best_effort` semantics documented; renderer warns on `order > 1 && weight > 1`. |
| UFW does not filter Docker ports (C3) | False sense of source restriction | Address binding + `DOCKER-USER` chain + oneshot unit; `--check` verifies it. |
| A listen address is absent | Container fails to start | Pre-flight `ip addr` check; explicit skip flag. |
| Single-box model evicts the shared model (C11) | Every session pinned to that box pays a cold load | Renderer warning; dedicate a box or add a matrix; T6 measures cross-box correctness only. |
| Gateway restart drops pins | One cold prefill per active session | Documented; Redis would fix it, deliberately out of scope. |
| Laptop offline | Failover traffic may fail once | `best_effort`/order 2, cooldown, retries; laptop is not in the normal path. |
| LiteLLM config keys drift | Startup failure or silently ignored option | Pin `v1.106.6`; verify `enable_weighted_failover` and `session_affinity_repin_on_failover`; fail on config errors in the startup gate. |
| Answers differ between TensorFold and Gufo | Same session sees a different quant/engine after failover | Affinity keeps a session on one box; document that failover may change style. |
| Gateway is a SPOF | All agents lose the endpoint | Break-glass direct `:9292`; `docker compose down` is one command. |
| Prompt/response leakage | Private code leaves the box | `LITELLM_TELEMETRY_DISABLED=true`, `turn_off_message_logging: true`, no callbacks, no DB, no public exposure. |
| Cold load exceeds timeout | First request after a swap fails | `timeout`/`stream_timeout` 1200 s (above dgx's 900 s `healthCheckTimeout`); `--warm` optional; llama-swap default is 500 s. |

---

## 10. Open questions (resolve in P0/P1)

1. Laptop: exact model id, base URL, NetBird IP, `GUFO_SESSIONS`, whether it is reachable at
   all today, and whether it keeps Flash Next resident (`ttl: 0`). A laptop that unloads the
   model cannot join the shared group (D5/R4); it stays out until `ttl: 0` is set there.
2. dgx: is `PARALLEL=5` actually set in `/srv/tensorfold/serve.env`, or is the engine default
   (8) in effect? Set the cap to the observed value.
3. Do the three llama-swap configs actually enable `apiKeys`? If not, omit `api_key_env` for
   those backends (C5).
4. Which of pi, Open WebUI, n8n and Hermes can send a stable session header? If none, document
   no-affinity and decide whether a future Postgres/virtual-key design is worth it.
5. Confirm the NetBird CIDR (`100.64.0.0/10` is the CGNAT default) and that `192.168.122.1`
   exists on evobox.
6. Confirm on `v1.106.6` that `enable_weighted_failover` and
   `session_affinity_repin_on_failover` are accepted; drop the latter if it is not.
7. Is evobox the right gateway host, given it is also a 1-slot backend? The alternative is a
   small always-on box; the plan chooses evobox for locality and Docker.
8. Should Strix run `GUFO_SESSIONS=2`? Memory is tight with ~94 GB weights; P3 data decides.

---

## 11. Deliverables

```text
tasks/setup-llm-gateway.sh                  # new, idempotent, --check/--force/--interactive/--help
tasks/render-llm-gateway-config.py          # new, validates + renders config.yaml + compose.ports.yml
templates/llm-gateway/docker-compose.yml    # new, static service definition (no ports)
templates/llm-gateway/env.template          # new, secret placeholders (0600 at install)
templates/llm-gateway/llm-gateway-firewall.service  # new, oneshot DOCKER-USER unit
gateway.yml.example                         # new, committed; gateway.yml gitignored
.gitignore                                  # add gateway.yml
machine-config-inference.yml.example        # add setup-llm-gateway (enabled: false)
models.yml.example                          # add a commented gateway provider example
README_LLM_GATEWAY.md                       # new: setup, verify, break-glass, troubleshooting
AUTOMATIONS.md, CONTEXT.md, README.md       # task list, terms, service list
tests/unit/test_llm_gateway_render.py       # renderer tests (U1–U15)
tests/unit/fixtures/llm-gateway/            # golden config.yaml/compose.ports.yml + fixture env
docs/plans/2026-11-02-llm-gateway-litellm.md # the source plan, committed with the feature
```

---

## 12. Sources

Accessed 2026-11-02.

- LiteLLM routing, session affinity, weights, order, max parallel, retries:
  <https://docs.litellm.ai/docs/routing>
- LiteLLM cache-aware/session-affinity overview:
  <https://docs.litellm.ai/docs/proxy/cache_aware_routing>
- LiteLLM health endpoints: <https://docs.litellm.ai/docs/proxy/health>
- LiteLLM timeouts: <https://docs.litellm.ai/docs/proxy/timeout>
- LiteLLM telemetry: <https://docs.litellm.ai/docs/proxy/telemetry>
- LiteLLM logging / `turn_off_message_logging`:
  <https://docs.litellm.ai/docs/proxy/logging>
- LiteLLM response headers (`x-litellm-model-id`):
  <https://docs.litellm.ai/docs/proxy/response_headers>
- LiteLLM Anthropic unified API: <https://docs.litellm.ai/docs/anthropic_unified>
- LiteLLM Prometheus metrics: <https://docs.litellm.ai/docs/proxy/prometheus>
- LiteLLM Docker deployment and image tags: <https://docs.litellm.ai/docs/proxy/deploy>
- LiteLLM CLI (`--num_workers`): <https://docs.litellm.ai/docs/proxy/cli>
- LiteLLM issue “let a session-affinity pin yield when saturated”:
  <https://github.com/BerriAI/litellm/issues/45868>
- llama-swap README (`/health`, `/running`, `/metrics`, `/v1/messages`, `ttl`, `matrix`, API keys):
  <https://github.com/mostlygeek/llama-swap>
- Docker vs UFW and `DOCKER-USER`:
  <https://github.com/chaifeng/ufw-docker> and
  <https://docs.docker.com/engine/network/packet-filtering-firewalls/>
- Repo sources: `tasks/setup-llama-swap.sh`, `templates/llama-swap/config.yaml`,
  `templates/tensorfold-spark-qwen38-flash/*`, `templates/gufo-strix-halo-qwen38-flash/*`,
  `tasks/sync-models.py`, `sync_models/agents/*`, `models.yml.example`,
  `tasks/configure-firewall.sh`, `templates/monitoring/prometheus.yml`,
  `templates/hermes/hermes-egress.nwfilter.xml`, `tasks/setup-hermes.sh`, `lib/helpers.sh`,
  `tests/lint.sh`, `specification/project/conventions.md`.
- Repo design note for Spark parallelism: `docs/plans/tensorfold-qwen3.8-flash-next.md`.
