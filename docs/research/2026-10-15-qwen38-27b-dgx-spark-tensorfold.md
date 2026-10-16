# Integration Report: Qwen3.8-27B (TensorFold) with llama-swap

**Date:** 2026-10-15
**Author:** denkobot
**Target:** Julian (Captain) — DGX Spark (GB10, 128 GB unified memory)
**Companion report:** `docs/research/2026-10-14-qwen38-tensorfold-llama-swap-integration.md` (Flash Next)

---

## 1. Executive Summary

This report describes how to integrate the **Qwen3.8-27B on DGX Spark (TensorFold)** recipe
([MiaAI-Lab/Qwen3.8-27B-DGX-Spark-TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-TensorFold))
into the existing **llama-swap** workflow established for the sibling Flash Next recipe.

**Key findings:**

1. **The 27B recipe is structurally identical to Flash Next** for integration purposes: same
   lifecycle model (`start.sh` with `FOREGROUND=1` blocking mode, `stop.sh`, `scripts/prepare.sh`
   one-time setup), same container pattern (`docker run -d --gpus all --network host`, fixed port,
   `/health` endpoint), same llama-swap integration shape (catalog entry with `llamaSwap`
   pass-through: `cmd` = upstream `start.sh`, `cmdStop` = `docker stop`, `proxy` to fixed port).
   **No new schema/merge features in `sync_models/` are needed.**

2. **It is a much smaller model.** 27B dense (~15 GB MLX 4-bit checkpoint + ~3.6 GB DFlash2
   drafter, ~19 GiB resident at idle) vs. Flash Next's 125B-A5B MoE (~122 GB checkpoint, ~103 GiB
   at startup). Disk: ~60 GB vs. ~160 GB. First load: seconds-to-minutes vs. ~122 GiB weight load.

3. **It is NOT the same engine.** Flash Next runs TensorFold's **Zig engine** (`tensorfold-native`,
   image `tensorfold-qwen38:zig-db28187`); 27B runs **TensorFold v0.6.0 (c464617) in Python** on
   NVIDIA's PyTorch container (`nvcr.io/nvidia/pytorch:26.07-py3`, image `tensorfold-qwen38-27b:v0.6.0`),
   with five patches (50 images + video, opt-in YaRN 1M window, FP8 KV cache, zero memory reserve,
   pinned KV pool). The two images, kernel caches, containers, and checkpoints are all independent —
   the recipes can coexist on one machine.

4. **Port conflict by default:** both recipes default to port 8888. The kwisatz Flash Next install
   already pins 8888 via `/srv/tensorfold/.env`. **The 27B must get a different port (recommend 8889)**
   via its own `.env`.

5. **Memory coexistence:** both models loaded at their defaults does **not** fit in 128 GB
   (Flash Next ~103 GiB + 27B ~97 GiB with the auto KV pool). llama-swap's one-model-at-a-time
   swap model is the correct usage; loading both simultaneously is only possible with reduced
   settings (Section 6).

**Integration design (recommended):** extend `tasks/setup-tensorfold-spark-qwen38-flash.sh` with a model profile
(`--model flash-next|27b`), or add a sibling `tasks/setup-tensorfold-spark-qwen38-27b.sh` reusing the same
pattern; either way the new surface area is one template pair
(`templates/tensorfold-spark-qwen38-27b/{models-entry.yml,serve.env}`) plus one recipe checkout at
`/srv/tensorfold-27b` (pinned to commit `c11ff138871cf43d12898d79dbfa4dc952d17ca4`).

---

## 2. Component Analysis

### 2.1 Recipe repository (`Qwen3.8-27B-DGX-Spark-TensorFold`)

**Recipe commit:** `c11ff138871cf43d12898d79dbfa4dc952d17ca4` (2026-10-01, main).
**Patches hash** (labels the prebuilt image tag): `fb91a0019fdc`.

**Repository layout** (same shape as Flash Next):

```
start.sh, stop.sh   setup (first run) + start / stop the server
scripts/            prepare.sh (image + checkpoints), config.sh (all settings),
                    banner.sh, publish-image.sh (push prebuilt image to GHCR)
patches/            0001 many-images-video, 0002 yarn, 0003 kv-fp8,
                    0004 memory-reserve, 0005 kv-pool
```

### 2.2 Model checkpoints

| | Value |
|---|---|
| Target model | `Vontra/Qwen3.8-27B-MLX-4bit` (MLX affine 4-bit, groups of 64, **~15 GB**) |
| Drafter | `z-lab/Qwen3.8-27B-DFlash2` (DFlash2 speculative decoding, **~3.6 GB**; `DRAFT_ID=` serves without drafts) |
| Revision pin | **None** — `scripts/config.sh` has no `MODEL_REVISION`; `prepare.sh` does `hf download $repo` (latest revision). ⚠ Unlike Flash Next, the checkpoint is not revision-pinned. |
| Alternative | `MODEL_ID=nvidia/Qwen3.8-27B-NVFP4 VISION=0` (slower decode, no vision) |
| API model id | `Qwen3.8-27B` |
| Disk | ~19 GB checkpoints + ~25–35 GB image ≈ **~60 GB** (`MIN_FREE_GB=25`, `IMAGE_FREE_GB=35`) |

### 2.3 Docker image

| | Value |
|---|---|
| Local image | `tensorfold-qwen38-27b:v0.6.0` |
| Prebuilt | `ghcr.io/miaai-lab/qwen3.8-27b-dgx-spark-tensorfold:v0.6.0-fb91a0019fdc` (pulled first if reachable; falls back to local build) |
| Base | `nvcr.io/nvidia/pytorch:26.07-py3` (requires NVIDIA NGC pull, same as Flash Next) |
| Engine | TensorFold v0.6.0 (`git+https://github.com/ashhart/TensorFold.git@v0.6.0`) + `transformers==5.17.0` + `av`, with the 5 patches baked in |

The image is rebuilt when the patches hash changes (`prepare.sh --rebuild` to force). The
`tensorfold --version` and an import smoke test run at the end of prepare.

### 2.4 Serve command and config levers

`start.sh` builds:

```
docker run -d --name qwen38-27b-tf --gpus all --ipc=host --network host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -e HF_HUB_OFFLINE=1 -e TENSORFOLD_<...>… \
  -v $HF_CACHE:/root/.cache/huggingface -v $KERNEL_CACHE:/cache \
  tensorfold-qwen38-27b:v0.6.0 \
  tensorfold serve Vontra/Qwen3.8-27B-MLX-4bit --host 0.0.0.0 --port 8888 \
    --name Qwen3.8-27B --parallel 8 --context 262144 \
    --temperature 1.0 --top-p 0.95 --top-k 20 --prefill-fp8 --vision --thinking
```

**Config levers** (env or `.env` next to `start.sh`; `scripts/config.sh`):

| Variable | Default | Meaning |
|---|---|---|
| `PARALLEL` | `8` | concurrent streams |
| `CONTEXT` | `262144` | window per stream (× `YARN_FACTOR`) |
| `YARN_FACTOR` | unset | opt-in YaRN rope scaling; `4` → 1,048,576-token window (patches 0002) |
| `KV_POOL_GB` | `auto` | pinned attention cache at startup; `auto` = free GiB − ~31, max 78; `0` = grow on demand (patches 0005) |
| `KV_DTYPE` | `fp8` | KV cache precision: `fp8` (32 KiB/token) or `bf16` (64 KiB/token) (patches 0003) |
| `PREFILL_FP8` | `1` | FP8 prompt activations (+35–40% prefill, small precision cost) |
| `VISION` / `VISION_URLS` | `1` / `0` | image+video input (MLX checkpoint only) / also fetch `https://` URLs |
| `TENSORFOLD_MAX_IMAGES` / `TENSORFOLD_IMAGE_TOKENS` / `TENSORFOLD_VIDEO_TOKENS` | `50` / `16384` / `16384` | media limits (patches 0001) |
| `TEMPERATURE` / `TOP_P` / `TOP_K` | `1.0` / `0.95` / `20` | Qwen thinking-mode sampling |
| `THINKING` | `1` | open a think block by default |
| `DRAFT_ID` | `z-lab/Qwen3.8-27B-DFlash2` | drafter; empty → `--no-drafts` |
| `TENSORFOLD_MEMORY_RESERVE_GIB` | `0` | GiB kept free (patches 0004 allow 0; raise if sharing the box) |
| `SERVED_NAME`, `PORT`, `HOST`, `CONTAINER_NAME`, `IMAGE` | `Qwen3.8-27B`, `8888`, `0.0.0.0`, `qwen38-27b-tf`, `tensorfold-qwen38-27b:v0.6.0` | |
| `HF_CACHE`, `KERNEL_CACHE` | `~/.cache/huggingface`, `~/.cache/tensorfold-qwen38-27b` | |

Notes vs. Flash Next: there is **no `TENSORFOLD_CUDA_KERNELS`** env (kernels are PyTorch
extensions + Triton, cached under `$KERNEL_CACHE/{torch_extensions,triton}`), **no `MAX_TOKENS`**
lever (client `max_tokens` is bounded by the window), **no `DRAFTS` toggle** (use `DRAFT_ID=`),
and the **`/health` endpoint** reports busy flag + live token totals.

### 2.5 Memory budget on the 128 GB Spark

| Component | Size |
|---|---|
| Weights + drafter + per-stream buffers (8 streams) | ~19 GiB |
| KV pool (`auto`, full) | up to **78 GiB** (≈2.55M tokens at fp8 32 KiB/token) |
| Resident with full pool | **~97 GiB** (held from the first second, never returned) |
| Idle with `KV_POOL_GB=0` | **~20 GiB** (caches grow on demand; each full 262,144-token stream = 8 GiB fp8) |
| Startup estimate at defaults (README) | ~45 GiB without the pinned pool |

`start.sh` refuses to start the `auto` pool if less than ~40 GiB free; a fixed `KV_POOL_GB` that
doesn't fit is refused with the largest fitting window named.

### 2.6 Lifecycle scripts and blocking behavior

- `./start.sh` — preflight (docker, GPU, disk), runs `scripts/prepare.sh` if the prepared marker
  (`$KERNEL_CACHE/.prepared`) is stale, validates args in a throwaway container, checks port and
  memory, computes the `auto` KV pool, `docker run -d`, then **waits on `/v1/models`** with a
  heartbeat (default `WAIT_TIMEOUT=1800`), runs a smoke test, prints the endpoint and **exits**.
- `./start.sh restart [extra serve args]` — stop, then start (extra `tensorfold serve` flags win
  over defaults).
- `./start.sh` with **`FOREGROUND=1`** (the kwisatz-relevant mode): stays attached via
  `docker logs -f` and exits with the container's exit code — a blocking process for the
  container's lifetime, exactly what llama-swap's `cmd` needs.
- `./stop.sh` — checks `/health` for in-flight requests (warns), `docker stop -t 30` + `docker rm -f`.
- `scripts/prepare.sh` — preflight, pull prebuilt image or build, `hf download` both repos
  (+ `tensorfold pull` verification), `tensorfold info` verify, writes the prepared marker.
  Idempotent; `--rebuild` forces an image rebuild.
- flock-protected (`.start.lock`, `.prepare.lock` under `$KERNEL_CACHE`).

### 2.7 GPU / CDI requirements

`docker run --gpus all` — identical to Flash Next. Requires Docker with the NVIDIA container
toolkit and the CDI spec `nvidia.com/gpu=all` (kwisatz `setup-nvidia-container.sh`). No new
requirement.

---

## 3. Comparison with the Flash Next recipe

| Dimension | Flash Next (integrated 2026-10-14) | 27B (this report) |
|---|---|---|
| Model | Qwen3.8-Flash-Next-125B-A5B (MoE, INT4-AutoRound) | Qwen3.8-27B dense (MLX 4-bit) |
| Checkpoint size / disk | ~122 GB / ~160 GB | ~19 GB / ~60 GB |
| Revision pin | `1464274120d36a4d8fcaa934552334a7d83ce0fd` | **none** (latest revision) |
| Engine | TensorFold Zig (`tensorfold-native`), TF_REF `db281878` | TensorFold v0.6.0 Python (c464617) |
| Base image | `nvcr.io/nvidia/pytorch:26.07-py3` | `nvcr.io/nvidia/pytorch:26.07-py3` (same) |
| Local image | `tensorfold-qwen38:zig-db28187` | `tensorfold-qwen38-27b:v0.6.0` |
| Prebuilt GHCR | `ghcr.io/miaai-lab/qwen38-flash-next-single-dgx-spark-tensorfold` | `ghcr.io/miaai-lab/qwen3.8-27b-dgx-spark-tensorfold` |
| Container name | `qwen38-flash-next-tf` | `qwen38-27b-tf` (no collision) |
| Default port | 8888 | **8888 (conflict — needs 8889)** |
| Default settings | context 262144, parallel 8, KV fp8, vision, MTP drafts | context 262144, parallel 8, KV fp8, vision, **DFlash2 drafts, prefill-fp8, pinned KV pool** |
| Memory at startup | ~103 GiB | ~97 GiB (full pool) / ~20 GiB (`KV_POOL_GB=0`) |
| Vision | 50 images + video, 2 GiB helper workspace | 50 images + 2 videos (video code ported from Flash Next), no separate workspace env |
| Extra features | — | opt-in YaRN 1M window, pinned KV pool (`KV_POOL_GB`), `PREFILL_FP8` |
| Drafts | MTP (`DRAFTS`) | DFlash2 drafter model (`DRAFT_ID`, `--no-drafts`) |
| Patches | engine-specific (Zig) | 5 patches (video, YaRN, KV fp8, reserve 0, KV pool) |
| Kernel cache | `~/.cache/tensorfold-qwen38` | `~/.cache/tensorfold-qwen38-27b` |
| Prepared marker | `$STATE_DIR/prepared` (`~/.local/state/qwen38-flash-next-tf/prepared`) | `$KERNEL_CACHE/.prepared` (`~/.cache/tensorfold-qwen38-27b/.prepared`) |
| `FOREGROUND=1` | yes | yes (same blocking contract) |
| Health endpoint | `/health` | `/health` (also reports `requests_running`, token totals) |
| `docker run` GPU | `--gpus all` | `--gpus all` (same) |
| HF cache mount | snapshot dir (ro) | entire `$HF_CACHE` (rw) |

**Same:** overall lifecycle contract (start/stop/prepare scripts, `FOREGROUND` mode, fixed-port
host-network container, `/health`, `--gpus all`, `.env` settings file, idempotent prepare with a
marker), and therefore the entire kwisatz integration pattern.

**Different:** engine (Python vs. Zig), image, checkpoints, kernel cache, prepared-marker
location, memory profile, port (must differ), and a few levers (YaRN, KV pool, prefill-fp8,
DFlash2 vs. MTP).

---

## 4. Integration Design

### 4.1 Reusable as-is

- **`sync_models/` (sync-models.py):** the `llamaSwap` pass-through (`cmdStop`, `proxy`,
  `checkEndpoint`, `ttl`, `aliases`, `unloadTimeout`) already covers everything 27B
  needs. **No new schema or merge features required.** (Correction 2026-10-16: `healthCheckTimeout` is
  GLOBAL in llama-swap, not a per-model field — the setup script raises the
  top-level value instead.)
- **`tasks/merge-model-entry.py`:** catalog entry merge works unchanged.
- **`tasks/setup-tensorfold-spark-qwen38-flash.sh` structure:** pre-flight (docker, CDI, Spark, disk, hf CLI,
  llama-swap), pinned checkout, `.env` render, `prepare.sh`, catalog merge, `sync-models.py`,
  smoke test — all steps apply identically.
- **Catalog pattern:** `serve.cmd = bash /srv/tensorfold-27b/start.sh` (blocking with
  `FOREGROUND=1` in `.env`), `llamaSwap.cmdStop = docker stop -t 30 qwen38-27b-tf`.

### 4.2 New surface area

1. **Recipe checkout:** `/srv/tensorfold-27b`, pinned to `c11ff138871cf43d12898d79dbfa4dc952d17ca4`.
2. **Port:** 8889 (Flash Next holds 8888). Rendered into `/srv/tensorfold-27b/.env`.
3. **Templates:** `templates/tensorfold-spark-qwen38-27b/models-entry.yml` + `serve.env`.
4. **Disk check:** ~60 GB (vs. 160 GB for Flash Next).
5. **Health timeout:** ~300–600 s is ample (19 GB load + one-time kernel compile), vs. 900 s.
6. **Download marker:** `${KERNEL_CACHE}/.prepared` (different location than Flash Next's
   `STATE_DIR/prepared`).

### 4.3 Task script: extend vs. new (decision for the plan)

**Option A — extend `tasks/setup-tensorfold-spark-qwen38-flash.sh` with `--model flash-next|27b` (default
`flash-next`).** Per-model constants (repo, recipe ref, project dir, port, disk, model name,
container, kernel cache, health timeout) move into a `case` profile; the ~200-line main flow
stays shared. Pros: no duplication, one entry point, easy to add more recipes later. Cons: the
script grows a second config surface; `--check`/`--force` semantics must cover both models.

**Option B — new `tasks/setup-tensorfold-spark-qwen38-27b.sh` + `templates/tensorfold-spark-qwen38-27b/`.** Mirrors the
existing script (~90% identical). Pros: matches the repo's one-task-script-per-service convention,
zero risk to the working Flash Next install. Cons: ~250 duplicated lines; drift risk when the
pattern evolves.

**Option C — refactor shared logic into `lib/tensorfold.sh`** with two thin wrappers. Most
engineering, least duplication.

**Recommendation:** Option A if the plan keeps the script under control; Option B is the
lowest-risk, convention-matching fallback. Both keep the Flash Next install untouched
(`PROJECT_DIR`, port, and catalog entry names differ).

### 4.4 Catalog entry (shape)

`templates/tensorfold-spark-qwen38-27b/models-entry.yml` (rendered with `TENSORFOLD_27B_PORT`,
`LLAMA_SWAP_PORT`, `HF_CACHE_DIR`, `KERNEL_CACHE_27B_DIR`, `TENSORFOLD_27B_HEALTH_TIMEOUT`):

```yaml
providers:
  - name: local
    baseUrl: http://localhost:${LLAMA_SWAP_PORT}/v1
    models:
      - name: qwen3.8-27b
        type: local
        env:
          - name: HF_CACHE
            value: ${HF_CACHE_DIR}
          - name: KERNEL_CACHE
            value: ${KERNEL_CACHE_27B_DIR}   # ~/.cache/tensorfold-qwen38-27b
        # No-op while the upstream prepared marker is present.
        download:
          - "[[ -f ${KERNEL_CACHE_27B_DIR}/.prepared ]] || bash /srv/tensorfold-27b/scripts/prepare.sh"
        serve:
          cmd: "bash /srv/tensorfold-27b/start.sh"
        llamaSwap:
          cmdStop: "docker stop -t 30 qwen38-27b-tf"
          unloadTimeout: 60
          proxy: "http://127.0.0.1:${TENSORFOLD_27B_PORT}"   # 8889
          checkEndpoint: "/health"
          healthCheckTimeout: ${TENSORFOLD_27B_HEALTH_TIMEOUT}  # ~600
          ttl: 0
          aliases:
            - "Qwen3.8-27B"
            - "qwen3.8"
        agent:
          contextWindow: 262144
          maxTokens: 32768
          reasoning: true
          input: [text, image]   # 'video' is not a valid catalog value (text/image only)
```

Notes:
- `env` entries are expanded by `sync_models` and applied to the `cmd` process (llama-swap runs
  it as root with `ProtectHome`, so `HF_CACHE`/`KERNEL_CACHE` must be pinned to the invoking
  user's home — same as the Flash Next entry).
- The 27B `start.sh` mounts the **entire** `$HF_CACHE` (rw), so no per-snapshot mount handling is
  needed in the catalog.
- `agent.input` cannot express video (catalog validates `text`/`image` only); video is available
  through the OpenAI API directly.

### 4.5 serve.env

`templates/tensorfold-spark-qwen38-27b/serve.env` (rendered to `/srv/tensorfold-27b/.env`):

```
# Managed by kwisatz tasks/setup-tensorfold-spark-qwen38-flash.sh — re-rendered on every run.
FOREGROUND=1
PORT=${PORT}     # 8889
# Engine levers (PARALLEL, CONTEXT, YARN_FACTOR, KV_POOL_GB, KV_DTYPE, PREFILL_FP8,
# VISION, DRAFT_ID, TENSORFOLD_*) can be added here; see /srv/tensorfold-27b/scripts/config.sh.
```

### 4.6 Memory coexistence (both models on one 128 GB Spark)

| Scenario | Flash Next | 27B | Fits? |
|---|---|---|---|
| Both at defaults | ~103 GiB | ~97 GiB (auto pool) | **No** (~200 GiB) |
| Flash Next default + 27B `KV_POOL_GB=0` | ~103 GiB | ~20 GiB idle + KV growth | No / marginal (only ~15 GiB free) |
| Flash Next `PARALLEL=2` (~82 GiB) + 27B `KV_POOL_GB=0`, 2 streams at 262k (~36 GiB) | ~82 GiB | ~36 GiB | Yes (~118 GiB), tight |

**Practical answer:** llama-swap's model-swap usage (one model loaded at a time) is the correct
default for this machine. The 27B fits comfortably alone (~97 GiB at full pool, ~20 GiB idle
with `KV_POOL_GB=0`). Co-loading requires explicitly reduced settings on at least one side, and
with `TENSORFOLD_MEMORY_RESERVE_GIB=0` (the 27B recipe default), an overcommit freezes the host —
if co-loading is wanted, raise `TENSORFOLD_MEMORY_RESERVE_GIB` (e.g. 4) **in
`/srv/tensorfold-27b/.env` only**: the Flash Next recipe already keeps 10 GiB, and setting 4
there would lower its floor instead of raising the 27B's.

---

## 5. Setup Procedure (reference, for the plan)

```bash
# 1. (Once) llama-swap + NVIDIA toolkit already in place (Flash Next install).
# 2. Run the (extended) setup task for the 27B profile:
#    - pre-flight: docker, CDI nvidia.com/gpu=all, GB10, ~60 GB disk, hf CLI, llama-swap
#    - clone/checkout https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-TensorFold
#      @ c11ff138 into /srv/tensorfold-27b
#    - render /srv/tensorfold-27b/.env (FOREGROUND=1, PORT=8889)
#    - /srv/tensorfold-27b/scripts/prepare.sh (pull/build image + ~19 GB checkpoints)
#    - merge catalog entry qwen3.8-27b into models.yml
#    - tasks/sync-models.py (merge into llama-swap config, restart only on change)
#    - smoke test through http://localhost:9292/v1 (model: qwen3.8-27b)
```

Runtime:

```bash
curl -s -X POST http://localhost:9292/v1/models/qwen3.8-27b/load     # load
curl -s -X POST http://localhost:9292/v1/models/qwen3.8-27b/unload   # stop container
docker logs -f qwen38-27b-tf                                          # logs
```

---

## 6. Risks and Considerations

1. **No checkpoint revision pin.** `Vontra/Qwen3.8-27B-MLX-4bit` and `z-lab/Qwen3.8-27B-DFlash2`
   download at latest revision; a future upstream change silently swaps weights. The recipe repo
   pin does not cover this. Mitigation upstream: none (no `MODEL_REVISION`). Mitigation in this
   repo: `setup-tensorfold-spark-qwen38-27b.sh` records the SHAs `prepare.sh` resolved in
   `/srv/tensorfold-27b/.checkpoint-revisions` and warns on drift at install and with `--check`
   (detection, not prevention — pin via `hf download --revision` or a recipe change to prevent it).
2. **Port conflict.** Both recipes default to 8888. The 27B must run on a different port (8889)
   via `.env`; `start.sh` dies if the port is taken, so the conflict is loud, not silent.
3. **Memory overcommit.** With `TENSORFOLD_MEMORY_RESERVE_GIB=0` (the recipe default) and the
   `auto` KV pool, the 27B holds ~97 GiB and never gives it back; starting it while Flash Next is
   loaded fails the start (good), but co-loading with reduced settings can exhaust the 128 GB and
   freeze the host. Document "one model at a time" as the default.
4. **First start compiles CUDA kernels** (a few minutes) — cached under
   `~/.cache/tensorfold-qwen38-27b`; set `healthCheckTimeout` accordingly (~600 s).
5. **Stale container after llama-swap restart** (same as Flash Next): if llama-swap dies while
   the container runs, the next load fails until `docker rm -f qwen38-27b-tf`.
6. **YaRN is off by default** (`YARN_FACTOR` unset → 262,144 window). The 1M window shrinks the
   auto KV pool to ~70 GiB and is only worth enabling for long-context use.
7. **`PREFILL_FP8=1` is the default** — +35–40% prefill at a small prompt-precision cost
   (KL 0.04 vs. 0.003); `PREFILL_FP8=0` if quality matters more.
8. **Prebuilt image availability:** `ghcr.io/miaai-lab/qwen3.8-27b-dgx-spark-tensorfold` requires
   a reachable Docker login for that package; otherwise the local build path runs (a few
   minutes). Same behavior as Flash Next.
9. **Disk:** ~60 GB; if the Flash Next install already occupies ~160 GB, the Spark needs ~220 GB
   free total for both recipes — check before preparing the 27B.

---

## 7. Summary

The 27B recipe is the Flash Next integration pattern with a smaller model and a Python engine
instead of the Zig engine. The existing kwisatz machinery (setup task structure, `templates/`,
`merge-model-entry.py`, `sync_models` llamaSwap pass-through) covers 100% of the integration;
the new work is one template pair, one recipe pin, one new port (8889), and the decision of
whether to extend `tasks/setup-tensorfold-spark-qwen38-flash.sh` (Option A) or add a sibling task script (Option B).
Memory-wise, the two models do not coexist at defaults; llama-swap's swap model is the right
fit.
