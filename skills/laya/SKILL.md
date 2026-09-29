---
name: laya
description: How to understand and use Laya (convaiinnovations/laya), a self-hosted non-autoregressive "System 1" decision model, through this repo's systemd deployment. Covers the choice/score/noul question primitives, the /v1/systemone wire protocol, which checkpoint to route to, calibration and other honest limits, and troubleshooting. Use when the user asks to classify/route/triage/score text, wants a fast yes/no or confidence judgment instead of an LLM call, mentions Laya/System 1/Jev-style typed decisions, or asks how to call the locally hosted Laya model.
---

# Laya (System 1 decision model)

Laya is **not a chat/generative LLM**. It is a ~421M ModernBERT-large encoder
plus small decision heads that takes a *state* (some text: an email, ticket,
JSON blob, ...) and a set of *typed questions*, and returns typed answers with
calibrated probabilities in a single forward pass (~33 ms on a T4). It never
writes a sentence — "there is nothing to parse and nothing to hallucinate."
Use it for fast routing/triage/guardrail/classification decisions that would
otherwise burn an LLM call on a yes/no or multiple-choice judgment.

Deployed in this repo by `tasks/setup-laya.sh` (installs `laya[serve]` into a
venv at `/srv/laya/venv` and runs it as the systemd service `laya`, bound to
`LAYA_HOST:LAYA_PORT`, default `0.0.0.0:7771`; see
`docs/research/laya-system1-model-research.md` for the full research this
skill is distilled from). If neither the venv nor the service exist yet, stop
and recommend running `tasks/setup-laya.sh` — this skill is for *using* an
existing install.

## Orient yourself first

```bash
LAYA="${LAYA_URL:-http://localhost:7771}"
sudo systemctl status laya                # service is up?
curl -s "$LAYA/health"                    # {"status":"ok","loaded":[...],"device":"cpu"}
curl -s "$LAYA/docs"                      # Swagger UI (request/response schema)
curl -s "$LAYA/openapi.json"              # machine-readable OpenAPI spec
```

If the service is down: `sudo journalctl -u laya -n 50`. On a machine with a
firewall, the UFW rule `laya-api` (added by `tasks/setup-laya.sh`) allows
inbound TCP on the API port; when the service was installed with
`LAYA_HOST=127.0.0.1` it is local-only — tunnel with SSH instead.

## Calling Laya directly

Laya's API is `POST /v1/systemone` — **not** an OpenAI chat-completions
shape. `GET /health` (no auth) reports `{"status":"ok","loaded":[<checkpoint
currently in memory>],"device":"cpu|cuda"}`; `GET /docs` is the Swagger UI
and `GET /openapi.json` the spec (note: the spec defines **no request
schema** for `/v1/systemone` — verify request shape against the live server).

**Auth**: `tasks/setup-laya.sh` always configures a bearer token — `LAYA_API_KEY`
if you set it, otherwise generated (`openssl rand -hex 24`) and stored in
`/srv/laya/.env` (mode 600, loaded by the unit via `EnvironmentFile=`). Every
`/v1/systemone` call must send `Authorization: Bearer <key>` (wrong/missing
→ 401 `invalid or missing bearer token`). `/health` and `/docs` stay open.

```bash
TOKEN=$(grep -Eo '^LAYA_API_KEY=\S+' /srv/laya/.env | cut -d= -f2)
curl -s -X POST $LAYA/v1/systemone \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{...}'
```

**Server-side guardrails** (enforced, not advisory): max **64 questions** per
call, `state` ≤ **50,000 chars**, request body ≤ **2 MB** (413 above that).

The request body may carry an optional `model` field to pick the checkpoint:
`english`, `multilingual`, `typed-decisions`, or `convaiinnovations/laya`
(let the router auto-select; omitting `model` does the same).

## The `/v1/systemone` request

Laya answers **typed questions about one state**, not a conversation. Three
question primitives:

| Type | Meaning | Answer shape |
|---|---|---|
| `choice` | pick one option from `criteria` (a `{name: description}` map) | `{"type":"choice", "choice": "<option-name>", ...}` |
| `score` | ordinal rating from an ordered `criteria` list | `{"type":"score", "score": <float>, "legend": {"0": "<item-0>", ...}, ...}` |
| `noul` | yes/no as a **calibrated probability of "yes"** | `{"type":"noul", "noul": 0.0-1.0, ...}` |

The `...` in each answer carries `probabilities`, `confidence`,
`answer_confidence` and an `action` block (see the full verified response
shape below). For `score`, `score` is a **float on the ordinal axis**, not a
label: map it to the nearest `legend` entry (`round(score)` → label), e.g.
`1.5208` → `2` → `"blocking"`.

```bash
TOKEN=$(grep -Eo '^LAYA_API_KEY=\S+' /srv/laya/.env | cut -d= -f2)
curl -s -X POST "$LAYA/v1/systemone" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "state": "Hi, we were billed twice for March. Please refund the duplicate today.",
    "questions": {
      "department": {
        "type": "choice",
        "instructions": "Which team should handle this ticket?",
        "criteria": {
          "billing": "invoices, payments, refunds",
          "technical": "bugs, outages",
          "other": "everything else"
        }
      },
      "urgency": {
        "type": "score",
        "instructions": "How urgent is this?",
        "criteria": ["not urgent", "soon", "blocking"]
      },
      "churn_risk": {
        "type": "noul",
        "instructions": "Does the user threaten to cancel?"
      }
    }
  }'
```

Response shape (**verified against a live server** — the request above,
`laya[serve]` 0.3.19; `answers` keyed by your question names, plus
`model`/`routing`/`usage` metadata):

```json
{
  "model": "laya-rl-agent",
  "answers": {
    "department": {
      "type": "choice",
      "choice": "billing",
      "probabilities": {"billing": 0.9905, "technical": 0.0044, "other": 0.0051},
      "confidence": 0.9454,
      "answer_confidence": 0.9905,
      "action": {"act_probability": 1.0}
    },
    "urgency": {
      "type": "score",
      "score": 1.5208,
      "legend": {"0": "not urgent", "1": "soon", "2": "blocking"},
      "probabilities": {"0": 0.1036, "1": 0.2721, "2": 0.6244},
      "confidence": 0.1962,
      "answer_confidence": 0.6244,
      "action": {"act_probability": 1.0}
    },
    "churn_risk": {
      "type": "noul",
      "noul": 0.1893,
      "confidence": 0.8107,
      "answer_confidence": 0.8107,
      "action": {"act_probability": 1.0}
    }
  },
  "usage": {"input_tokens": 142, "output_tokens": 0},
  "routing": {
    "model": "english",
    "repo": "convaiinnovations/laya",
    "reason": "English Latin text",
    "detection": {"script": "latin", "language": "en", "is_english": true, "...": "..."}
  }
}
```

Note the **request** body has no schema in the OpenAPI spec (`GET
$LAYA/openapi.json` defines no `requestBody` for `/v1/systemone` and an empty
200 response schema) — the request shape above was verified by a live call,
not by the spec. Before depending on response field names in production
code, re-confirm against `$LAYA/docs` (Swagger) or `$LAYA/openapi.json`,
especially across `laya[serve]` upgrades.

One HTTP call can carry **multiple questions** about the same `state` — batch
your questions instead of firing one request per question; batching is also
markedly faster (10 questions batched: ~72–159 ms vs. ~33–40 ms × 10 serial).
Inference runs on a **single worker thread** — one forward pass at a time;
concurrent requests queue, they don't parallelize.

## Checkpoint routing — pick the right model

| Checkpoint | Params | Context | Use for |
|---|---|---|---|
| `laya` (English root) | 421M ModernBERT-large | 512 | English-only text |
| `laya-multilingual` | 322M mmBERT-base | 1024 (up to 8192) | 100+ languages, non-English/non-Latin script, ~2.2x faster |
| `laya-typed-decisions` | 421M ModernBERT-large | 1024 | fine-tuned specifically for typed-decision workflows (0.766 acc vs 0.362 for the base checkpoint) |

By default `laya-serve` auto-routes by detected script/language (`<0.5ms`
detection) between `laya`/`laya-multilingual` when both are loaded. Set
`LAYA_MODELS` (comma list) at setup time to control which checkpoints are
loaded; `LAYA_PRELOAD=1` (this repo's default) loads all of them up front
instead of lazily on first use.

## Honest limits — read before trusting the output

- **Base checkpoints (`laya`, `laya-multilingual`) are near chance on
  zero-shot typed decisions** (0.362 acc vs. 0.318 random baseline). The
  0.766 accuracy figure requires `laya-typed-decisions` (or your own
  fine-tune) — treat the base checkpoints as a fast encoder to specialize,
  not a general zero-shot decision engine.
- **`score` (ordinal) is the weakest primitive** (SST-5 accuracy 0.372) —
  prefer `choice` or `noul` when the distinction matters.
- **`noul` can key off the option *label* text instead of the state.**
  Verify on your own data; if it misbehaves, rephrase as a two-option
  `choice` instead.
- **`action.act_probability` in the response carries no usable signal**
  (reads ~1.0 regardless, AUROC 0.30). Gate decisions on `confidence`
  instead (AUROC 0.77), never on `act_probability`.
- **Ships over-confident.** Raw probabilities are poorly calibrated (mean
  ECE ~0.31–0.47). If you need trustworthy probabilities (not just a
  ranking), fit one temperature per `(type, option count)` on your own
  labeled data before trusting them as-is.
- **English-only on the root `laya` checkpoint** — route non-English text to
  `laya-multilingual` (done automatically by the router when both are
  loaded).

## Troubleshooting

- **Service won't come up**: `sudo journalctl -u laya -n 50`. First start
  downloads checkpoints from Hugging Face and preloads them
  (`LAYA_PRELOAD=1`) — startup can take minutes on CPU; the setup script's
  health gate waits up to `LAYA_HEALTH_TIMEOUT` (default 300s) for `/health`
  (which also reports `loaded` checkpoints and `device`).
- **First request after a restart is slow / times out**: normal — the
  checkpoints are being loaded; retry with a longer client timeout.
  `curl $LAYA/health` shows which checkpoints are `loaded`.
- **401 on `/v1/systemone`**: missing or wrong bearer token — read it from
  `/srv/laya/.env` (`LAYA_API_KEY=` line); it is stable across re-runs of
  `tasks/setup-laya.sh` (never rotated).
- **413 on `/v1/systemone`**: request body over the 2 MB cap — trim `state`
  (hard limit 50,000 chars) or questions (max 64 per call).
- **404 on `/v1/systemone`**: you likely hit the wrong host/port — the API
  lives directly on the service's bind address (default
  `http://<host>:7771/v1/systemone`); check the unit's
  `Environment=LAYA_PORT=...` in `/etc/systemd/system/laya.service`.
- **422 on `/v1/systemone`** (FastAPI validation error with `detail`):
  invalid request body — the request shape was verified by a live call, not
  by the spec (the OpenAPI spec has no `requestBody` schema) — check
  `$LAYA/docs` for the authoritative schema on your install.
- **GPU not being used**: `LAYA_DEVICE` is fixed at setup time
  (auto-detected via `nvidia-smi` by `tasks/setup-laya.sh`) — check the
  `Environment=LAYA_DEVICE=...` line in `/etc/systemd/system/laya.service`,
  and re-run `tasks/setup-laya.sh` with `LAYA_DEVICE=cuda` if it guessed
  wrong.

## Links

- `tasks/setup-laya.sh` — install/upgrade the venv + systemd service
  (`--check`, `--force`, `LAYA_DIR`/`LAYA_VERSION`/`LAYA_PORT`/`LAYA_HOST`/
  `LAYA_DEVICE`/`LAYA_API_KEY`)
- `/srv/laya/.env` — bearer token (`LAYA_API_KEY=`, mode 600), auto-generated
  on first setup, never rotated on re-runs
- `templates/laya/laya.service` — the systemd unit template, rendered to
  `/etc/systemd/system/laya.service` after setup (loads the token via
  `EnvironmentFile=`)
- `/srv/laya/start-laya.sh` — convenience script to run `laya-serve`
  manually in the foreground
- `docs/research/laya-system1-model-research.md` — full research this skill
  is distilled from (checkpoints, benchmarks, GGUF feasibility analysis,
  fine-tuning notes)
- https://huggingface.co/convaiinnovations/laya
- https://nandhakishorm.github.io/laya/ (upstream docs + API reference)
