---
name: laya
description: How to understand and use Laya (convaiinnovations/laya), a self-hosted non-autoregressive "System 1" decision model, through this repo's llama-swap deployment. Covers the choice/score/noul question primitives, the /v1/systemone wire protocol, which checkpoint to route to, calibration and other honest limits, and troubleshooting. Use when the user asks to classify/route/triage/score text, wants a fast yes/no or confidence judgment instead of an LLM call, mentions Laya/System 1/Jev-style typed decisions, or asks how to call the locally hosted Laya model.
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
venv at `/srv/laya/venv`) and wired into llama-swap by hand from the snippet
it generates at `/srv/laya/llama-swap-configuration.yml` (see
`docs/research/laya-system1-model-research.md` for the full research this
skill is distilled from). If neither exists yet, stop and recommend running
`tasks/setup-laya.sh` — this skill is for *using* an existing install.

## Orient yourself first

Laya is spawned **on demand** by llama-swap, like any other backend — there
is no standalone `laya` systemd service to check.

```bash
LS="${LLAMA_SWAP_URL:-http://localhost:9292}"
curl -s "$LS/health"                      # llama-swap itself is up
curl -s "$LS/v1/models" | grep -i laya    # confirm the model ID is registered
```

If `laya` is missing from `/v1/models`, the config snippet was never pasted
into llama-swap's `config.yaml` — check
`/srv/laya/llama-swap-configuration.yml` and `systemctl status llama-swap`.
Find the actual registered model ID (default `laya`, configurable via
`LAYA_MODEL_ID` at setup time) — don't assume it wasn't renamed.

## Reaching Laya through llama-swap

Laya's own API is `POST /v1/systemone` — **not** an OpenAI chat-completions
shape, so it cannot go through llama-swap's `/v1/chat/completions` routing.
Instead use llama-swap's direct upstream passthrough, which still triggers
on-demand spawning/swap-in the same as a normal request:

```bash
POST $LS/upstream/laya/v1/systemone
```

(replace `laya` with your `LAYA_MODEL_ID` if it was changed at setup time).
The first request after idle pays model-load latency; llama-swap's
`checkEndpoint: /docs` gate in the generated snippet only proves the process
is up, not that inference is warm.

## The `/v1/systemone` request

Laya answers **typed questions about one state**, not a conversation. Three
question primitives:

| Type | Meaning | Answer shape |
|---|---|---|
| `choice` | pick one option from `criteria` (a `{name: description}` map) | `{"choice": "<option-name>"}` |
| `score` | ordinal rating from an ordered `criteria` list | `{"score": "<one-of-the-list>"}` |
| `noul` | yes/no as a **calibrated probability of "yes"** | `{"noul": 0.0-1.0}` |

```bash
curl -s -X POST "$LS/upstream/laya/v1/systemone" \
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

Expected response shape (`answers` keyed by your question names, plus
`routing`/`usage` metadata — schema-identical to TypeSafe's hosted Jev API
per the upstream docs):

```json
{
  "answers": {
    "department": {"choice": "billing"},
    "urgency": {"score": "soon"},
    "churn_risk": {"noul": 0.92}
  },
  "routing": {"model": "english"},
  "usage": {"input_tokens": 41, "output_tokens": 3}
}
```

**This exact JSON shape is inferred from the Python client** (`Router.predict(state, questions)`)
and the "wire-protocol-identical-to-Jev" claim in the research doc — the raw
HTTP schema was not independently verified against a running server. Before
depending on field names in production code, confirm against the live
Swagger UI: `curl -s "$LS/upstream/laya/docs"` (or open it in a browser via
an SSH tunnel).

One HTTP call can carry **multiple questions** about the same `state` — batch
your questions instead of firing one request per question; batching is also
markedly faster (10 questions batched: ~72–159 ms vs. ~33–40 ms × 10 serial).

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

- **`laya` missing from `$LS/v1/models`**: the model was never added to
  llama-swap's `config.yaml` — see `/srv/laya/llama-swap-configuration.yml`
  and paste it in, then `sudo systemctl restart llama-swap`.
- **First request after idle is slow / times out**: normal — llama-swap is
  cold-starting the `laya-serve` process. Retry with a longer client timeout;
  `LAYA_PRELOAD=1` only preloads *checkpoints inside* the process, it does
  not keep the process itself warm across llama-swap's idle-unload.
- **404 on `/v1/systemone`**: you likely hit `$LS/v1/systemone` directly
  instead of the upstream passthrough — use
  `$LS/upstream/<model-id>/v1/systemone`.
- **`server_error` / schema mismatch on the request body**: the JSON shape
  above is inferred, not verified against a live server — check
  `$LS/upstream/laya/docs` for the authoritative schema on your install.
- **GPU not being used**: `LAYA_DEVICE` is fixed at setup time (auto-detected
  via `nvidia-smi` by `tasks/setup-laya.sh`) — check the `env:` block in
  `/srv/laya/llama-swap-configuration.yml` / the live `config.yaml`, and
  re-run `tasks/setup-laya.sh` with `LAYA_DEVICE=cuda` if it guessed wrong.

## Links

- `tasks/setup-laya.sh` — install/upgrade the venv (`--check`, `--force`,
  `LAYA_DIR`/`LAYA_VERSION`/`LAYA_MODEL_ID`/`LAYA_DEVICE`)
- `templates/laya/llama-swap-configuration.yml` — the rendered llama-swap
  model block lives at `/srv/laya/llama-swap-configuration.yml` after setup
- `docs/research/laya-system1-model-research.md` — full research this skill
  is distilled from (checkpoints, benchmarks, GGUF feasibility analysis,
  fine-tuning notes)
- https://huggingface.co/convaiinnovations/laya
- https://nandhakishorm.github.io/laya/ (upstream docs + API reference)
