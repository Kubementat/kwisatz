# Private LLM Gateway (LiteLLM)

One private, OpenAI- and Anthropic-compatible endpoint in front of the llama-swap
boxes. Agents (pi, opencode, Claude Code, Hermes, Open WebUI, n8n) use **one base
URL and one key**; the gateway chooses the box that serves each request.

The gateway is [LiteLLM Proxy](https://docs.litellm.ai/docs/proxy/deploy) in one
Docker container on **evobox**, under `/srv/llm-gateway`, on port `4000`. It keeps
model groups, session pins, per-deployment capacity caps, retries and cooldowns.
llama-swap stays the per-box front door; its behaviour does not change.

```
 pi   opencode   Claude Code   Hermes VM   Open WebUI   n8n
  \       |          |            |            |        /
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
```

* [Setup](#setup) · [Routing config](#routing-config-gatewayyml) · [Secrets](#secrets) ·
  [Verification](#verification) · [Agent wiring](#agent-wiring) ·
  [Break-glass](#break-glass) · [Troubleshooting](#troubleshooting)

---

## Setup

```bash
# 1. Copy the routing config and edit it (it is gitignored)
cp gateway.yml.example gateway.yml
$EDITOR gateway.yml

# 2. Render the config and start the gateway
./tasks/setup-llm-gateway.sh

# 3. Verify everything (config, secrets, container, exposure, firewall)
./tasks/setup-llm-gateway.sh --check
```

`gateway.yml` must name the addresses assigned to **this** host, its llama-swap
backends and their model ids. Before the first run:

| Edit | Why |
|------|-----|
| `listen.addresses` | Every address to publish on. Never `0.0.0.0` or `::`. Check with `ip -4 addr` — NetBird is `ip -4 addr show wt0`, libvirt is `virbr0`. |
| `listen.allow_from` | Source CIDRs allowed to reach the port. Never `0.0.0.0/0`. |
| `backends.*.base_url` | `http://<box>:9292/v1`. |
| `backends.*.api_key_env` | Only when that box enables llama-swap `apiKeys`; omit otherwise. |
| `models[].deployments[].model` | The **box's own** llama-swap model id. |
| `max_parallel` | The engine's real parallelism. A shared group must keep the model resident (`ttl: 0`). |

A missing `gateway.yml` is never generated silently: the task copies
`gateway.yml.example` next to your path, prints what to edit, and exits `1`.

Useful flags and overrides:

| Flag / variable | Meaning |
|-----------------|---------|
| `--check` | Read-only report; exit `0` only when every check passes |
| `--render-only` | Validate + render the files, no Docker |
| `--force` | Re-create the container (secrets are never rotated) |
| `--warm` / `GATEWAY_WARM=true` | Warm shared-group models after start (loads weights) |
| `--interactive` | Show diffs and ask before re-creating (needs a TTY) |
| `LLM_GATEWAY_DIR` | Project directory (default `/srv/llm-gateway`) |
| `LLM_GATEWAY_IMAGE` | Pinned image (default `ghcr.io/berriai/litellm:v1.106.6`) |
| `GATEWAY_YML` | Routing config (default `<repo>/gateway.yml`) |
| `WAIT_TIMEOUT` | Health/smoke timeout (default `180`) |
| `GATEWAY_STRICT_BACKENDS` | Fail when a required backend is unreachable |
| `GATEWAY_ALLOW_MISSING_ADDRESSES` | Skip unassigned listen addresses with a warning |
| `GATEWAY_ALLOW_NO_SOURCE_FILTER` | Address binding only, no `DOCKER-USER` rules |

---

## Routing config (`gateway.yml`)

```yaml
version: 1

listen:
  port: 4000
  addresses: [192.168.178.57, 100.64.0.10, 192.168.122.1]
  allow_from: [192.168.178.0/24, 100.64.0.0/10, 192.168.122.0/24]

affinity_ttl_seconds: 7200
request_timeout_seconds: 1200

backends:
  dgx:
    base_url: http://192.168.178.104:9292/v1
    api_key_env: LLAMA_SWAP_KEY_DGX
  evobox:
    base_url: http://192.168.178.57:9292/v1
    api_key_env: LLAMA_SWAP_KEY_EVOBOX
  laptop:
    base_url: http://100.64.0.20:9292/v1
    api_key_env: LLAMA_SWAP_KEY_LAPTOP
    best_effort: true          # order 2 = failover only

models:
  - name: qwen3.8-flash-next    # public name agents use
    aliases: [qwen3.8-flash]
    deployments:
      - backend: dgx
        model: qwen3.8-flash-next          # the box's own id
        id: dgx-qwen3.8-flash-next         # stable model_info.id
        max_parallel: 5                    # = TensorFold PARALLEL
        weight: 5
        order: 1
        resident: true
      - backend: evobox
        model: qwen3.8-flash-next-gufo
        max_parallel: 1                    # = GUFO_SESSIONS
        weight: 1
        resident: true
      - backend: laptop
        model: qwen3.8-flash-next-gufo
        max_parallel: 1
        resident: true
```

| Field | Default | Meaning |
|-------|---------|---------|
| `listen.port` | `4000` | Host and container port. `LLM_GATEWAY_PORT` must match it when set. |
| `listen.addresses` | — | Explicit IPv4 addresses; duplicates, hostnames and wildcards are rejected. |
| `listen.allow_from` | — | IPv4 CIDRs; the default route is rejected. |
| `affinity_ttl_seconds` | `7200` | Idle TTL of a session pin. |
| `request_timeout_seconds` | `1200` | Rendered as `timeout` and `stream_timeout`; must exceed the backend's `healthCheckTimeout` (dgx: 900). |
| `backends.<name>.base_url` | — | OpenAI base URL, no credentials/query/fragment. |
| `backends.<name>.api_key_env` | — | Env var in `.env`; omit when the box has no `apiKeys`. |
| `backends.<name>.best_effort` | `false` | `true` ⇒ deployment defaults to `order: 2` (failover only). |
| `models[].name` | — | Public model id (`[A-Za-z0-9._/-]+`), unique. |
| `models[].aliases` | `[]` | Extra public names, must not collide. |
| `deployments[].id` | `<backend>-<model>` | Stable `model_info.id`, unique. |
| `deployments[].max_parallel` | `1` | Hard per-deployment, per-worker cap. Overflow is an immediate `429`. |
| `deployments[].weight` | `1` | `simple-shuffle` weight for a session's first request. |
| `deployments[].order` | `1` | Lower tiers are tried first; `order > 1` gets no new sessions. |
| `deployments[].resident` | `true` | Operator assertion that the box keeps the model loaded. Required on every deployment of a shared group. |

The renderer validates the whole file and reports **all** errors at once, then
writes nothing. Two warnings do not fail: a backend that appears both in a
shared group and in a single-box model (loading the single-box model evicts the
resident shared model), and `order > 1` with `weight > 1` (weight is ignored at
that tier).

`listen.port` is the single source of truth. The task reads it with
`render-llm-gateway-config.py --print-port`; a conflicting `LLM_GATEWAY_PORT`
is exit `1`, not a silent divergence.

---

## Secrets

`/srv/llm-gateway/.env` is mode `0600`, owner `root`. It is generated once and
reused on every re-run — no secret is rotated, and `--force`/`--interactive`
never rotate either.

```dotenv
LITELLM_MASTER_KEY=sk-...          # generated as sk- + 64 hex characters
LLAMA_SWAP_KEY_DGX=...             # one per backend that requires a key
LLAMA_SWAP_KEY_EVOBOX=...
LLAMA_SWAP_KEY_LAPTOP=...
```

* The rendered `config.yaml` contains only `os.environ/NAME`; a secret value is
  never written into it.
* Every `api_key_env` referenced by `gateway.yml` must exist and be non-empty,
  or the task fails before rendering and lists every missing name.
* Unknown keys already in `.env` are preserved.
* **Rotating an upstream key:** edit the line in `.env`, then re-run the task
  (`config.yaml` references the name, not the value, so only the container
  needs to pick up the new environment: the task re-creates it when `.env`
  changed). Rotating `LITELLM_MASTER_KEY` invalidates every agent's key —
  update the clients afterwards.
* The key is never printed. Retrieve it when wiring an agent with:
  `sudo sed -n 's/^LITELLM_MASTER_KEY=//p' /srv/llm-gateway/.env`

---

## Session affinity

LiteLLM pins a session to one deployment for `affinity_ttl_seconds`, so turns
2..N reuse that box's prefix cache. Affinity needs a recognized session id from
the client:

| Client | Header |
|--------|--------|
| opencode | `x-session-id` / `x-parent-session-id` |
| Claude Code | `x-claude-code-session-id` |
| Codex | `session-id` / `thread-id` |
| curl / tests | `x-litellm-session-id` (or any `x-<vendor>-session-id`) |
| pi, Open WebUI, n8n, Hermes | none documented — each request is a new session |

Vendor-style session ids must be at least 8 characters (`[A-Za-z0-9_-]`); a
shorter value is ignored. A client with no session header still works — it just
loses prefix-cache locality. `deployment_affinity` (pinning by caller) is
deliberately **not** enabled: every agent shares one master key, so it would pin
all headerless clients to a single box. Per-agent virtual keys need a database
(a future feature, not v1).

**Pinned session at capacity:** `max_parallel_requests` is a hard cap and a pin
narrows the candidates to one deployment. A second concurrent turn on a 1-slot
box gets an immediate `429`; it does not yield to a peer (LiteLLM issue
[#45868](https://github.com/BerriAI/litellm/issues/45868)). The client must
retry, or raise the Strix cap (`GUFO_SESSIONS=2`) if memory allows. A **new**
session that hits a full box is retried/failed over to a peer.

---

## Exposure

Two controls, both required:

1. **Address binding.** `compose.ports.yml` publishes `<address>:<port>:<port>`
   for each `listen.addresses` entry. There is no `0.0.0.0` and no `::`; an
   unassigned address fails pre-flight (Docker would fail to bind anyway).
2. **Source filtering in `DOCKER-USER`.** Docker publishes ports through its own
   `nat`/`filter` rules, so **UFW cannot filter them** — a `ufw allow from … to
   any port 4000` rule would create a false sense of security. The generated
   `firewall.sh` builds the chain `KWISATZ-LLM-GATEWAY`:

   ```
   ESTABLISHED,RELATED                     -> RETURN
   -s <allow_from CIDR> -p tcp --dport 4000 -> RETURN   (one per CIDR)
   -p tcp --dport 4000                      -> DROP
   everything else                          -> RETURN   (other containers untouched)
   ```

   A single jump is inserted at the **head** of `DOCKER-USER`, and
   `llm-gateway-firewall.service` (oneshot, `After/Requires/PartOf=docker.service`,
   `RemainAfterExit=yes`) re-applies it after boot or a Docker restart. No UFW
   rule is added for port 4000; UFW stays authoritative for every host-network
   service.

`GATEWAY_ALLOW_NO_SOURCE_FILTER=true` downgrades the chain to a loud warning and
relies on address binding only — use it for a laptop or a deliberate teardown,
not on a shared host.

---

## Verification

`./tasks/setup-llm-gateway.sh --check` prints a labelled `PASS`/`FAIL`/`WARN`
line per check and exits `0` only when everything passes:

1. `gateway.yml` parses and validates (warnings shown)
2. the secret file is mode `600` owned by `root`, and every referenced env key is present and non-empty
3. rendered `config.yaml`, `compose.ports.yml` and `firewall.sh` match a fresh render
4. container `llm-gateway` is running and healthy
5. `/health/liveliness` and authenticated `/v1/models` succeed and list every
   public model
6. each non-`best_effort` backend answers `/health` or `/v1/models`
7. every listen address is bound; an address whose interface is down is a
   `WARN` when `GATEWAY_ALLOW_MISSING_ADDRESSES=true` and a `FAIL` otherwise;
   no `0.0.0.0`/`::`
8. `KWISATZ-LLM-GATEWAY` has the expected allow/drop rules and exactly one
   `DOCKER-USER` jump
9. `llm-gateway-firewall.service` is enabled and active

It never sends a completion, so it never loads a model.

Manual probes:

```bash
KEY="$(sudo sed -n 's/^LITELLM_MASTER_KEY=//p' /srv/llm-gateway/.env)"
G=http://192.168.178.57:4000

curl -s -o /dev/null -w '%{http_code}\n' "$G/v1/models"                    # 401
curl -s -H "Authorization: Bearer $KEY" "$G/v1/models" | jq -r '.data[].id' # public names

# Stickiness: five turns, same x-litellm-model-id every time
for i in 1 2 3 4 5; do
  curl -s -D - -o /dev/null "$G/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -H 'x-litellm-session-id: t3-fixed' \
    -d '{"model":"qwen3.8-flash-next","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' \
    | grep -i '^x-litellm-model-id'
done

# Exposure: only the configured addresses, never a wildcard
ss -ltnp | grep ':4000'
sudo iptables -S KWISATZ-LLM-GATEWAY
```

---

## Agent wiring

`sync-models.py` already writes pi/opencode provider configs from `models.yml`.
Add one gateway provider (the key is a secret; `models.yml` is gitignored):

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

```bash
./tasks/sync-models.py --agents-only
```

Keep the existing `local`/`dgx` provider entries for break-glass until the
gateway is trusted, then remove them.

**Claude Code** (optional; LiteLLM translates `/v1/messages` to the
OpenAI-compatible upstream — point it at the gateway root, no `/v1`):

```bash
export ANTHROPIC_BASE_URL=http://192.168.178.57:4000
export ANTHROPIC_AUTH_TOKEN=sk-<LITELLM_MASTER_KEY>
export ANTHROPIC_MODEL=qwen3.8-flash-next
```

**Hermes VM:** use the libvirt bridge address, never the LAN:

```
HERMES_LLM_BASE_URL=http://192.168.122.1:4000/v1
HERMES_LLM_MODEL=qwen3.8-flash-next
HERMES_LLM_API_KEY=<LITELLM_MASTER_KEY>
```

`setup-hermes.sh` auto-adds the endpoint to the VM's egress allowlist when the
host is an IPv4 gateway; verify the rendered `hermes-egress.nwfilter.xml`
contains the `192.168.122.1:4000` accept rule before the private `drop` rules.

---

## Break-glass

llama-swap stays untouched. If the gateway is down, point an agent at a box
directly — no config regeneration is needed:

```bash
curl http://<box>:9292/v1/chat/completions \
  -H "Authorization: Bearer <that box's llama-swap key>" \
  -H 'Content-Type: application/json' \
  -d '{"model":"<box model id>","messages":[{"role":"user","content":"hi"}]}'
```

Stop the gateway (manual, not part of a normal task run):

```bash
cd /srv/llm-gateway && sudo docker compose \
  -f docker-compose.yml -f compose.ports.yml down
```

---

## Operations

* **Converge semantics.** Re-running re-renders everything. `config.yaml` changed
  → `docker compose restart llm-gateway` (it is a bind mount, so `up -d` alone
  would keep the old config). `docker-compose.yml`, `compose.ports.yml`, `.env`
  or the image changed → `up -d --force-recreate llm-gateway` (env vars and port
  bindings are fixed at creation). Nothing changed → the container is left
  alone, and the run reports “converged, no change”. There is no `down` and
  never a `down -v`.
* **Pins live in the single proxy worker's memory** (no Redis). A restart or
  re-create drops every pin; each active session re-pins on its next turn and
  pays one cold prefill. This is deliberate for v1.
* **One worker.** `--num_workers 1` is explicit: caps and pins are per worker,
  so a second worker would double every cap and split the pin cache.
* **No background health checks.** A LiteLLM health check would issue a
  completion against llama-swap, loading (and possibly swapping) a model.
  Request failures + cooldowns are the signal; `--check` probes only `/health`
  or `/v1/models` on the backend. Never probe the gateway's own `/health` for
  monitoring — only `/health/liveliness` (process liveness, not the
  deployments).
* **Logs:** `cd /srv/llm-gateway && sudo docker compose -f docker-compose.yml -f compose.ports.yml logs -f`.
* **Telemetry/logging:** `LITELLM_TELEMETRY_DISABLED=true` and
  `turn_off_message_logging: true` are always on; there is no database, no
  callback and no admin UI.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `listen address … is not assigned` | NetBird (`wt0`) or libvirt (`virbr0`) is down, or the address is wrong. Start it, fix `gateway.yml`, or set `GATEWAY_ALLOW_MISSING_ADDRESSES=true` to skip it temporarily. |
| `Port 4000 is already in use` | `ss -ltnp` names the holder. Another process owns the port; choose a different port in `gateway.yml` and `LLM_GATEWAY_PORT`. |
| `DOCKER-USER chain was not found` | Docker runs with iptables management disabled. Enable it, or accept address-binding-only with `GATEWAY_ALLOW_NO_SOURCE_FILTER=true`. |
| `api_key_env 'X' is missing or empty` | Add `X=…` to `/srv/llm-gateway/.env` and re-run; the value is never printed. |
| `gateway.yml failed validation` | Run `python3 tasks/render-llm-gateway-config.py --config gateway.yml --print-plan`; every error is reported with its YAML path. |
| `shared group … requires resident: true` | Every deployment of a multi-box model must keep it loaded (`ttl: 0`/matrix). Remove the box or fix its llama-swap `ttl`. |
| Health times out | `sudo docker compose … logs --tail=100`. Usually a bad image, a config typo, or a bind address that vanished after pre-flight. |
| `--check` says config drifted | Someone edited `/srv/llm-gateway/config.yaml` by hand; re-run the task to regenerate it from `gateway.yml`. |
| `429` on a pinned session | Expected at a hard cap (C2). Retry the turn, or raise that deployment's `max_parallel` to match the engine. |
| Same session changes box after a restart | Pins are in memory (no Redis); the next turn re-pins once. |

Monitoring (P3, optional): llama-swap is a systemd service, so the existing
Docker service discovery does not find it — add static Prometheus targets for
each box's `/metrics`. Do not put the gateway master key in `prometheus.yml`;
use a mode-`0600` file reference or skip gateway scraping.
