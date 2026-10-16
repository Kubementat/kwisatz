# Integration Report: Qwen3.8 Flash Next (TensorFold) with llama-swap

**Date:** 2026-10-14
**Author:** denkobot
**Target:** Julian (Captain) — DGX Spark (GB10, 128 GB unified memory)

---

## 1. Executive Summary

This report describes how to integrate the **Qwen3.8 Flash Next on DGX Spark (TensorFold)** project
([MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold))
with your existing **llama-swap** setup from the [kwisatz](https://github.com/Kubementat/kwisatz) repository,
so that llama-swap manages the full lifecycle of the Qwen3.8 model using the TensorFold Zig engine.

**Key finding:** TensorFold's `tensorfold-native serve` runs inside a Docker container and exposes an
OpenAI-compatible API (default port 8888). llama-swap can proxy requests to this upstream server via its
`proxy` field, while its `cmd`/`cmdStop` fields manage the container lifecycle. The `scripts/prepare.sh`
script handles one-time setup (image build + checkpoint download), and `start.sh`/`stop.sh` handle runtime
lifecycle. The integration bridges these two worlds through a `models.yml` catalog entry and a wrapper
that translates llama-swap's generic commands into TensorFold-specific Docker operations.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        llama-swap (Go proxy)                        │
│                    port 9292 (OpenAI-compatible)                    │
│  /v1/chat/completions  →  proxy  →  http://127.0.0.1:8888           │
│         ↕                                                     ↕       │
│   models.yml (catalog)                                   TensorFold    │
│   sync-models.py                                     tensorfold-native  │
│   setup-llama-swap.sh                                  serve (Docker)   │
│         ↕                                                     ↕       │
│   config.yaml  ←── add-only merge ──────────────────   start.sh/      │
│                  from sync-models.py                       stop.sh      │
│                                                                    │
│   ┌── lifecycle commands ───────────────────────────────────────┐   │
│   │  cmd:       docker run ... tensorfold-native serve ...       │   │
│   │  cmdStop:   docker stop + rm qwen38-flash-next-tf            │   │
│   │  proxy:     http://127.0.0.1:${PORT}                         │   │
│   │  checkEndpoint: /health                                      │   │
│   └──────────────────────────────────────────────────────────────┘   │
│                                                                    │
│   ┌── prepare.sh (one-time) ───────────────────────────────────┐   │
│   │  1. preflight: docker, GPU, disk, memory                    │   │
│   │  2. build/pull TensorFold Zig image (TF_REF + patches)      │   │
│   │  3. download checkpoint (~122 GB) to HF cache               │   │
│   │  4. verify: model_type=qwen4_exp, GPTQ int4, n-gram table   │   │
│   └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Component Analysis

### 3.1 TensorFold Project (`Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold`)

**Repository structure:**
- `start.sh` — setup (first run) and start the server; calls `scripts/prepare.sh`, launches container,
  waits for `/health`, runs smoke test
- `stop.sh` — stop and remove the container, freeing GPU memory
- `scripts/config.sh` — all settings (model ID, port 8888, context 262144, parallel 8, KV_DTYPE fp8, etc.)
- `scripts/prepare.sh` — preflight, build/pull image, download checkpoint, verify
- `scripts/banner.sh` — start.sh's banner
- `patches/` — patches for the Zig engine
- `tools/` — benchmark and checks

**Key settings (from `scripts/config.sh`):**
| Setting | Default | Description |
|---------|---------|-------------|
| `MODEL_ID` | `azampatti/Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound` | HF checkpoint |
| `MODEL_REVISION` | `1464274120d36a4d8fcaa934552334a7d83ce0fd` | pinned commit |
| `PORT` | `8888` | API port |
| `SERVED_NAME` | `Qwen3.8-Flash-Next` | model ID in API |
| `CONTEXT` | `262144` | native window |
| `PARALLEL` | `8` | concurrent requests |
| `KV_DTYPE` | `fp8` | KV cache dtype |
| `VISION` | `1` | image/video input |
| `DRAFTS` | `1` | MTP drafting |
| `MAX_TOKENS` | `32768` | max decode tokens |
| `THINKING` | `1` | reasoning |
| `HF_CACHE` | `${HOME}/.cache/huggingface` | checkpoint location |
| `KERNEL_CACHE` | `${HOME}/.cache/tensorfold-qwen38` | CUDA kernels |
| `CONTAINER_NAME` | `qwen38-flash-next-tf` | Docker container name |

**Lifecycle commands:**
- `./start.sh` — full lifecycle: prepare → launch → wait → smoke test
- `./start.sh restart` — stop, then start again
- `./stop.sh` — stop and remove container
- `./scripts/prepare.sh` — one-time setup (image + checkpoint)
- `docker logs -f qwen38-flash-next-tf` — view logs

**Health endpoint:** `http://127.0.0.1:8888/health` — returns 200 when ready

### 3.2 llama-swap (from kwisatz)

**Setup script (`tasks/setup-llama-swap.sh`):**
- Installs llama-swap as a systemd daemon
- Generates `config.yaml` from template (`templates/llama-swap/config.yaml`)
- Generates `llama-swap.service` from template
- Default port: 9292, config at `/srv/llama-swap/config/config.yaml`
- Health check: `http://localhost:9292/health`

**Sync script (`tasks/sync-models.py`):**
- Reads `models.yml` (or `models.yml.default`) catalog
- Downloads local model weights via `hf CLI`
- Additively merges model entries into `config.yaml` (only `models` section)
- Restarts llama-swap after config change
- Polls health endpoint

**Catalog format (`models.yml`):**
```yaml
env:
  - name: MODEL_DIR
    value: ${HOME}/.cache/huggingface/hub

providers:
  - name: local
    baseUrl: http://localhost:9292/v1
    apiKey: "***"
    models:
      - name: qwen3.8-27b
        type: local
        download:
          - "hf download hf://unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_XL.gguf"
        serve:
          cmd: |
            ${llama-server-bin}
            --port ${PORT}
            -m ${models-dir-hf}/...
        agent:
          contextWindow: 262144
          maxTokens: 16000
          reasoning: true
          input: [text, image]
```

**llama-swap config.yaml key fields:**
| Field | Description |
|-------|-------------|
| `models.<id>.cmd` | Command to start the inference server (supports multi-line with `\|`) |
| `models.<id>.cmdStop` | Command to stop the upstream process |
| `models.<id>.proxy` | URL where llama-swap forwards requests (default: `http://localhost:${PORT}`) |
| `models.<id>.checkEndpoint` | Health check path (default: `/health`) |
| `models.<id>.env` | Per-model environment variables |
| `models.<id>.ttl` | Auto-unload after N seconds (0 = never) |
| `models.<id>.aliases` | Alternative model names |
| `models.<id>.filters` | Request parameter filtering |
| `macros` | Reusable string snippets |
| `globalTTL` | Default model idle TTL |

**Important:** llama-swap uses `${PORT}` macro (auto-assigned from `startPort`), `${MODEL_ID}` macro,
and `${PID}` macro. The `cmd` is run via bash, and `cmdStop` can reference `${PID}`.

### 3.3 Sync-models.py Integration Mechanism

The `sync_models/llama_swap.py` module:
- Loads `config.yaml` as YAML
- For each local model in the catalog, adds an entry to the `models` section
- `cmd` = expanded `serve.cmd` (with `${VAR}` placeholders replaced by catalog env values)
- `env` = per-model env entries (only per-model env, not top-level)
- Does NOT touch macros, matrix, hooks, apiKeys, peers, or global settings
- Rewrites the file with a YAML round-trip (comments not preserved)
- Restarts llama-swap via `sudo systemctl restart llama-swap`
- Polls health endpoint for up to `health_timeout` seconds (default 500)

---

## 4. Integration Design

### 4.1 Approach

We integrate TensorFold's `tensorfold-native serve` as a llama-swap-managed upstream server.
The approach has three layers:

1. **Preparation layer** (`scripts/prepare.sh`): One-time setup of the TensorFold image and checkpoint.
   This is run before llama-swap manages the model.

2. **Catalog layer** (`models.yml`): A declarative model entry that tells sync-models.py how to
   configure llama-swap for Qwen3.8-Flash-Next.

3. **Lifecycle layer** (`cmd`/`cmdStop` in config.yaml): llama-swap starts/stops the TensorFold
   container and proxies requests to it.

### 4.2 Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Use `proxy` field pointing to `http://127.0.0.1:8888` | TensorFold's server runs on a fixed port; no need for `${PORT}` macro |
| Use `cmd` to run `docker run ... tensorfold-native serve` | llama-swap manages the container lifecycle |
| Use `cmdStop` to run `docker stop + rm` | Clean container teardown on model unload |
| Set `ttl: 0` (never auto-unload) | The 122 GB model should stay loaded; manual control via llama-swap UI/API |
| Set `checkEndpoint: /health` | TensorFold's health endpoint |
| Set `env` for `HF_HUB_OFFLINE` and `TENSORFOLD_CUDA_KERNELS` | Required by TensorFold inside the container |
| Use `start.sh` for initial setup, then `cmd`/`cmdStop` for ongoing lifecycle | Separates one-time prep from runtime management |

### 4.3 Port Configuration

TensorFold uses a fixed port (8888 by default). Two options:

**Option A (recommended): Fixed port 8888**
- `proxy: http://127.0.0.1:8888`
- `cmd` uses `--port 8888`
- Simple, matches TensorFold's default

**Option B: Dynamic port via `${PORT}`**
- `proxy: http://127.0.0.1:${PORT}`
- `cmd` uses `--port ${PORT}`
- Requires `startPort` to be set to 8888 in config, or a custom macro

Option A is recommended because TensorFold's `config.sh` hardcodes `PORT=8888` and the
`start.sh`/`stop.sh` scripts expect this port.

---

## 5. Configuration Files

### 5.1 models.yml Entry

Add this to your `models.yml` (or `models.yml.default`):

```yaml
# Qwen3.8 Flash Next — TensorFold Zig engine on DGX Spark
# Requires: scripts/prepare.sh run first (one-time, ~122 GB download)

env:
  # TensorFold runtime environment
  - name: HF_HUB_OFFLINE
    value: "1"
  - name: TENSORFOLD_CUDA_KERNELS
    value: /opt/tensorfold/share/tensorfold/cuda/sm121
  - name: HF_CACHE
    value: ${HOME}/.cache/huggingface
  - name: KERNEL_CACHE
    value: ${HOME}/.cache/tensorfold-qwen38

providers:
  - name: local
    baseUrl: http://localhost:9292/v1
    apiKey: "***"
    models:
      - name: qwen3.8-flash-next
        type: local
        # One-time preparation (image build + checkpoint download)
        # This runs via bash; prepare.sh is idempotent.
        download:
          - "bash scripts/prepare.sh"
        serve:
          # Launch tensorfold-native serve inside Docker, managed by llama-swap.
          # The container name must be unique per model to avoid collisions.
          cmd: |
            set -euo pipefail
            CONTAINER_NAME="qwen38-flash-next-tf"
            PORT=8888
            # Remove any stale container with the same name
            docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            # Launch tensorfold-native serve with the pinned checkpoint
            docker run -d --name "$CONTAINER_NAME" \
              --gpus all --ipc=host --network host \
              --ulimit memlock=-1 --ulimit stack=67108864 \
              -v "${HF_CACHE}/hub/models--azampatti--Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound/snapshots/1464274120d36a4d8fcaa934552334a7d83ce0fd":/root/.cache/huggingface/hub/models--azampatti--Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound/snapshots/1464274120d36a4d8fcaa934552334a7d83ce0fd:ro \
              -v "${KERNEL_CACHE}/$(cat ${KERNEL_CACHE}/current_hash 2>/dev/null || echo default):/cache" \
              -e "HF_HUB_OFFLINE=${HF_HUB_OFFLINE}" \
              -e "TENSORFOLD_CUDA_KERNELS=${TENSORFOLD_CUDA_KERNELS}" \
              -e "TENSORFOLD_NO_UPDATE_CHECK=1" \
              tensorfold-qwen38:zig-db28187 \
              tensorfold-native serve \
                /root/.cache/huggingface/hub/models--azampatti--Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound/snapshots/1464274120d36a4d8fcaa934552334a7d83ce0fd \
                --name Qwen3.8-Flash-Next \
                --host 0.0.0.0 \
                --port "$PORT" \
                --context 262144 \
                --parallel 8 \
                --max-tokens 32768 \
                --temperature 1.0 \
                --top-p 0.95 \
                --top-k 20 \
                --kv-dtype fp8 \
                --thinking \
                --vision \
                --vision-max-images 50 \
                --vision-max-videos 4 \
                --vision-image-tokens 16384
          # Stop the TensorFold container and clean it up
          cmdStop: |
            docker stop -t 30 qwen38-flash-next-tf >/dev/null 2>&1 || true
            docker rm -f qwen38-flash-next-tf >/dev/null 2>&1 || true
        # Forward requests to the TensorFold server
        proxy: http://127.0.0.1:8888
        # Health check: TensorFold's /health endpoint
        checkEndpoint: /health
        # Never auto-unload (122 GB model, manual control)
        ttl: 0
        # Aliases for convenience
        aliases:
          - "Qwen3.8-Flash-Next"
          - "qwen3.8-flash"
          - "qwen3.8"
        # Agent metadata (used by sync-models.py for agent config)
        agent:
          contextWindow: 262144
          maxTokens: 32768
          reasoning: true
          input: [text, image]
        # Metadata exposed in /v1/models
        metadata:
          port: 8888
          context_size: 262144
          quantization: "INT4-AutoRound"
          kv_dtype: fp8
          vision: "true"
          parallel: 8
```

### 5.2 Expected llama-swap config.yaml Entry

After running `sync-models.py`, the `config.yaml` will contain:

```yaml
models:
  qwen3.8-flash-next:
    cmd: |
      set -euo pipefail
      CONTAINER_NAME="qwen38-flash-next-tf"
      PORT=8888
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
      docker run -d --name "$CONTAINER_NAME" \
        --gpus all --ipc=host --network host \
        --ulimit memlock=-1 --ulimit stack=67108864 \
        -v "/opt/data/.cache/huggingface/hub/models--azampatti--Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound/snapshots/1464274120d36a4d8fcaa934552334a7d83ce0fd:/root/.cache/huggingface/hub/models--azampatti--Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound/snapshots/1464274120d36a4d8fcaa934552334a7d83ce0fd:ro" \
        -v "/opt/data/.cache/tensorfold-qwen38/default:/cache" \
        -e "HF_HUB_OFFLINE=1" \
        -e "TENSORFOLD_CUDA_KERNELS=/opt/tensorfold/share/tensorfold/cuda/sm121" \
        -e "TENSORFOLD_NO_UPDATE_CHECK=1" \
        tensorfold-qwen38:zig-db28187 \
        tensorfold-native serve \
          /root/.cache/huggingface/hub/models--azampatti--Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound/snapshots/1464274120d36a4d8fcaa934552334a7d83ce0fd \
          --name Qwen3.8-Flash-Next \
          --host 0.0.0.0 \
          --port 8888 \
          --context 262144 \
          --parallel 8 \
          --max-tokens 32768 \
          --temperature 1.0 \
          --top-p 0.95 \
          --top-k 20 \
          --kv-dtype fp8 \
          --thinking \
          --vision \
          --vision-max-images 50 \
          --vision-max-videos 4 \
          --vision-image-tokens 16384
    cmdStop: |
      docker stop -t 30 qwen38-flash-next-tf >/dev/null 2>&1 || true
      docker rm -f qwen38-flash-next-tf >/dev/null 2>&1 || true
    proxy: http://127.0.0.1:8888
    checkEndpoint: /health
    ttl: 0
    env:
      - "HF_HUB_OFFLINE=1"
      - "TENSORFOLD_CUDA_KERNELS=/opt/tensorfold/share/tensorfold/cuda/sm121"
      - "HF_CACHE=/opt/data/.cache/huggingface"
      - "KERNEL_CACHE=/opt/data/.cache/tensorfold-qwen38"
    aliases:
      - "Qwen3.8-Flash-Next"
      - "qwen3.8-flash"
      - "qwen3.8"
    metadata:
      port: 8888
      context_size: 262144
      quantization: "INT4-AutoRound"
      kv_dtype: fp8
      vision: "true"
      parallel: 8
```

**Note:** The `cmd` will have `${HF_CACHE}` and `${KERNEL_CACHE}` expanded to their actual values
by sync-models.py's `expand_text` function (which replaces `${VAR}` with catalog env or process env
values). llama-swap macros like `${PORT}` are NOT expanded by sync-models.py (they're left for
llama-swap to expand at runtime). However, since we use a fixed port (8888), this isn't an issue.

### 5.3 Wrapper Script for Lifecycle Management

For users who prefer the `start.sh`/`stop.sh` workflow over llama-swap's auto-management,
create a wrapper that bridges the two:

```bash
#!/usr/bin/env bash
# /opt/data/vault/30-Reports/scripts/tensorfold-llama-swap-bridge.sh
#
# Bridges TensorFold's start.sh/stop.sh with llama-swap.
# - `bridge start`   : run prepare.sh (if needed) + start.sh, then register with llama-swap
# - `bridge stop`    : stop via llama-swap API (triggers cmdStop)
# - `bridge restart` : restart via llama-swap API
# - `bridge status`  : show llama-swap model status
# - `bridge health`  : check TensorFold health endpoint

set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-status}"
LLAMA_SWAP_URL="http://localhost:9292"
TENSORFOLD_URL="http://127.0.0.1:8888"

case "$ACTION" in
  start)
    echo "=== Preparing TensorFold (one-time) ==="
    bash scripts/prepare.sh
    echo "=== Starting Qwen3.8 via llama-swap ==="
    curl -s -X POST "$LLAMA_SWAP_URL/v1/models/qwen3.8-flash-next/load" || true
    ;;
  stop)
    echo "=== Stopping Qwen3.8 via llama-swap ==="
    curl -s -X POST "$LLAMA_SWAP_URL/v1/models/qwen3.8-flash-next/unload" || true
    ;;
  restart)
    echo "=== Restarting Qwen3.8 via llama-swap ==="
    curl -s -X POST "$LLAMA_SWAP_URL/v1/models/qwen3.8-flash-next/reload" || true
    ;;
  status)
    echo "=== llama-swap models ==="
    curl -s "$LLAMA_SWAP_URL/running" || true
    echo ""
    echo "=== TensorFold health ==="
    curl -s "$TENSORFOLD_URL/health" || true
    echo ""
    echo "=== Docker container ==="
    docker ps -a --filter "name=qwen38-flash-next-tf" || true
    ;;
  health)
    curl -s "$TENSORFOLD_URL/health" || true
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|health}"
    exit 1
    ;;
esac
```

---

## 6. Setup Procedure

### 6.1 Prerequisites

1. **llama-swap installed** (from kwisatz):
   ```bash
   ./tasks/setup-llama-swap.sh --force
   ```

2. **TensorFold repository cloned**:
   ```bash
   cd ~
   git clone https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold.git
   cd Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
   ```

3. **DGX Spark with Docker** (NVIDIA container runtime, user in `docker` group)

4. **~160 GB free disk** (122 GB checkpoint + 35 GB image)

### 6.2 Integration Steps

```bash
# Step 1: Add the Qwen3.8 model to models.yml
cp models.yml.default models.yml
# (append the model entry from Section 5.1 to models.yml)

# Step 2: Run prepare.sh to build image + download checkpoint (~122 GB, one-time)
cd Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
bash scripts/prepare.sh

# Step 3: Run sync-models.py to add the model to llama-swap config
cd /path/to/kwisatz
python3 tasks/sync-models.py

# Step 4: Verify llama-swap loaded the model
curl -s http://localhost:9292/v1/models | python3 -m json.tool

# Step 5: Test a completion
curl -s http://localhost:9292/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.8-flash-next",
    "messages": [{"role": "user", "content": "Write a Python fibonacci function."}],
    "max_tokens": 1000
  }'
```

### 6.3 Using the Bridge Script

```bash
# Start (prepare if needed + load into llama-swap)
bash tensorfold-llama-swap-bridge.sh start

# Stop (unload from llama-swap, stops container)
bash tensorfold-llama-swap-bridge.sh stop

# Check status
bash tensorfold-llama-swap-bridge.sh status

# Direct health check
bash tensorfold-llama-swap-bridge.sh health
```

---

## 7. Lifecycle Management

### 7.1 Model Loading (via llama-swap)

When a request comes in for `qwen3.8-flash-next`:
1. llama-swap checks if the model is loaded
2. If not, it runs the `cmd` (docker run tensorfold-native serve)
3. llama-swap polls `http://127.0.0.1:8888/health` until ready
4. Once healthy, requests are forwarded to the TensorFold server
5. The TensorFold container stays running (ttl=0, never auto-unload)

### 7.2 Model Unloading (via llama-swap)

When the model is unloaded (manual or via API):
1. llama-swap runs `cmdStop` (docker stop + rm)
2. GPU memory is freed

### 7.3 Direct TensorFold Control

You can still use TensorFold's scripts directly:
```bash
cd Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
./start.sh          # prepare + start
./start.sh restart  # restart
./stop.sh           # stop
```

But when using llama-swap, the preferred way is through the llama-swap API:
```bash
# Load model
curl -s -X POST http://localhost:9292/v1/models/qwen3.8-flash-next/load

# Unload model
curl -s -X POST http://localhost:9292/v1/models/qwen3.8-flash-next/unload

# Check status
curl -s http://localhost:9292/running

# List models
curl -s http://localhost:9292/v1/models
```

### 7.4 Configuration Reload

After editing `models.yml`:
```bash
cd /path/to/kwisatz
python3 tasks/sync-models.py --no-restart  # update config without restart
sudo systemctl restart llama-swap           # restart manually
```

---

## 8. Verification

### 8.1 Health Check

```bash
# llama-swap health
curl -s http://localhost:9292/health

# TensorFold health (when model is loaded)
curl -s http://127.0.0.1:8888/health

# Running models
curl -s http://localhost:9292/running
```

### 8.2 Smoke Test

```bash
curl -s http://localhost:9292/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.8-flash-next",
    "messages": [{"role": "user", "content": "Reply with OK."}],
    "max_tokens": 32,
    "temperature": 0,
    "chat_template_kwargs": {"enable_thinking": false}
  }'
```

### 8.3 Model Listing

```bash
curl -s http://localhost:9292/v1/models | python3 -m json.tool
```

Expected output includes:
```json
{
  "data": [
    {
      "id": "qwen3.8-flash-next",
      "object": "model",
      "name": "Qwen3.8 Flash Next",
      "description": "Qwen3.8 Flash Next on DGX Spark (TensorFold)",
      "metadata": {
        "port": 8888,
        "context_size": 262144,
        "quantization": "INT4-AutoRound",
        "kv_dtype": "fp8",
        "vision": "true",
        "parallel": 8
      }
    }
  ]
}
```

---

## 9. Risks and Considerations

### 9.1 Memory Management

- The 122 GB checkpoint + fp8 KV cache (~4.37 GB per full window) requires careful memory management
- TensorFold's `start.sh` checks `MemAvailable` before launching; llama-swap does not
- **Recommendation:** Set `MEM_CHECK=0` in config.sh if you want to bypass memory checks,
  but ensure sufficient memory is available

### 9.2 Image/Checkpoint Version Pinning

- The TensorFold image is pinned to `TF_REF=db281878ddb836fd0df510d8771ecb7e0fe47d26` (zig-flashnext)
- The checkpoint is pinned to revision `1464274120d36a4d8fcaa934552334a7d83ce0fd`
- If you update the TensorFold repo, you must re-run `scripts/prepare.sh --rebuild` to rebuild the image

### 9.3 Container Name Collision

- The `cmd` uses a fixed container name `qwen38-flash-next-tf`
- If you run multiple models with llama-swap, ensure each has a unique container name
- The `cmd` includes `docker rm -f` before `docker run` to clean up stale containers

### 9.4 Logging

- TensorFold's logs are visible via `docker logs -f qwen38-flash-next-tf`
- llama-swap's logs are in `journalctl -u llama-swap -f`
- The `logToStdout` setting in config.yaml controls what's logged

### 9.5 GPU Memory

- The DGX Spark has 128 GB unified memory
- Weights: ~66 GB (loaded with n-gram table)
- KV cache: ~4.37 GB per full window (fp8)
- With PARALLEL=8: ~35 GB KV cache + 66 GB weights = ~101 GB
- Plus 10 GB reserve + 2 GB vision workspace = ~113 GB
- This fits within 128 GB, but leave some headroom

### 9.6 Network Configuration

- TensorFold binds to `0.0.0.0:8888` by default
- llama-swap proxies to `127.0.0.1:8888`
- If accessing from another machine, ensure port 8888 is reachable

---

## 10. Summary

The integration of Qwen3.8 Flash Next (TensorFold) with llama-swap is straightforward:

1. **One-time setup:** Run `scripts/prepare.sh` to build the TensorFold image and download the checkpoint
2. **Catalog entry:** Add the Qwen3.8 model to `models.yml` with the `serve.cmd` that launches `tensorfold-native serve` in Docker
3. **Sync:** Run `sync-models.py` to add the model to llama-swap's `config.yaml`
4. **Runtime:** llama-swap manages the container lifecycle (start/stop) and proxies OpenAI API requests to TensorFold

The key insight is that TensorFold's `tensorfold-native serve` is already an OpenAI-compatible server,
so llama-swap can proxy to it directly. The `cmd`/`cmdStop` fields in llama-swap handle the Docker
container lifecycle, while `proxy` and `checkEndpoint` handle request forwarding and health checking.

**Files created/modified:**
- `models.yml` — add Qwen3.8 model entry
- `/srv/llama-swap/config/config.yaml` — auto-generated by sync-models.py
- `tensorfold-llama-swap-bridge.sh` — optional bridge script for direct control

**Commands:**
```bash
# Setup
./tasks/setup-llama-swap.sh --force
cd Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
bash scripts/prepare.sh
cd /path/to/kwisatz
python3 tasks/sync-models.py

# Usage
curl -s http://localhost:9292/v1/models          # list
curl -s http://localhost:9292/running             # check loaded models
curl -s -X POST http://localhost:9292/v1/models/qwen3.8-flash-next/load   # load
curl -s -X POST http://localhost:9292/v1/models/qwen3.8-flash-next/unload  # unload
```
