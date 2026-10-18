# Benchmark: Qwen3.8 Flash Next (TensorFold, single DGX Spark)

Date: 2026-10-16. Measured on `192.168.178.104` ("dgx"), model `qwen3.8-flash-next`,
served by TensorFold's Zig engine (`tensorfold-qwen38:zig-db28187`, engine commit
`db28187`) behind llama-swap on port 9292 (`localhost:8888` inside the container, bound
to 127.0.0.1 only). Context window 262144. Recipe:
<https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold>.

Everything below was measured over the llama-swap OpenAI endpoint, i.e. exactly the
path a client (including this pi session) uses.

## Setup of the measurement

* Prompts were generated as random unique word sequences, so **no prefix cache hits**
  for the prefill sweep (`cached=0` confirmed in the engine log for every sample).
* Sampling `temperature=0`, `chat_template_kwargs.enable_thinking=false` for the
  prefill sweep, so no reasoning tokens contaminate the counts.
* Wall-clock timing client-side (`requests`, no proxying tricks). The engine's own
  `tensorfold.tokens_per_second` / `prefill_seconds` fields agreed with the client-side
  numbers to <1%, which is a good sanity check that llama-swap's proxy adds nothing
  measurable.
* The box was idle apart from the benchmark itself (load average ~1.0, GPU util 0%
  between runs). While the benchmark ran, the operator session was blocked, so no
  other inference competed for the GPU.

Headline numbers:

| | |
|---|---|
| Prompt processing, sustained (cold prompt) | **≈ 2100 tok/s** |
| Prompt processing, 128k-token prompt | 2041 tok/s (66.1 s) |
| Prompt processing, prefix-cache hit | ≈ 76 000 tok/s effective (8115/8122 cached) |
| Decode, real prose | **≈ 50–80 tok/s** (mean ≈ 57 tok/s) |
| Decode, engine step rate | 21–26 forward passes/s, 2–4 accepted tokens each |
| Decode at 32k context | ≈ 41–44 tok/s |
| Decode at 128k context | ≈ 35 tok/s |
| Aggregate decode, 4 concurrent streams | ≈ 87 tok/s (≈ 22 tok/s per stream) |

## Prompt processing (prefill)

Cold prompt, `max_tokens=1`, so wall time ≈ prefill time + ~0.3 s request overhead.
`prompt_tokens` read back from the response's `usage`.

| prompt tokens | wall | tokens/s | marginal tokens/s |
|---|---|---|---|
| 154 | 0.37 s | 418 | — |
| 548 | 1.00 s | 548 | — |
| 2 126 | 3.33 s | 639 | — |
| 8 477 | 9.03 s | 939 | — |
| 16 878 | 11.74 s | 1 438 | ~3 100 (noisy) |
| 33 758 | 19.78 s | 1 707 | ~2 100 |
| 67 502 | 35.57 s | 1 898 | ~2 140 |
| 134 892 | 66.09 s | 2 041 | ~2 210 |

Interpretation:

* Prefill is **linear from ~16k tokens onward** at ≈ 2 100 tok/s; the whole 128k context
  window costs ~66 s to warm up. There is no cliff at any size tested.
* Below ~2k tokens the numbers are dominated by a **flat ~0.3 s per-request/launch
  overhead**, not by attention cost — 154 tokens in 0.37 s is 418 tok/s but tells you
  nothing about throughput. For short prompts expect TTFT ≈ 0.35–0.9 s, not a throughput
  problem.
* **Prefix caching works and is worth more than the raw prefill rate.** Re-sending the
  identical 8k prompt: 3.13 s → 0.106 s, `cached=8115` of 8122 tokens, i.e. ~76 000 tok/s
  effective. This is why an agent session with a long stable prefix stays responsive; a
  cache miss at 128k is a 60 s+ stall. The engine log shows `prompt cache: … resumed at
  8115` and the cache holds ~8 states (~8 GiB of state, 0 MiB spare) — long-context
  cache reuse is limited by that budget, and concurrent long contexts evict each other
  (`evicted 28` after the sweep).

### TTFT (cold) by prompt size

| prompt tokens | TTFT |
|---|---|
| ~2 k | 0.85–0.91 s |
| ~32 k | 14–15 s |
| ~65 k | 28 s |
| ~130 k | 57–64 s |

## Decode

The TensorFold engine is speculative ("drafts": true, lanes engine), so wall-clock
tokens/s decomposes into *engine step rate × accepted tokens per step*. Both were read
from the engine's own per-request log line (`rounds=N accepted=A/D`), so this is not a
client-side guess.

Realistic prompts (26–31 prompt tokens, 400–1024 generated tokens, greedy/low
temperature, real English/technical prose):

| mode | samples | mean decode rate |
|---|---|---|
| thinking off (`enable_thinking=false`) | 4 | **57 tok/s** (49–80) |
| thinking on (`effort=medium`, as used by pi) | 6 | **56 tok/s** (49–72) |

Engine internals behind those numbers: 180–490 rounds per request, i.e. **21–26
forward passes/s**, each accepting 1.9–3.8 tokens (draft acceptance rate ≈ 70–95%).
Reasoning mode is *not* faster per token than non-reasoning mode, and for a given
prompt it is not slower either — the tokens are just cheaper to draft.

Longer prompts cost decode throughput:

| prompt tokens | decode rate |
|---|---|
| ~0.5 k – 8 k | 57–58 tok/s |
| ~32 k | 41–44 tok/s |
| ~130 k | ~35 tok/s |

Caveat worth stating: on **low-entropy or self-repeating text the same engine reports
150–300 tok/s** (one 128k request: 512 tokens in 88 rounds = 5.8 tokens/round). Those
numbers are an artefact of the draft model trivially predicting the repetition and are
not representative of real generation — do not quote them.

### Concurrency

Same node, 1k-token prompts, 128 output tokens each, thinking off:

| concurrent streams | aggregate tok/s | per stream | TTFT |
|---|---|---|---|
| 1 | 40 | 40 | 0.54 s |
| 2 | 64 | 32–36 | 0.4–1.0 s |
| 4 | **87** | 22–24 | 1.8 s |

Batching gives ~2.2× aggregate throughput at 4 streams — i.e. decode is not yet
memory-bandwidth-bound at one stream, but it saturates quickly. For comparison, a
single stream at 128-token generations measured 40 tok/s because the fixed per-request
overhead and low acceptance dominate; steady-state single-stream is the ~57 tok/s above.

## How to reproduce

The endpoint is the llama-swap OpenAI API; the key is the `dgx` provider apiKey in
`~/.pi/agent/models.json` (do not hardcode it into a repo file).

```bash
KEY=$(python3 -c 'import json;print(json.load(open("/home/USER/.pi/agent/models.json"))["providers"]["dgx"]["apiKey"])')
curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next","messages":[{"role":"user","content":"…"}],
       "max_tokens":512,"temperature":0,
       "chat_template_kwargs":{"enable_thinking":false}}' \
  http://192.168.178.104:9292/v1/chat/completions | jq '.usage, .tensorfold'
```

* `usage` gives prompt/completion/cached token counts; the response also carries a
  `tensorfold` block with `tokens_per_second`, `prefill_seconds`, `time_to_first_token`,
  `engine`, `drafts` — cross-check client-side timings against it.
* Engine-side ground truth (rounds, draft acceptance, prompt-cache state):

  ```bash
  ssh 192.168.178.104 'docker logs --since 10m qwen38-flash-next-tf 2>&1 | grep "done chatcmpl"'
  # → prompt=… cached=… thinking=… tokens=… rounds=N accepted=A/D
  ```

* For a cold prefill sweep, build prompts from random words and read `usage.prompt_tokens`
  back (`max_tokens=1`); a fixed ~1.05 tokens/word calibration is good to ~1%.

## Notes / limitations

* Absolute throughput is sensitive to the accepted-token rate, which depends on the text.
  Quote 50–80 tok/s for prose, ~2 100 tok/s for cold prefill.
* The llama-swap proxy overhead is not separately isolated, but engine-reported timings
  match client-side timings within <1%, so it is negligible.
* Only `qwen3.8-flash-next` was loaded during the runs; sibling models (27b, 35b, …) were
  unloaded, so no cross-model interference.
* Port 8888 (TensorFold) is bound to 127.0.0.1 on the host on purpose; all measurements
  go through 9292.
