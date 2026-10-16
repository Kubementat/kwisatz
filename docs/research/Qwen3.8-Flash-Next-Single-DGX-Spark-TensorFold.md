# Report: Qwen3.8 Flash Next on one DGX Spark (TensorFold)

**Repository:** [MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold)
**by MiaAI Lab** (x.com/MiaAI_lab)
**Date researched:** 2026-10-06

---

## 1. What this repository is

This repository provides a **single-command recipe to serve Qwen3.8 Flash Next** from a single NVIDIA DGX Spark (GB10, 128 GB unified memory) through an OpenAI-compatible API. It runs **TensorFold v0.6.1** (`17c73e1`) in NVIDIA's PyTorch container, plus a patch that adds video input, many-image support, copy drafts, SSD read-ahead, and other optimizations.

**Key capability:** 5 concurrent requests at the full 262,144-token context with image and video input.

**Checkpoint:** `Vontra/Qwen3.8-Flash-Next-MLX-4bit-MTP` (MLX 4-bit, group size 32, with the MTP draft head)
**API model id:** `Qwen3.8-Flash-Next`

---

## 2. Repository structure

```
start.sh          set up (first run) and start the server
stop.sh           stop the server
scripts/
  prepare.sh      image + checkpoint download + verify
  config.sh       all settings (defaults + env overrides)
  publish-image.sh  push the image to GHCR
  banner.sh       start.sh's terminal banner
patches/
  0002-flash-next-v061.patch   Flash Next on v0.6.1: video, 50 images, copy drafts, etc.
  languages/0010-flash-next-draft-languages   language draft vocabularies (opt-in)
tools/
  bench.py            smoke benchmark: prefill + decode
  test_copy_draft_rows.py   copy/MTP proposal-row ownership (CPU, needs TF_SRC)
  test_astra_patches.py      first-token-before-draft, MTP absorb, PLE concat
  needle.py           needle-in-a-haystack (~195k-token prompt)
  toolcheck.py        tool call with array parameter check
  visioncheck.py      image input check (drawn shapes)
CREDITS.md      credits and licenses
LICENSE         MIT (with TensorFold's notice for patches)
```

---

## 3. How it works

### `start.sh` — 5-step workflow
1. **Setup:** Runs `scripts/prepare.sh` when not ready (first run, patches changed, different model/image). Compares the prepared state with current settings so later starts skip instantly.
2. **Checks:** Validates arguments with TensorFold's own parser (in a throwaway container), checks the previous server, port, and free memory.
3. **Launch:** Starts `tensorfold serve` with settings from `scripts/config.sh`.
4. **Loading:** Streams the server log; every 15 s reports elapsed time and GPU memory loaded vs. startup estimate.
5. **Smoke test:** One chat completion, then prints `Qwen3.8-Flash-Next is now LIVE! on port 8888`.

`./start.sh restart` checks new arguments before stopping the running server. `FOREGROUND=1` stays attached (for systemd).

### `scripts/prepare.sh` — one-time setup
1. Preflight: Docker, NVIDIA runtime, disk space (~125 GB checkpoint + ~35 GB image).
2. Image: TensorFold v0.6.1 with all `patches/*.patch` applied, plus `transformers` (vision tower) and PyAV (video). On NVIDIA's `nvcr.io/nvidia/pytorch:26.07-py3`. Tries prebuilt image from GHCR first (`ghcr.io/miaai-lab/qwen3.8-flash-next-single-dgx-spark-tensorfold:v0.6.1-<patches hash>`, ~11 GB), else builds locally.
3. Downloads checkpoint to `~/.cache/huggingface` (resumable).
4. Verifies with `tensorfold info`.

### `scripts/config.sh` — configuration
Every setting is overridable via environment, `.env` file, or `tensorfold serve` flags. Defaults:
- `PARALLEL=5` streams, `CONTEXT=262144` tokens each → **1,310,720-token KV pool**
- `KV_DTYPE=int8`, `PLE_ON_SSD=1` (reads 29.8 GiB n-gram tables from SSD)
- `VISION=1` (image/video input on), `MTP_DRAFTS=6`, `MTP_CONFIDENCE=0.60`
- `TEMPERATURE=1.0`, `TOP_P=0.95`, `TOP_K=20` (Qwen's thinking-mode sampling)
- `THINKING=1`, `MAX_TOKENS=32768`
- `TENSORFOLD_MEMORY_RESERVE_GIB=2` (floor; prevents OOM freezes)

---

## 4. Performance (measured on one DGX Spark, v0.6.1)

### Decode, prose
| Concurrent | Aggregate | Per request | TTFB |
|---|---|---|---|
| 1 | 63.6 tok/s | 63.6 tok/s | 66 ms |
| 2 | 85.6 tok/s | 43.8 tok/s | 226 ms |
| 4 | 114.5 tok/s | 29.7 tok/s | 304 ms |

### Decode, code
| Concurrent | Aggregate | Per request | TTFB |
|---|---|---|---|
| 1 | 96.9 tok/s | 96.9 tok/s | 206 ms |
| 2 | 133.9 tok/s | 67.0 tok/s | 210 ms |
| 4 | 166.4 tok/s | 44.8 tok/s | 292 ms |

### Prefill
| Prompt | Tokens | Prefill speed | TTFB |
|---|---|---|---|
| 8k | 8,228 | 2,421 tok/s | 3.40 s |
| 16k | 16,423 | 2,468 tok/s | 6.66 s |
| 32k | 32,805 | 2,462 tok/s | 13.33 s |
| 64k | 65,571 | 2,391 tok/s | 27.43 s |
| 128k | 131,110 | 2,180 tok/s | 60.13 s |

**Key improvements vs. unpatched TensorFold v0.3.6.2:** prefill went from ~1,350–1,490 tok/s to ~2,340–2,480 tok/s (3k–50k-token prompts), single-request decode up ~4%, every reply byte-identical. A new question on a shared 31k-token system prompt: 0.18 s vs. 14 s.

---

## 5. Memory budget (default 5×262,144 int8)

| Component | GiB |
|---|---|
| Model weights (n-gram tables on SSD) | 75.2 |
| Vision tower | 0.84 |
| Stream caches (5×4.49) | 22.5 |
| Fixed buffers | 4.0 |
| **Startup estimate** | **102.5** |

The vision tower's scratch (~0.8 GiB) is borrowed only while encoding and returned immediately. `TENSORFOLD_MEMORY_RESERVE_GIB=2` is the floor; without it TensorFold would reserve ~12 GiB and refuse 5×262k.

Other configs that fit the ~128 GB budget:
- `PARALLEL=4` int8 → 97.7 GiB (more headroom)
- `PARALLEL=6 KV_DTYPE=int4` → 97.6 GiB
- `PARALLEL=3 KV_DTYPE=bf16` → 102.0 GiB (full-precision KV)
- `PARALLEL=8 KV_DTYPE=int4 CONTEXT=250000` → ~103 GiB (tight)

---

## 6. The patch (`patches/0002-flash-next-v061.patch`)

This single patch folds the earlier v0.5.0 series into one diff for TensorFold v0.6.1. It adds:
- **Video input** and up to **50 images** sharing 16,384 tokens (on top of TensorFold's own Flash Next vision)
- **Copy drafts** with compact MTP rows (uses TensorFold's `CopyIndex` from Qwen3.5 27B engine)
- **`TENSORFOLD_PREFILL_ROWS`** override (port of TensorFold #40 by MovieMaker93)
- **SSD read-ahead** around the n-gram table
- **First token before the next draft**
- **No unused MTP logits** while prompts absorb
- **96 MiB request bodies**

The language patch (`patches/languages/0010`) is opt-in (`DRAFT_LANGUAGE=zh|ja`), adding language draft vocabularies for the MTP head. Token lists come from Javier (jvr0x)'s vLLM recipe.

**Outputs are unchanged** — every speed patch changes speed only; drafts are verified against the model's own keyed samples. Verified via reply hashes (sampled and greedy, prompts up to 149k tokens) against unpatched TensorFold, with vision on/off, and a ~195k-token needle-in-a-haystack test.

---

## 7. Images and video

The model's own vision tower (27 layers, 0.84 GiB) turns images and video frames into tokens with Qwen's 3-D rotary positions.

| | Images | Videos |
|---|---|---|
| Formats | JPEG, PNG, WebP | MP4, WebM, MOV, MKV |
| Per request | up to 50, 10 MB each, 64 MB total | up to 2, 64 MB each, 96 MB total, ~1 hour |
| Tokens | up to 16,384 total (≤4,096/image; "low": 256) | 2 fps (≤256 frames), ≤16,384 tokens |

Data URLs accepted by default; `VISION_URLS=1` also fetches public `https://` URLs. `VISION=0` serves text only.

---

## 8. Requirements

- **DGX Spark** (GB10, 128 GB unified memory) with nothing else large on the GPU (~103 GiB needed at startup)
- **Docker** with NVIDIA container runtime, user in `docker` group
- **~160 GB free disk**: ~125 GB checkpoint + ~35 GB image
- Optional: `hf` CLI on host (faster, resumable), Hugging Face token

---

## 9. Quick start

```bash
git clone https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold.git
cd Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
./start.sh
```

Then:
```bash
curl -s http://<spark-address>:8888/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen3.8-Flash-Next",
  "messages": [{"role": "user", "content": "Write a Python fibonacci function."}],
  "max_tokens": 1000
}'
```

Any OpenAI client: `base_url = "http://<spark-address>:8888/v1"`, model `Qwen3.8-Flash-Next`.

---

## 10. License

MIT (see LICENSE, which carries TensorFold's MIT notice for the patches). Model weights under Qwen Community License 1.0. The image also contains Hugging Face `transformers` (Apache 2.0) and PyAV (BSD) with FFmpeg (LGPL).

---

## 11. Credits

- **Qwen3.8 Flash Next** by Qwen (Qwen Community License 1.0)
- **Vontra** — MLX 4-bit checkpoint with preserved MTP draft head
- **TensorFold** by Ash Hart and contributors (Apache-2.0/MIT)
- **MovieMaker93** — prompt-chunk change (TensorFold #40)
- **Javier (jvr0x)** — language draft vocabularies
- Built with Claude Code and Cursor