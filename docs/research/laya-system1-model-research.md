# Laya (convaiinnovations/laya) — Research Report

**Date:** 2026-09-28
**Model:** https://huggingface.co/convaiinnovations/laya
**Repo:** https://github.com/NandhaKishorM/laya
**License:** Apache 2.0
**Published:** 2026-09-18 by Convai Innovations

---

## 1. What is Laya?

Laya is a **multilingual, non-autoregressive System 1 decision model**. Instead of generating text, it takes a *state* (text, email, ticket, or JSON) plus *typed questions* and returns typed answers with calibrated probabilities in a single forward pass (~33 ms on a T4). It never writes a sentence, so "there is nothing to parse and nothing to hallucinate."

Three primitives:
- **`choice`** — pick one option from a list (with criteria/descriptions)
- **`score`** — ordinal rating (e.g. not urgent / soon / blocking)
- **`noul`** — yes/no (calibrated probability the answer is "yes")

Training uses **RLCD** (Reinforcement Learning for Calibrated Decisions) against strictly proper scoring rules (log-score, spherical score, ranked probability score). Honest probability reporting is the only way to maximise reward.

## 2. Checkpoints

| Checkpoint | Encoder | Params | Context | Use it for |
|---|---|---|---|---|
| `convaiinnovations/laya` (root) | ModernBERT-large | 421M | 512 | English text, guardrails, email triage |
| `convaiinnovations/laya-multilingual` | mmBERT-base (256k vocab) | 322M | 1024 (up to 8192) | 100+ languages, ~2.2x faster |
| `convaiinnovations/laya-typed-decisions` | ModernBERT-large | 421M | 1024 | the four typed-decisions workflows (0.766 acc) |

The English checkpoint is a ~395M ModernBERT-large backbone + a from-scratch decision head (2 transformer layers, option scorer, act-versus-escalate gate). The multilingual variant uses mmBERT-base.

## 3. Quickstart

```python
pip install laya
from laya import Router
router = Router()  # or Router(preload=True) to load all checkpoints
state = "Hi, we were billed twice for March. Please refund the duplicate today."
questions = {
    "department": {"type": "choice", "instructions": "...",
                   "criteria": {"billing": "invoices, payments, refunds",
                                "technical": "bugs, outages", "other": "everything else"}},
    "urgency": {"type": "score", "instructions": "...", "criteria": ["not urgent", "soon", "blocking"]},
    "churn_risk": {"type": "noul", "instructions": "Does the user threaten to cancel?"},
}
result = router.predict(state, questions)
print(result["answers"]["department"]["choice"])  # -> billing
print(result["answers"]["churn_risk"]["noul"])    # -> 0.92
print(result["routing"]["model"])                 # -> english
```

The `Router` auto-detects script/language in <0.5 ms and dispatches to the right checkpoint. Non-Latin text routes to `laya-multilingual`.

## 4. Benchmarks (shared benchmark, 17,416 questions, one T4)

| Task | English | Multilingual | Router (routed) |
|---|---|---|---|
| MASSIVE intent, English | 0.783 | 0.657 | **0.783** |
| MASSIVE intent, 13 other langs | 0.306 | **0.451** | **0.451** |
| XNLI, English | 0.860 | 0.843 | **0.860** |
| XNLI, 14 other langs | 0.521 | **0.731** | **0.731** |
| Languages usable (>3x random) | 23/51 | 45/51 | **45/51** |
| Latency, 1 question | 39.5 ms | **32.8 ms** | **32.8 ms** |
| Latency, 10 questions batched | 158.6 ms | **72.3 ms** | **72.3 ms** |

Typed-decisions benchmark (2,000 decisions, 4 workflows):
| model | accuracy | Brier | ECE |
|---|---|---|---|
| **laya-typed-decisions** | **0.766** | **0.062** | 0.213 |
| laya | 0.362 | 0.316 | 0.175 |
| laya-multilingual | 0.342 | 0.439 | 0.285 |
| Jev 1.13.0 (published) | 0.727 | 0.148 | 0.144 |

## 5. Honest Limits (important)

- **Base checkpoints are near chance on typed-decisions zero-shot** (0.362 vs 0.318 random, 0.461 majority-class). The 0.766 requires fine-tuning on that benchmark's own training split. Laya is a fast base to specialise, not a zero-shot decision engine.
- **Ordinal `score` questions are the weakest primitive** (SST-5 0.372).
- **`noul` can follow option labels** instead of the state; check on your own data. Workaround: ask as a two-option `choice`.
- **`action.act_probability` carries no usable signal** (reads ~1.0; AUROC 0.30). Gate on `confidence` instead (AUROC 0.77).
- **Ships over-confident.** Refitting one temperature per (type, option count) moves mean ECE 0.466→0.081 (English) and 0.314→0.106 (multilingual). Do this on your own data before trusting probabilities.
- **English-only on root.** Use `laya-multilingual` for non-English.

## 6. Self-Hosting

### 6.1 Official: `laya[serve]` (PyTorch + FastAPI) — the recommended path

```bash
pip install "laya[serve]"        # fastapi + uvicorn + python-multipart
LAYA_DEVICE=cuda LAYA_PRELOAD=1 laya-serve   # binds 0.0.0.0:8000
```

Exposes **`POST /v1/systemone`** on the same wire protocol as TypeSafe's hosted Jev API. The answer payload is schema-identical to Jev (`choice`/`score`/`noul` answers + `{input_tokens, output_tokens}` usage). Existing Jev clients only need `baseUrl` repointed.

Env vars: `LAYA_HOST`, `LAYA_PORT`, `LAYA_DEVICE`, `LAYA_PRELOAD`, `LAYA_MODELS` (comma list), `LAYA_THREADS`, `LAYA_AUTO_TASK`, `LAYA_API_KEY` (enables Bearer-token auth).

### 6.2 ONNX Runtime (CPU, no PyTorch needed)

```bash
pip install "laya[onnx]"
python scripts/export_onnx.py --quantize   # writes INT8 copy for CPU
```

Community pre-exported ONNX bundles exist on HuggingFace:
- `mariojcr/laya-onnx` — English, ModernBERT-large (421M), INT8 CPU (~370ms batch of 4)
- `Mattepiu/laya-onnx`, `receptron/laya-onnx` — fp32 ONNX + config + tokenizer

ONNX inputs: `input_ids`, `attention_mask`, `marker_pos`, `marker_mask`, `qtype`. Outputs: `logits` [B,K], `act_probs` [B,2].

### 6.3 Community HTTP servers

- **`laya-server`** (TypeScript, Docker) — web console + API keys: https://github.com/.../laya-server
- **`sys1`** (Rust, candle) — routing, batching, metrics, playground; CPU/CUDA/Metal
- **`ollaya`** (Rust, Ollama-style) — CLI + daemon, pulls models by name

## 7. GGUF / llama.cpp Path — Analysis

Laya is **not a generative LLM** — it's a BERT encoder + custom decision heads. So it is **not a standard GGUF text model**, and you cannot simply `llama-server -m laya.gguf`.

However, llama.cpp **does** support ModernBERT:
- `conversion/bert.py` registers `BertModel`/`BertForMaskedLM`/`CamembertModel`/`BertForSequenceClassification` and writes GGUF with `MODEL_ARCH.BERT`
- `src/models/modern-bert.cpp` provides the ModernBERT graph in llama.cpp
- `src/models/bert.cpp` provides BERT graph support

**Feasibility of a GGUF Laya build:**
- The **ModernBERT-large encoder** *could* be converted to GGUF via `convert_hf_to_gguf.py` (the BERT conversion path).
- The **decision heads** (2-layer transformer + option scorer + act/escalate gate) are Laya-specific and are **not** part of standard BERT. A pure llama.cpp GGUF would only give you the encoder, not the full decision-making.
- The Rust community servers (`sys1`, `ollaya`) implement the full Laya architecture in candle/Rust — this is the closest thing to a "native GGML" Laya runtime.

**Bottom line:** A GGUF-only path would lose the decision heads. The practical self-hosting options are `laya[serve]` (PyTorch) or the ONNX export. If you want a llama.cpp-native experience, the Rust candle servers are the way to go.

## 8. Recommendation for the User

Given you run **llama-swap + llama.cpp**, the cleanest path is:

1. **For full Laya functionality** (typed decisions, routing, calibration): use `laya[serve]` behind llama-swap as a backend. llama-swap can proxy to `http://localhost:8000` and present it alongside your other models. This is the official, well-supported path.
2. **For CPU-only / no-PyTorch**: export to ONNX INT8 and run with `onnxruntime` (or use a community ONNX bundle).
3. **For a GGUF-native experience**: look at `sys1` or `ollaya` (Rust/candle servers that implement the full Laya architecture). A direct llama.cpp GGUF conversion would only cover the encoder, not the decision heads.

## 9. Fine-tuning

The Kaggle notebook (`notebooks/laya_finetune_typed_decisions_2xT4_kaggle.ipynb`) runs the whole loop: build dataset, RLCD training (GRPO-style policy gradient), fit calibration temperatures, evaluate, push to Hub. Runtime ~4-5 hours on 2xT4 for 4 epochs over ~30k questions. `model.head_checkpointing = True` enables activation checkpointing for the head.

## 10. Other Ecosystem

- **`laya-ts`** — TypeScript/Node.js/browser client (npm `laya-ts`)
- **LangChain/LangGraph** — `LayaRouter`, `LayaGuardrail`, `LayaTriage`, `LayaEvaluator`, `LayaDecision`
- **MCP server** — `laya[mcp]`
- **LlamaIndex selectors** — `laya[llamaindex]`
- **CrewAI routing** — `laya[crewai]`
- **Docker** — official Docker guide at docs
- Community browser builds: `VishalMysore/layaForWebTrained` (ONNX int8 WebAssembly 422MB, int4 WebGPU 278MB)

## Sources

- https://huggingface.co/convaiinnovations/laya
- https://github.com/NandhaKishorM/laya
- https://nandhakishorm.github.io/laya/ (docs + API reference)
- https://pypi.org/project/laya/0.3.19/
- https://github.com/ggml-org/llama.cpp (bert.py, modern-bert.cpp)
- https://dev.to/yanng981/open-source-jev-alternatives-system-one-models-you-can-self-host-i5e
- https://huggingface.co/mariojcr/laya-onnx
- https://medium.com/@visrow/jev-vs-laya-llm-as-a-judge-running-100-inside-your-browser-no-api-costs-2cebcbccac2d
- https://aiweekly.co/alerts/convai-ships-laya-a-421m-modernbert-decision-model-apache-20
- https://flowtivity.ai/blog/laya-open-source-jev-alternative
