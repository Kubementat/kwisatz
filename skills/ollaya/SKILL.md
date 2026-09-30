---
name: ollaya
description: How to use the Ollaya decision-model server deployed by this repo (tasks/setup-ollaya.sh) through its `ollaya` CLI and HTTP API. Covers locating the service and API key, running typed choice/score/noul decisions (CLI, /v1/systemone, /api/decide), pulling/listing/creating models, presets, reading and thresholding answers, error codes and troubleshooting. Use when the user asks to classify, route, triage, moderate or score text/JSON quickly and cheaply, mentions Ollaya, `ollaya run`, decision models, or the port 11435 API, or wants to manage Ollaya models.
---

# Ollaya (decision model runtime)

Ollaya is "Ollama for decision models". A *decision model* reads a **state**
(text, email, ticket, any JSON) plus **typed questions** and returns calibrated
answers in one forward pass (~10 ms on GPU, a few hundred ms on CPU). It never
generates text, so there is nothing to parse and nothing to hallucinate. Use it
for routing, triage, guardrails and yes/no gates; keep open-ended reasoning in
text. It is **not** an OpenAI/Ollama chat API (`/api/generate`, `/api/chat`,
`/api/embed` return 404).

Deployed here by `tasks/setup-ollaya.sh`: binary `/usr/local/bin/ollaya`,
systemd unit `ollaya`, system user `ollaya`, models in `/srv/ollaya/models`,
API key in `/srv/ollaya/.env`, default bind `0.0.0.0:11435`. Research:
`docs/research/ollaya-research.md`. If the binary or service is missing, stop
and recommend `tasks/setup-ollaya.sh` — this skill is for *using* an install.
(The related `laya` skill covers the older standalone Python Laya server on
port 7771; Ollaya serves the same `laya` model on 11435.)

## 1. Orient yourself

```bash
OLLAYA_URL="${OLLAYA_URL:-http://127.0.0.1:11435}"
systemctl status ollaya --no-pager          # up?
curl -s "$OLLAYA_URL/"                      # "Ollaya is running" (never needs auth)
ollaya --version
sudo journalctl -u ollaya -n 50             # logs
```

**Auth.** The setup script always sets `OLLAYA_API_KEY`. Everything except
`GET /` and `HEAD /` needs `Authorization: Bearer <key>` (missing/wrong -> 401
`UNAUTHORIZED`). The key file is root-only (mode 600):

```bash
export OLLAYA_API_KEY="$(sudo sed -n 's/^OLLAYA_API_KEY=//p' /srv/ollaya/.env)"
AUTH=(-H "Authorization: Bearer $OLLAYA_API_KEY")
curl -s "${AUTH[@]}" "$OLLAYA_URL/api/version"
```

Never print the key into logs, commits or chat unless the user asks. The
`ollaya` CLI reads `OLLAYA_API_KEY` and `OLLAYA_HOST` from the environment, so
exporting them makes every CLI command talk to the authenticated service:

```bash
export OLLAYA_HOST=127.0.0.1:11435      # or <server>:11435 for a remote host
export OLLAYA_API_KEY=...               # as above
```

Without `OLLAYA_HOST`, the CLI targets `127.0.0.1:11435` and — if nothing
answers — starts its *own* background daemon with a different model store
(`~/.ollaya/models`). If `ollaya list` looks empty, check these variables
first. Remote hosts: the daemon has no TLS; use an SSH tunnel or a reverse
proxy. Bound to `127.0.0.1` the server also rejects unusual `Host` headers.

## 2. Pick a model (pull first — nothing auto-pulls over HTTP)

```bash
ollaya list                 # local models        (GET /api/tags)
ollaya ps                   # loaded in memory    (GET /api/ps)
ollaya pull laya            # download            (POST /api/pull)
ollaya show laya            # details             (POST /api/show)
ollaya rm <model>  |  ollaya cp <src> <dst>  |  ollaya stop <model>
```

`ollaya run` pulls a missing model; the HTTP API never does (404
`MODEL_NOT_FOUND ... try pulling it first`).

| Model | Use it for | Speed (5 questions) |
|---|---|---|
| `laya` (router -> `laya:en` / `laya:multilingual`) | Default. English + 100+ languages, CPU-friendly | ~10 ms GPU, 0.2–0.4 s CPU |
| `winnow:e4b` | Best accuracy (0.722 typed-decisions), ~8 GB, wants NVIDIA GPU >= 10 GB | ~90 ms GPU |
| `kev`, `decider`, `decision` | Larger Qwen-based decoders (`kev:9b` = winnow accuracy) | 0.2–0.5 s GPU |
| `decider:2b-vision` | Questions about an image (`--image` / `images`) | ~0.2 s GPU |
| `nli`, `gliclass` | Zero-shot yes/no / many options | ~20 ms GPU |
| `qwen3guard` | Safety guard, **built-in questions only** (send no `questions`) | ~40 ms GPU |
| `von` | Long states (8k tokens) | ~25 ms GPU |

No NVIDIA GPU -> stay with `laya`. Names are `[host/][namespace/]model[:tag]`,
case-insensitive; `laya` == `laya:latest`. Browse: https://ollaya.dev/search.
Precision tags: `laya:en-fp32`, `laya:en-fp16`.

## 3. Ask typed questions

Three question types, keyed by an id you choose (descriptive ids help: if
`instructions` is omitted the model reads the id):

```json
{
  "team": {"type": "choice", "instructions": "Which team handles `ticket`?",
           "criteria": {"billing": "invoices, refunds", "engineering": "bugs, outages", "other": "anything else"}},
  "urgency": {"type": "score", "instructions": "How urgent is `ticket`?",
              "criteria": ["can wait", "this week", "today", "right now"]},
  "wants_refund": {"type": "noul", "instructions": "Does the customer ask for their money back?"}
}
```

- **choice**: 2–255 options, `criteria` = object label->description (or array of labels); mutually exclusive, include a catch-all `other`. `laya:en` fits ~125 options (`TOO_MANY_OPTIONS` otherwise).
- **score**: 2–10 ordered levels, lowest first, `criteria` = array of level descriptions; answer is the expected level (can fall between levels).
- **noul**: one true/false statement, `criteria` optional (`{"true": ..., "false": ...}`).
- 1–256 questions per request; `state` = string, object or array (<= 65,536 tokens; body <= 8 MiB). Name the state field in `instructions` when `state` is an object.
- Passing `questions` **replaces** a model's embedded questions entirely.

### CLI

```bash
ollaya run laya --preset triage --format json "I was charged twice, refund it today or I cancel."
ollaya run laya --questions questions.json --format json "$TEXT"
ollaya run laya --questions '{"angry":{"type":"noul"}}' --format json "$TEXT"
echo '{"subject":"...","body":"..."}' | ollaya run laya --preset email --format json
ollaya run decider:2b-vision --image chart.png --questions q.json --format json "describe"
```

`--format json` prints the full response (use it in scripts). Without it the
CLI prints a bar chart. Presets: `triage` (intent, is_urgent, frustration,
refund_requested, churn_risk; state field `message`), `email` (`body`),
`guard` (jailbreak, prompt_injection, ...; `prompt`), `moderation` (`post`),
`router` (`request`), `agent` (action run/ask/block, risk; `request` +
`command`). Pass the state as a plain string or an object with that field.
Run `ollaya run --help` for the flags of the installed version.

### HTTP: TypeSafe-compatible `/v1/systemone`

```bash
curl -s "$OLLAYA_URL/v1/systemone" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{
  "model": "laya",
  "state": {"subject": "Invoice", "message": "Can I get an invoice for last month?"},
  "questions": {
    "intent": {"type": "choice", "instructions": "What does the customer want?",
               "criteria": {"invoice": "needs an invoice", "refund": "wants money back", "other": "anything else"}},
    "billing": {"type": "noul", "instructions": "Is this about billing?"}
  }}'
```

```json
{"model":"laya:en","answers":{
  "intent":{"type":"choice","choice":"invoice","confidence":0.8995,"probabilities":{"invoice":0.933,"refund":0.021,"other":0.046}},
  "billing":{"type":"noul","noul":0.9641}},
 "usage":{"input_tokens":71,"output_tokens":0}}
```

`/v1/decisions` is an alias; `GET /v1/models` lists local models. The official
TypeSafe SDK works by setting `TYPESAFE_BASE_URL=http://host:11435` and its API
key to the Ollaya key. Prefer `/v1/*` when you want a wire format that will not change.

### HTTP: native `/api/decide`

Same body as `/v1/systemone`, plus `keep_alive`, `images` (base64 PNG, vision
model), `extras: ["laya"]` (adds `laya.confidence` and `laya.act_probability`
per answer). Response adds `routing` (`route`, `model`, `reason` for routers),
`state_truncated` (state was cut to fit the context — `/v1/*` returns 422
`STATE_TRUNCATED` instead), `done_reason`, and nanosecond durations
(`total_duration`, `load_duration`, `eval_duration`). No streaming
(`stream: true` -> 422).

Load / unload a model without deciding (no `state`):

```bash
curl -s "$OLLAYA_URL/api/decide" "${AUTH[@]}" -d '{"model":"laya","keep_alive":"30m"}'   # preload
curl -s "$OLLAYA_URL/api/decide" "${AUTH[@]}" -d '{"model":"laya","keep_alive":0}'       # unload
```

`keep_alive`: duration (`"5m"`, `"1h"`), seconds, `0` = unload now, negative =
keep forever; default from `OLLAYA_KEEP_ALIVE` (`5m`). `/v1/*` cannot set it.

## 4. Manage models over HTTP

| Call | Purpose |
|---|---|
| `curl "$OLLAYA_URL/api/tags" "${AUTH[@]}"` | list local models |
| `curl "$OLLAYA_URL/api/ps" "${AUTH[@]}"` | loaded models, VRAM, `expires_at`, device |
| `curl "$OLLAYA_URL/api/pull" "${AUTH[@]}" -d '{"model":"winnow:e4b","stream":false}'` | pull (NDJSON stream by default; resumable, idempotent, joins duplicate pulls) |
| `curl -X DELETE "$OLLAYA_URL/api/delete" "${AUTH[@]}" -d '{"model":"x"}'` | remove |
| `curl "$OLLAYA_URL/api/copy" "${AUTH[@]}" -d '{"source":"laya","destination":"mine"}'` | copy |
| `curl "$OLLAYA_URL/api/show" "${AUTH[@]}" -d '{"model":"laya"}'` | details, embedded questions |

A stream that ends without a `{"status":"success"}` line was cut off = failure.

### Custom model with baked-in questions

```
# Modelfile
FROM laya
QUESTIONS ./triage.json
PARAMETER precision fp32
```

```bash
ollaya create triage -f Modelfile
ollaya run triage --format json "some ticket text"     # no --questions needed
```

Over HTTP: `POST /api/create` with `model`, `from`, `questions`, optional
`parameters`, `license`, `description`. Creation never pulls the base model.

## 5. Reading answers and acting on them

| `type` | Fields |
|---|---|
| `choice` | `choice`, `confidence` (0–1), `probabilities` per option |
| `score` | `score` (expected level), `confidence`, `legend`, `probabilities` |
| `noul` | `noul` = probability the statement is true |

Rules of thumb (tune per model on real examples; thresholds do not transfer
between models): `choice` act at `confidence` >= 0.6, else treat the top two as
candidates or ask a human; `noul` >= 0.8 = yes, <= 0.2 = no, in between escalate;
`score` compare against your threshold and look at `confidence`. Report which
model answered (`model` in the response, e.g. `laya:en`) and the probability
behind each action so a person can audit it. fp16 (GPU) can differ from fp32
(CPU) on near-ties.

## 6. Agents: MCP and bundled skill

`claude mcp add ollaya -- ollaya mcp` exposes tools `decide`, `list_models`,
`show_model`, `pull_model` to MCP clients (export `OLLAYA_HOST` /
`OLLAYA_API_KEY` for the authenticated service). Upstream also ships a
`ollaya-decisions` skill under `/usr/local/share/ollaya/skills`.

## 7. Errors and troubleshooting

Error body: `{"error": "...", "code": "...", "detail": [...]}`; unknown codes -> fall back to the HTTP status.

| Status / code | Meaning -> action |
|---|---|
| 401 `UNAUTHORIZED` | Missing/wrong key -> re-read `/srv/ollaya/.env` |
| 403 `FORBIDDEN` | Browser `Origin` not allowed (`OLLAYA_ORIGINS`) or bad `Host` on a loopback bind |
| 404 `MODEL_NOT_FOUND` | `ollaya pull <model>` first |
| 409 `OPERATION_IN_PROGRESS` | Pull/create of that name running -> retry after it ends |
| 422 `INVALID_REQUEST` / `TOO_MANY_OPTIONS` / `INPUT_TOO_LONG` / `STATE_TRUNCATED` | Fix the request (`detail[].loc` names the field); don't retry unchanged |
| 503 `QUEUE_FULL` | Overloaded -> retry after `Retry-After` |
| 500 `MODEL_LOAD_FAILED` | Out of memory / corrupt files -> `journalctl -u ollaya`, lower `OLLAYA_MAX_LOADED_MODELS` |
| 502 `REGISTRY_ERROR` / `DIGEST_MISMATCH` | Registry/network problem -> retry the pull |

Other checks: `ollaya list` empty -> wrong `OLLAYA_HOST` (section 1). Slow first
call -> model loading (`load_duration`); preload with `keep_alive`. GPU unused
-> `ollaya ps` shows `device`; check `nvidia-smi`, that `OLLAYA_DEVICE` is not
`cpu`, and that the CUDA libs exist in `/usr/local/lib/ollaya/`. GGUF models
(`winnow`, `jevk5`) need `libgomp1`. Change service settings by re-running
`tasks/setup-ollaya.sh` with different env vars (`OLLAYA_HOST`,
`OLLAYA_KEEP_ALIVE`, `OLLAYA_MAX_LOADED_MODELS`, `OLLAYA_DEVICE`,
`OLLAYA_PULL_MODELS`), or `sudo systemctl edit ollaya` for other `OLLAYA_*`
variables (`OLLAYA_MAX_QUEUE`, `OLLAYA_LOAD_TIMEOUT`, `OLLAYA_LOG=debug`).
Status check: `tasks/setup-ollaya.sh --check`.
