> **SUPERSEDED** by `docs/plans/tensorfold-llama-swap-integration.md` (operator decision 2026-10-14:
> no standalone stack — the model runs through llama-swap).

# Plan: `setup-tensorfold-spark-qwen38-flash.sh` — Qwen3.8 Flash Next on one DGX Spark

**Date:** 2026-10-06
**Research:** `docs/research/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold.md`
**Upstream recipe:** https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold

## Goal

A repo-conventional task script that deploys **Qwen3.8 Flash Next** (via
TensorFold v0.6.1 + MiaAI-Lab patches) as a Docker stack on a DGX Spark
(GB10, 128 GB unified memory), OpenAI-compatible API on port 8888.

## Design

- **Service name:** `tensorfold` → `tasks/setup-tensorfold-spark-qwen38-flash.sh`,
  `templates/tensorfold-spark-qwen38-flash/`, project dir `/srv/tensorfold`
- **Pattern:** follow `tasks/setup-vllm.sh` (closest analog: Docker LLM server,
  `.env` + `docker-compose.yml.tmpl` rendered via `envsubst`, converge-by-default
  re-run policy, `wait_for_healthy`, `--check`/`--force`/`--help`)
- **Image:** pinned `ghcr.io/miaai-lab/qwen3.8-flash-next-single-dgx-spark-tensorfold`
  tag — the exact tag (contains the patches hash) must be read from the upstream
  `scripts/prepare.sh` / `scripts/publish-image.sh` and pinned as a
  `TENSORFOLD_DEFAULT_TAG` constant (override: `--image` / `TENSORFOLD_IMAGE`).
  No local-build path in v1 (the prebuilt image is ~11 GB; local build needs the
  full patch pipeline) — print a pointer to the upstream repo instead.
- **Checkpoint:** `Vontra/Qwen3.8-Flash-Next-MLX-4bit-MTP` (~125 GB) downloaded
  on the host with `hf download` into the HF cache dir
  (`HF_CACHE_DIR`, default `~/.cache/huggingface`), bind-mounted into the
  container. Script pre-checks free disk (~160 GB total) and skips the download
  when already present.
- **Serve command / config levers:** derive the exact `tensorfold serve`
  flags (or env vars) from the upstream `scripts/config.sh` + `start.sh`.
  Expose as env/flags with the research defaults:
  `PARALLEL=5`, `CONTEXT=262144`, `KV_DTYPE=int8`, `PLE_ON_SSD=1`, `VISION=1`,
  `MTP_DRAFTS=6`, `MTP_CONFIDENCE=0.60`, `THINKING=1`, `MAX_TOKENS=32768`,
  `TEMPERATURE=1.0`, `TOP_P=0.95`, `TOP_K=20`, `TENSORFOLD_MEMORY_RESERVE_GIB=2`
  Port: `TENSORFOLD_PORT` (default 8888). Served model id: `Qwen3.8-Flash-Next`.
- **Health:** compose healthcheck + script-level poll against the server
  (verify the health endpoint from the upstream repo — likely `/v1/models` or a
  `/health` route), then one smoke chat completion (as upstream `start.sh` does).
  Bounded timeout via `TENSORFOLD_HEALTH_TIMEOUT` (default generous: 900s —
  125 GB weight load from SSD).
- **Pre-flight (NVIDIA/DGX Spark only):**
  - Docker + daemon running, `envsubst` present
  - `nvidia-ctk cdi list` contains `nvidia.com/gpu=all` (else: run
    `setup-nvidia-container.sh` first) — GPU requested via CDI device, same as vLLM
  - DGX Spark (compute capability 12.1) detection: hard-require (the recipe is
    Spark-sized), warn on other GPUs
  - Free disk check (~160 GB) before checkpoint download
  - Port conflict check (foreign listener on `TENSORFOLD_PORT`)
- **Secrets:** none expected (no auth); HF token optional for gated checkpoints
  (`HF_TOKEN` in `.env`, mode 600, never in compose).
- **Idempotency / converge:** reuse-first `.env` values (incl. `HF_TOKEN`),
  re-render templates, `docker compose up -d` reconciles, `wait_for_healthy`,
  converge-hash divergence warning like vLLM.
- **No reverse proxy:** direct LAN exposure on `TENSORFOLD_PORT` (same decision
  as vLLM, 2026-09-01) + ufw guidance in the summary.

## Deliverables

1. `tasks/setup-tensorfold-spark-qwen38-flash.sh` (shellcheck-clean, `--help` complete)
2. `templates/tensorfold-spark-qwen38-flash/docker-compose.yml.tmpl` + `env.template`
3. `AUTOMATIONS.md` entry
4. `machine-config.yml.example` entry (`setup-tensorfold`, enabled: false, env: `TENSORFOLD_PORT`)
5. Lint: `shellcheck` (script), `yamllint` (yml) — all pass
6. No live deployment on this machine (dev box, no Spark) — write + lint only.

## Verification

- `bash tasks/setup-tensorfold-spark-qwen38-flash.sh --help` renders
- `shellcheck tasks/setup-tensorfold-spark-qwen38-flash.sh` clean
- `yamllint` on example config clean
- Template renders valid YAML for the default case (dry-run render test)

## Out of scope (v1)

- Local image build (patches pipeline) — pointer only
- Traefik integration
- Non-Spark / multi-GPU topologies
- `DRAFT_LANGUAGE` opt-in patch
