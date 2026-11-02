# Plan: Private LLM Gateway (`tasks/setup-llm-gateway.sh`)

Date: 2026-11-02
Status: implemented (P1 scope; P0 inventory is host work, P2/P3 rollout below)
Feature spec: `specification/features/load-balance-inference-requests-spec.md`
Supersedes: `2026-10-26-home-lab-llm-routing-load-balancing-architecture.md`
Semver impact: MINOR — new task, new optional config file, no breaking keys

## Goal

Put **one private OpenAI- and Anthropic-compatible endpoint** in front of the
llama-swap boxes, so agents and apps share one base URL and one key:

```
pi  opencode  Claude Code  Hermes VM  Open WebUI  n8n
 \      |         |            |          |       /
        one base URL + one key (OpenAI /v1, Anthropic /v1/messages)
                           |
                  gateway (LiteLLM) :4000
                   model groups · session pins
                   per-deployment caps · retries/cooldowns
                    |           |            |
          box-a:9292    box-b:9292    box-c:9292 (best effort)
```

**Non-goals:** replacing llama-swap per box, an admin UI or per-agent virtual
keys (no database), scraping GPU metrics, or changing the engines' model ids.

## What "load balancing" means here

llama-swap already runs one model at a time per box and evicts to swap. The
gateway therefore balances **which box** serves a request, not GPU lanes:

| Behavior | Design |
|----------|--------|
| New request, several boxes | pick by deployment `order` (lower first), then least in-flight; `best_effort` boxes default to `order: 2` |
| Conversation continuity | `session_affinity` pins a session to the deployment that served its first request, keyed on the client's recognized session header |
| Pinned session at its cap | `429` — no silent spill to a box that would reload the model (C2) |
| Box swap risk | every member of a shared group must keep the model resident (`ttl: 0`); the validator enforces it (D5) |
| Box down | retries + `enable_weighted_failover` move the request to a peer; repeated failures open a cooldown |
| Break-glass | agents can always call `<box>:9292` directly; the gateway is not in the data path of a client that opts out |

## Decisions and why

| # | Decision | Reason |
|---|----------|--------|
| 1 | **LiteLLM Proxy in Docker**, on the box that fronts the others | OpenAI *and* Anthropic surfaces, model groups, session affinity, cooldowns in one image; compose matches the repo's other services |
| 2 | **`gateway.yml` is user-owned and gitignored**, `gateway.yml.example` committed | addresses and box names are site-specific; the example is the documented schema and the test fixture source |
| 3 | **A separate renderer** (`tasks/render-llm-gateway-config.py`) | validation is too complex for bash; Python also renders compose ports and the firewall script deterministically, and is unit-testable |
| 4 | **Secrets never rendered**: `.env` (0600 root) + `os.environ/NAME` in config | repo convention; `--check` can prove it by re-rendering |
| 5 | **Explicit publish addresses only**, never `0.0.0.0`/`::` | C9/C10: compose cannot loop over addresses, and publishing on a missing address makes the container fail — so addresses are validated (and optionally skipped) before start |
| 6 | **Source filtering in `DOCKER-USER`**, not UFW | C3: Docker publishes via its own chains and bypasses UFW |
| 7 | **Renderer emits `firewall.sh`**, run by a static oneshot unit | the allowed CIDRs are config, so the iptables calls have to be rendered; the unit stays a template |
| 8 | **No background LiteLLM health checks** | C7: they call every backend and can wake/swap models |
| 9 | **Recreate, not `down -v`**; decline on a TTY prints the command and exits 0 | converge-by-default conventions; never destroy state |
| 10 | **`best_effort: true` implies `order: 2`**; combining it with `order: 1` is an error | keeps failover ordering explicit and unambiguous |

## Deliverables

| Path | Role |
|------|------|
| `tasks/setup-llm-gateway.sh` | preflight, secrets, backend probes, render, converge, health/smoke/warm, firewall, `--check` |
| `tasks/render-llm-gateway-config.py` | strict YAML validation + renders `config.yaml`, `compose.ports.yml`, `firewall.sh` |
| `templates/llm-gateway/docker-compose.yml` | static service definition (no `ports:` — merged with the generated file) |
| `templates/llm-gateway/env.template` | secret placeholders, installed as `/srv/llm-gateway/.env` 0600 root |
| `templates/llm-gateway/llm-gateway-firewall.service` | oneshot unit applying the generated `DOCKER-USER` rules |
| `gateway.yml.example` | committed schema/example; `gateway.yml` is gitignored |
| `machine-config-inference.yml.example` | `setup-llm-gateway` entry, `enabled: false` |
| `models.yml.example` | commented gateway provider |
| `README_LLM_GATEWAY.md` | operator guide: setup, routing, secrets, affinity, exposure, verification, agent wiring, break-glass, troubleshooting |
| `AUTOMATIONS.md`, `CONTEXT.md`, `README.md` | discoverability and shared vocabulary |
| `tests/unit/test_llm_gateway_render.py` + fixtures | U1–U15 renderer coverage, plus plan/address print modes |

## Task flow

```
preflight (root? docker? compose? gateway.yml? renderer?)
  → resolve port (--print-port / LLM_GATEWAY_PORT) and validate listen addresses
  → ensure /srv/llm-gateway/.env (preserve every non-empty key; generate only missing)
  → probe every backend /v1/models (hard error if a deployment's model is absent;
     unreachable required backend = warning, or error with GATEWAY_STRICT_BACKENDS)
  → render into the project dir (atomic writes)
  → install/refresh firewall unit, validate compose config
  → converge: up -d / restart / force-recreate depending on what changed
  → health gate (/health/liveliness) → smoke (/v1/models, chat) → optional --warm
  → install + start the firewall unit, verify the chain
```

`--check` runs the same validations read-only into a temp dir, compares rendered
files with the installed ones, then checks secret mode/ownership, container
health, exposure and firewall state; exit `0` only if all pass.

`--render-only` stops after rendering (config-only changes).

## `gateway.yml` shape

```yaml
listen:
  addresses: [192.0.2.10, 100.64.0.10]      # no wildcards
  port: 4000
  allow_from: [192.0.2.0/24, 100.64.0.0/10]

backends:
  box-a: { base_url: "http://192.0.2.10:9292/v1" }   # this host
  box-b: { base_url: "http://192.0.2.21:9292/v1" }
  box-c:
    base_url: "http://100.64.0.20:9292/v1"          # mesh only
    best_effort: true
    api_key_env: LLAMA_SWAP_KEY_BOX_C

models:
  - name: qwen3.8-flash-next
    session_affinity: true
    deployments:
      - { backend: box-b, model: qwen3.8-flash-next, max_parallel: 2 }
      - { backend: box-a, model: qwen3.8-flash-next-gufo, max_parallel: 1 }
      - { backend: box-c, model: qwen3.8-flash-next-gufo, max_parallel: 1 }
```

Validation collects **all** errors (duplicate keys, unknown fields, wildcard
addresses, empty `allow_from`, a model missing from its backend, caps ≤ 0,
affinity without a stable header, shared-group members without `ttl: 0`, a
single-box model sharing a box with a resident group model → C11 warning).

## Renderer output

| File | Content |
|------|---------|
| `config.yaml` | `model_list` with public names and per-deployment params, `router_settings` (retries, cooldowns, failover), `litellm_settings`, master key as `os.environ/LLM_GATEWAY_MASTER_KEY` |
| `compose.ports.yml` | one `"ip:port:4000"` short-syntax entry per validated address |
| `firewall.sh` | idempotent `DOCKER-USER` chain: allow `allow_from` → drop the rest, scoped to the published port |

Print modes for bash: `--print-port`, `--print-addresses`, `--print-plan`
(tab-separated validated routing plan), `--exclude-address` (skip an interface
that is down).

## Tests

`tests/unit/test_llm_gateway_render.py` (21 tests) covers:

- U1–U3: strict YAML (duplicates, unknown keys, missing top-level keys)
- U4–U7: address/port validation, wildcard rejection, empty `allow_from`
- U8–U10: deployment/backend references, model presence, `max_parallel`
- U11–U13: affinity requirements, resident shared groups (D5), C11 warning
- U14–U15: deterministic byte-identical rendering against golden fixtures
- plus `--print-port`/`--print-plan`/`--print-addresses` and `--exclude-address`

Golden files are byte-sensitive: regenerate through the renderer with
`tests/unit/fixtures/llm-gateway/env`, never by hand.

Integration checks (P1/P2 on real boxes): the spec's T1–T6 — health, model
list, chat through each deployment, session pin observed across requests,
pinned-cap `429`, failover with a box stopped.

## Rollout

| Phase | Scope | Exit |
|-------|-------|------|
| P0 | inventory the boxes (`/v1/models`, `/running`, live `ttl`, the engine's session cap, `apiKeys`, the mesh address, the box's model ids) and fill `gateway.yml` | renderer clean except reviewed C11 warnings |
| P1 | renderer + task + compose on the gateway host; the two-box group; one agent repointed | T1–T6 pass |
| P2 | the third box as `best_effort` failover; all agents + Hermes migrated; affinity coverage recorded | two agents land on different boxes and stay sticky |
| P3 | Prometheus targets for llama-swap `/metrics` and gateway `/metrics`, Grafana panels | decide whether caps/weights or the engine's session cap need tuning |

## Risks

- **Model eviction** (C11): a single-box model on a shared box evicts the
  resident group model; the renderer warns, the operator accepts it explicitly.
- **Cap mismatch**: a `max_parallel` higher than the engine's real parallelism
  turns a queue into a reload storm; P0 must observe the live values.
- **Missing interface**: a NetBird/libvirt address that is down fails the
  container; the task refuses to start and offers
  `GATEWAY_ALLOW_MISSING_ADDRESSES=true` for a deliberate temporary skip.
- **No database**: no per-agent keys/admin UI; the master key is shared and
  `deployment_affinity` must stay off (C6).
- **One gateway**: it is a single point of routing, not of serving — the
  break-glass path keeps the boxes usable if it is down.

## Verification (this repo)

```bash
shellcheck tasks/setup-llm-gateway.sh
uv run ruff check tasks/render-llm-gateway-config.py tests/unit/test_llm_gateway_render.py
yamllint -d relaxed templates/llm-gateway/docker-compose.yml gateway.yml.example \
  machine-config-inference.yml.example models.yml.example
./tests/lint.sh
uv run pytest tests/unit/test_llm_gateway_render.py
```
