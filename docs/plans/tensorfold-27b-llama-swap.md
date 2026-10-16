# Plan: TensorFold Qwen3.8-27B on DGX Spark via llama-swap

**Research:** `docs/research/2026-10-15-qwen38-27b-dgx-spark-tensorfold.md` (authoritative; upstream clone verified at `/tmp/tensorfold-27b`)
**Builds on:** the Flash Next integration (this repo: `tasks/setup-tensorfold.sh`, `templates/tensorfold/`, `tasks/merge-model-entry.py`, `sync_models/` — just merged to `develop`)

> **Post-review decision (2026-10-16):** the catalog entry is named
> **`qwen3.8-27b-tf`**, not `qwen3.8-27b` — that name is already taken by the
> llama.cpp GGUF entry shipped in `models.yml.default` (same model, different
> runtime). Both runtimes coexist in llama-swap; replace `qwen3.8-27b` with
> `qwen3.8-27b-tf` everywhere below where it denotes the TensorFold entry.

## Decisions (this plan)

1. **Sibling script, not a `--model` profile — `tasks/setup-tensorfold-27b.sh`.**
   Repo convention is one task script per service/recipe (AUTOMATIONS.md and
   `machine-config.yml.example` are keyed per script), and the two recipes
   already diverge on their writable-state surface (Flash Next:
   `STATE_DIR`/`LOG_DIR` under `/srv`; 27B: all lock files and the prepared
   marker live under `KERNEL_CACHE`), the prepared-marker location, the port,
   the disk budget, and the health timeout. A shared script would grow a
   second env-var/flag surface and couple the working Flash Next install to
   changes made for 27B. The duplication (~250 lines) is the price for zero
   risk to the existing install and convention conformance. If a *third*
   TensorFold recipe shows up, refactor shared logic into `lib/tensorfold.sh`
   then — not now (YAGNI).
2. **Port: 8889** (`TENSORFOLD_27B_PORT`, default `8889`). Flash Next holds
   8888 via `/srv/tensorfold/.env`; both recipes default to 8888 upstream.
   `start.sh` fails loudly if the port is taken, but we don't rely on that.
3. **Checkpoint revision pinning: accept drift.** The 27B recipe has no
   `MODEL_REVISION` lever and its `prepare.sh` hardcodes
   `hf download "$repo" --cache-dir ...` — pinning would require patching the
   upstream checkout, which breaks the re-pin/converge re-run semantics
   (fetch + checkout of the recipe pin would discard the patch). The recipe
   pins the engine (TensorFold v0.6.0 `c464617`, patches hash
   `fb91a0019fdc`, image `tensorfold-qwen38-27b:v0.6.0`); the checkpoint
   tracks the latest revision of `Vontra/Qwen3.8-27B-MLX-4bit` and
   `z-lab/Qwen3.8-27B-DFlash2`. Documented as a known risk in the
   AUTOMATIONS entry (research §6.1). The recipe-repo pin
   (`c11ff138871cf43d12898d79dbfa4dc952d17ca4`) covers scripts/patches/image,
   not weights.
4. **Memory coexistence: document, don't engineer.** Both models at
   defaults do not fit in 128 GB (Flash Next ~103 GiB + 27B ~97 GiB with the
   auto KV pool). The documented usage is llama-swap's one-model-at-a-time
   swap. Co-loading only with explicitly reduced settings on at least one
   side *and* `TENSORFOLD_MEMORY_RESERVE_GIB=4` on both (research §4.6).
   Documented in the plan summary + AUTOMATIONS entry; no code.

## Design

### `tasks/setup-tensorfold-27b.sh` (new, modeled on `tasks/setup-tensorfold.sh`)

Workflow (all steps idempotent / converge on re-run):

1. **Pre-flight:** Docker running, CDI GPU spec (`nvidia.com/gpu=all`),
   DGX Spark detection, ~60 GB free disk under `HF_CACHE_DIR` (only while
   the checkpoints are missing; upstream `MIN_FREE_GB=25` +
   `IMAGE_FREE_GB=35` + margin), `hf` CLI, llama-swap installed
   (`/srv/llama-swap` + `systemctl status llama-swap`).
2. **Clone upstream** into `/srv/tensorfold-27b`, pinned to
   `https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-TensorFold` @
   **`c11ff138871cf43d12898d79dbfa4dc952d17ca4`**. Re-run: `git fetch` +
   `git checkout <pin>`.
3. **Write `/srv/tensorfold-27b/.env`** from `templates/tensorfold-27b/serve.env`
   (see below).
4. **Prepare:** run `/srv/tensorfold-27b/scripts/prepare.sh` with
   `HF_CACHE="$HF_CACHE_DIR" KERNEL_CACHE="$KERNEL_CACHE_DIR"` (prebuilt
   image `ghcr.io/miaai-lab/qwen3.8-27b-dgx-spark-tensorfold:v0.6.0-fb91a0019fdc`
   or local build + ~19 GB checkpoints + verify — idempotent upstream;
   marker at `$KERNEL_CACHE/.prepared`).
5. **Catalog entry:** render `templates/tensorfold-27b/models-entry.yml`,
   merge `qwen3.8-27b` into `models.yml` via `tasks/merge-model-entry.py`
   (additive; entry replaced if the rendered template changed; seed from
   `models.yml.default` if `models.yml` is missing — same as Flash Next).
6. **Sync:** `tasks/sync-models.py` (merge into llama-swap `config.yaml`,
   restart only on change, poll `/health`).
7. **Smoke test** through llama-swap: `POST http://localhost:9292/v1/chat/completions`
   with `model: qwen3.8-27b`, `max_tokens: 32`,
   `chat_template_kwargs: {enable_thinking: false}` (same shape as the Flash
   Next smoke test), bounded by `TENSORFOLD_27B_HEALTH_TIMEOUT + 60`.
8. **Flags:** `--port`, `--health-timeout`, `--dir`, `--hf-cache`,
   `--kernel-cache`, `--force` (stop model via upstream `stop.sh` + force
   re-merge), `--skip-smoke`, `--check`, `--help` (kept complete).

**Env vars (defaults):**

| Var | Default | Meaning |
|---|---|---|
| `TENSORFOLD_27B_PORT` | `8889` | TensorFold host-network port; llama-swap proxies to it |
| `TENSORFOLD_27B_HEALTH_TIMEOUT` | `600` | llama-swap wait for first load (19 GB + one-time kernel compile) |
| `PROJECT_DIR` | `/srv/tensorfold-27b` | recipe checkout + service dir |
| `HF_CACHE_DIR` | `~/.cache/huggingface` | host HF cache |
| `KERNEL_CACHE_DIR` | `/srv/tensorfold-27b/.cache` | kernel cache + lock files + prepared marker |
| `LLAMA_SWAP_PORT` | `9292` | llama-swap API port |
| `LLAMA_SWAP_DIR` | `/srv/llama-swap` | llama-swap install dir |

**`KERNEL_CACHE_DIR` defaults to `/srv/tensorfold-27b/.cache`, NOT `$HOME`:**
the 27B recipe keeps `.start.lock`, `.prepare.lock`, and `.prepared` under
`KERNEL_CACHE` (unlike Flash Next, which has a separate `STATE_DIR`).
llama-swap runs `cmd` as root with `ProtectHome=read-only`, so a `$HOME`
cache would fail to write the lock at load time. Same reasoning as Flash
Next's `TENSORFOLD_STATE_DIR`.

**No `STATE_DIR`/`LOG_DIR`** for 27B — the recipe has no such concept; logs
are `docker logs` only.

### `templates/tensorfold-27b/serve.env` (new)

Rendered to `/srv/tensorfold-27b/.env` (only `${PORT}` envsubsted):

```
# Managed by kwisatz tasks/setup-tensorfold-27b.sh — re-rendered on every run.
FOREGROUND=1
PORT=${PORT}
HOST=127.0.0.1
# Engine levers (PARALLEL, CONTEXT, YARN_FACTOR, KV_POOL_GB, KV_DTYPE,
# PREFILL_FP8, VISION, DRAFT_ID, TENSORFOLD_*) can be added here;
# see /srv/tensorfold-27b/scripts/config.sh.
```

(`HOST=127.0.0.1` mirrors Flash Next: the API is consumed through
llama-swap, no unauthenticated direct LAN access.)

### `templates/tensorfold-27b/models-entry.yml` (new)

Rendered with `TENSORFOLD_27B_PORT`, `LLAMA_SWAP_PORT`, `HF_CACHE_DIR`,
`KERNEL_CACHE_DIR`, `TENSORFOLD_27B_HEALTH_TIMEOUT`:

```yaml
providers:
  - name: local
    baseUrl: http://localhost:${LLAMA_SWAP_PORT}/v1
    models:
      - name: qwen3.8-27b
        type: local
        env:
          # llama-swap runs cmd as root with ProtectHome=read-only — pin the
          # caches to the invoking user's HF cache (read-only bind) and to
          # the service-writable /srv kernel cache (locks + prepared marker).
          - name: HF_CACHE
            value: ${HF_CACHE_DIR}
          - name: KERNEL_CACHE
            value: ${KERNEL_CACHE_DIR}
        # One-time prep (image + ~19 GB checkpoints). No-op while the
        # upstream prepared marker is present. ${KERNEL_CACHE} resolves from
        # the per-model env (sync-models.py expansion); KERNEL_CACHE is also
        # passed to prepare.sh so the marker lands where the service looks.
        download:
          - >-
            [[ -f ${KERNEL_CACHE}/.prepared ]] ||
            KERNEL_CACHE=${KERNEL_CACHE}
            bash /srv/tensorfold-27b/scripts/prepare.sh
        serve:
          cmd: "bash /srv/tensorfold-27b/start.sh"
        llamaSwap:
          cmdStop: "docker stop -t 30 qwen38-27b-tf"
          unloadTimeout: 60
          proxy: "http://127.0.0.1:${TENSORFOLD_27B_PORT}"   # 8889
          checkEndpoint: "/health"
          healthCheckTimeout: ${TENSORFOLD_27B_HEALTH_TIMEOUT}  # 600
          ttl: 0
          aliases:
            - "Qwen3.8-27B"
            - "qwen3.8-27"   # "qwen3.8" is already an alias of qwen3.8-flash-next
        agent:
          contextWindow: 262144
          maxTokens: 32768
          reasoning: true
          input: [text, image]   # video is available via the raw API only
```

Notes:
- No new `sync_models/` features needed — the existing `llamaSwap`
  pass-through covers everything.
- The 27B `start.sh` mounts the entire `$HF_CACHE` rw (no snapshot handling).
- `cmdStop` is a single command (llama-swap execs it without a shell) —
  stopping the container makes the blocking `start.sh` return.

### `AUTOMATIONS.md` (updated)

New `#### setup-tensorfold-27b.sh` entry next to the Flash Next one:
TensorFold v0.6.0 Python engine (not the Zig engine), prebuilt image
`ghcr.io/miaai-lab/qwen3.8-27b-dgx-spark-tensorfold:v0.6.0-fb91a0019fdc`
(local build fallback), ~60 GB disk, port 8889, **checkpoints not
revision-pinned (latest revision — known risk)**, ~97 GiB resident at the
full auto KV pool / ~20 GiB idle with `KV_POOL_GB=0`, **does not coexist
with Flash Next at defaults — use llama-swap's one-model-at-a-time swap;
co-loading needs reduced settings + `TENSORFOLD_MEMORY_RESERVE_GIB=4` on
both recipes**.

### `machine-config.yml.example` (updated)

New entry after `setup-tensorfold`:

```yaml
  setup-tensorfold-27b:
    enabled: false
    description: Qwen3.8-27B on DGX Spark (TensorFold v0.6.0, via llama-swap)
    env:
      TENSORFOLD_27B_PORT: '8889'
      # TENSORFOLD_27B_HEALTH_TIMEOUT: '600'
    # requires a DGX Spark (GB10) and llama-swap; runs after
    # setup-nvidia-container and setup-llama-swap; ~60 GB free disk
    args: []
```

## Deliverables

1. `tasks/setup-tensorfold-27b.sh` (new, shellcheck-clean, `--help` complete)
2. `templates/tensorfold-27b/models-entry.yml`
3. `templates/tensorfold-27b/serve.env`
4. `AUTOMATIONS.md` — new entry
5. `machine-config.yml.example` — new entry

Untouched: `tasks/setup-tensorfold.sh`, `templates/tensorfold/`,
`tasks/merge-model-entry.py`, `sync_models/`.

## Verification

- `--help` renders; `shellcheck` clean on the new script
- `yamllint` clean; both templates are valid YAML
- Catalog merge is additively idempotent: test `merge-model-entry.py` with a
  temp `models.yml` (entry added once, replaced only on template change)
- `--check` output on a non-Spark box degrades gracefully (pre-flight error)
- No deployment on this box (no GPU)

## Out of scope

- Patching the upstream recipe (no revision pin, no `--model` profile)
- `lib/tensorfold.sh` shared-logic refactor (revisit at a third recipe)
- Simultaneous loading of both models (documented as unsupported at defaults)
- `models.yml.default` entry (machine-specific catalog stays user-local)
- YaRN 1M window, `KV_POOL_GB` tuning, `PREFILL_FP8=0` — upstream levers in
  `/srv/tensorfold-27b/.env`, documented, not wired
