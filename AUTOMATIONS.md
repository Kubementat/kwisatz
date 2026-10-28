# Automations

The list of all automated software components in this repository.
For each of the scripts you can run the script with the `--help` parameter to display all environment configuration and script parameters.
E.g. `./tasks/setup-basics.sh --help`

To install one of them, prefer the CLI over the bare script — it applies the config's
`env:`/`args:` and records the run: `kwisatz apply <name>` (`./kwisatz apply basics` also
resolves `setup-basics`). `kwisatz info <name>` shows the same `--help` text plus the target's
resolved command, env keys and last apply.

Because a task script cannot answer a password prompt (`stdin` is `/dev/null`), `kwisatz apply`
settles sudo before the first script runs: your password once, up front, and the ticket held open
for the rest of the run. `--no-sudo-warmup` opts out of both; see *Using the `kwisatz` CLI* in
README.md.

### System & Infrastructure

#### `setup-basics.sh`
Installs common system packages (curl, git, python3, etc.), **uv** Python package manager, **herdr** CLI tool, Node.js/npm, and the **huggingface-cli**.

#### `setup-docker.sh`
Installs Docker Engine from the official Docker repository, adds the current user to the `docker` group and verifies the installation.

#### `setup-nvidia-container.sh`
Makes an existing GPU usable from containers via **CDI** (Container Device Interface). Installs the NVIDIA Container Toolkit when missing, generates `/etc/cdi/nvidia.yaml`, and installs an apt hook that regenerates the spec after a driver upgrade. Prerequisite for every GPU task (`setup-colqwen.sh`, `setup-vllm.sh`, `setup-vllm-omni.sh`). Does **not** install the GPU driver itself.

**Why CDI and not `deploy.resources.reservations.devices`:**
- The legacy path injects `/dev/nvidia*` from an OCI prestart hook, *after* runc created the container's systemd scope, so systemd never learns about those device nodes
- A later `systemctl daemon-reload` (snapd triggers one every few hours) then rebuilds the scope's cgroup device filter and silently revokes GPU access from the **running** container — CUDA fails while the container keeps answering `/health` with 200
- CDI injects the devices into the OCI spec *before* container creation, so a reload re-applies them

**Why the apt hook:**
- A CDI spec pins version-suffixed driver libraries (`libcuda.so.580.142`); a driver upgrade renames them and containers fail to start with `unresolvable CDI devices nvidia.com/gpu=all`
- The hook regenerates the spec in the same apt transaction that replaced the driver
- Manual equivalent: `sudo nvidia-cdi-refresh` (`--check` reports staleness without writing, `--force` regenerates unconditionally)

#### `setup-memory-safety.sh`
Guards against **silent unified-memory freezes** — the failure mode where a GPU box stops responding instead of failing. On unified-memory hardware (NVIDIA DGX Spark / GB10) host RAM and GPU memory are one physical pool, and when it is exhausted the CUDA allocator keeps asking, the system falls back to swap and thrashes, and the kernel is too starved to run its own OOM killer: SSH stops answering, nothing is logged, and the only way out is a power cycle. This script applies the three host-level mitigations that belong to the machine rather than to any one service, so it should run **before** the GPU workloads (`setup-llama-swap.sh`, `setup-vllm.sh`, `setup-gufo-*`, `setup-tensorfold-*`).

**What it does:**
- Disables swap and removes it from `/etc/fstab` (`MEMSAFETY_DISABLE_SWAP`, default `true`; the swap file itself is only deleted with `MEMSAFETY_REMOVE_SWAPFILE=true`), writing a timestamped `/etc/fstab.bak.<ts>` first
- Installs and configures **earlyoom** as the userspace OOM guard (`MEMSAFETY_EARLYOOM`, default `true`; triggers `MEMSAFETY_EARLYOOM_MEM_PCT=5`, `MEMSAFETY_EARLYOOM_SWAP_PCT=10`) via `/etc/default/earlyoom` plus an `OOMScoreAdjust` drop-in
- Optionally caps GPU clocks at boot through `nvidia-clock-cap.service` — **off by default** (`MEMSAFETY_GPU_CLOCK_CAP=false`, `MEMSAFETY_GPU_CLOCK_MIN=300`/`MEMSAFETY_GPU_CLOCK_MAX=2100`), needs `nvidia-smi`

**Why swap off looks backwards and is deliberate:** swap does not add safety here, it removes it — with swap present the machine degrades into thrashing and hangs without diagnostics, while without swap the kernel reaches its OOM condition promptly and kills a single process. You lose one inference job instead of the machine. Corroborated by pytorch#174358, NVIDIA forum threads 360336/362769 and ComfyUI#11106.

**Why no `MemoryMax=` on GPU services:** measured on GB10 / driver 580.142, a 4 GB `cudaMalloc` is charged to the cgroup as 71 MiB — classic device allocations escape memcg accounting entirely, while the same 4 GB shows plainly as a drop in `MemFree`. A `MemoryMax=` on those services would constrain only their host-side heap and give false assurance, so this script deliberately sets none; earlyoom watches `/proc/meminfo` and is the effective guard.

**Platform behaviour:** the swap and GPU measures are specific to unified-memory NVIDIA hardware and are **skipped** on anything else — disabling swap on an ordinary server with discrete VRAM is bad advice, not a safety measure. earlyoom is installed on every platform. `--check` reports the detected platform and the resulting state and changes nothing; `--force` re-applies (`FORCE=1`).

#### `setup-traefik.sh`
Deploys production-ready Traefik v3 reverse proxy with Docker Compose, TLS via Let's Encrypt, security headers, rate limiting, and optional protected dashboard.

**See also:** [README_TRAEFIK.md](README_TRAEFIK.md) for full documentation

#### `setup-upstream-kernel.sh`
Prepares the Zabbly mainline kernel apt repository on Ubuntu 22.04/24.04 LTS, providing access to the latest stable Linux kernels.

**Notes:**
- Requires Secure Boot to be disabled in BIOS/UEFI
- May require DKMS rebuild for NVIDIA proprietary drivers
- Officially supports Ubuntu Noble (24.04) and Jammy (22.04)

#### `setup-sshd.sh`
Installs OpenSSH server and configures it through the managed drop-in
`/etc/ssh/sshd_config.d/99-machine-setup.conf` (the main `sshd_config` is never
touched). Lockout-safe: `PasswordAuthentication no` only when a usable key is
in `~/.ssh/authorized_keys`; when moving the port, the old/live port keeps
listening; the new port is allowed in UFW before the restart; on
socket-activated systems (Ubuntu 24.04+ default, `ssh.socket`) the socket is
disabled for a port move — a socket-activated sshd would not bind the new
port; `sshd -t` validates before any restart (invalid drop-in is reverted) and
the effective config is proven with `sshd -T` afterwards. An unchanged
drop-in does not trigger a restart.

#### `configure-firewall.sh`
Sets up **UFW** rules for the SSH port plus any explicitly requested ports —
each service's own setup script opens its port (no speculative rules).
Lockout-safe: over SSH it refuses to enable UFW while the live session's port
would be cut, and the first remote enable arms the
`machine-setup-ufw-rollback` timer (see below).

#### `setup-fail2ban.sh`
Installs **fail2ban** (including the Python 3.12 `pyasynchat` compatibility fix) and configures the jail to monitor the custom SSH port, protecting SSH from brute-force attacks.

---

### AI & LLM Services

#### `setup-lm-studio.sh`
Downloads the specified LM Studio AppImage, creates a desktop entry, an optional start script, and optionally installs the **llmster** CLI (`lms`).

#### `setup-llama-cpp.sh`
Builds and installs llama.cpp from source with auto or manual GPU backend selection. Skips install if binaries are already present.

#### `setup-openwebui.sh`
Deploys Open WebUI using Docker Compose, connecting to an external LM Studio instance for AI model inference. Supports both direct access mode and Traefik reverse-proxy integration.

**Features:**
- Direct mode: Accessible at `http://localhost:3333`
- Traefik mode: Accessible via custom domain with TLS
- Secure secret key: generated on first run, stored in `.env` (mode 600), reused on re-runs (never rotated); `docker-compose.yml` keeps only a literal `${WEBUI_SECRET_KEY}` placeholder resolved from the project `.env`
- Creates convenience start script

#### `setup-opencode.sh`
Installs the **Opencode 2.x** AI coding agent. By default only the CLI is installed (`npm install -g @opencode/cli@$OPENCODE_VERSION`); `OPENCODE_SERVICE=true` additionally installs the `opencode` systemd unit, `USE_DOCKER=true` deploys the Opencode server as a Docker Compose stack (direct or Traefik mode).

**Features:**
- **V1 → V2 cutover:** the V1 npm package `opencode-ai` (which never ships past 1.19 and owns the same `opencode` command) is removed before the V2 install, so the two never fight over the binary. Config (`~/.config/opencode`) and session data (`~/.local/share/opencode/opencode.db`) are *kept* — V2 reads the V1 config format unchanged. `--uninstall` removes both packages and deletes the Docker stack / unit; user config and sessions are never deleted.
- **One version knob:** `OPENCODE_VERSION` (default `2.2.0`) drives both the npm package and the default server image (`ghcr.io/anomalyco/opencode:<version>`), so a central version pin only has to set that one variable. `OPENCODE_IMAGE` remains overridable — but note this registry's `:latest` is still the 1.x line, so only versioned tags are V2 images (`warn_moving_image` guards it).
- **Auth is a password only:** OpenCode V2 fixed the HTTP Basic username to `opencode` and dropped `OPENCODE_SERVER_USERNAME`, so the V1 variable is *gone* (not accepted). `OPENCODE_PASSWORD` is auto-generated on first run, stored in `/srv/opencode/.env` (mode 600) or the unit, read back before generating a new one, and never rotated on re-runs.
- **Readiness gate:** health is `GET /api/info` with `-u opencode:<password>` (the V2 server-info/readiness endpoint) after `docker compose up -d` plus `wait_for_healthy`; Traefik mode skips the direct probe. In systemd mode a re-run converges: the unit is rendered to a temp file and reinstalled/restarted only when it actually differs.
- **Docker state really persists:** the compose templates mount `opencode_data:/root/.local/share/opencode` and `opencode_config:/root/.config/opencode` (the paths `opencode debug paths` reports inside the image). The previous `:/data` mount held nothing, so all config and the session database lived in the container's writable layer and were lost on `docker compose down` — the fix is a pure fix, nothing to migrate.
- Env: `OPENCODE_PORT` (4096), `OPENCODE_HOSTNAME` (0.0.0.0, alias `OPENCODE_HOST`), `OPENCODE_DATA_DIR` (`/srv/opencode`), `OPENCODE_TRAEFIK` + `OPENCODE_DOMAIN` + `PROXY_NETWORK`, `WAIT_TIMEOUT` (180). UFW is opened for the port only in direct mode.
- Plan/research: `docs/plans/opencode-v2-upgrade-10-28-2026.md` (V2 breaking changes, sources, and what was deliberately *not* converted — the V1-shaped `~/.config/opencode/opencode.json` written by `sync-models` stays as is, since V2 normalizes it in memory and rewriting it is not our tool's job).

#### `setup-orca.sh`
Installs the Orca remote server (https://www.onorca.dev) in headless mode: the Linux AppImage is installed to `/opt/orca` and `orca serve` runs as the `orca-serve.service` systemd unit under the invoking user by default (lingering enabled so live terminals survive restarts); a different user can be set via `ORCA_SERVICE_USER`. Installs the Xvfb + Electron shared-library prerequisites, verifies the download, prints the pairing URL for clients, and opens the UFW port when the firewall is active.

**Features:**
- `ORCA_VERSION` (default `latest`), `ORCA_PORT` (default 6768), `ORCA_SERVICE_USER` (default: invoking user/sudo caller), `ORCA_PAIRING_ADDRESS` (Tailscale/LAN address or `https://…/runtime` URL clients should dial; empty = local-only), `ORCA_MOBILE_PAIRING`, `ORCA_DESKTOP` (adds an `/usr/local/bin/orca-desktop` AppImage launcher — only one host mode per machine)
- Bounded health verification on the `orca_server_ready` JSON contract
- Idempotent: re-runs skip the download and leave a healthy running service untouched; changed env values re-render the unit and restart

#### `setup-llama-swap.sh`
Deploys llama-swap, a multi-model LLM proxy with hot-swap support, as a native systemd service. Downloads the Go binary from GitHub releases and generates a comprehensive `config.yaml` with all available options documented.

**Features:**
- Hot-swap between multiple LLM models without restarting
- OpenAI-compatible API at `/v1/chat/completions`
- Web UI at `/ui`
- Health check endpoint at `/health`
- Comprehensive config with all options documented

#### `setup-laya.sh`
Installs [Laya](https://huggingface.co/convaiinnovations/laya) — a self-hosted, non-autoregressive "System 1" decision model (typed `choice`/`score`/`noul` questions, not chat) — as `laya[serve]` into an isolated Python venv at `/srv/laya/venv` and runs it as the native systemd service `laya.service`. The server binds `LAYA_HOST` (default `0.0.0.0`):`LAYA_PORT` (default `7771`) and answers typed questions on `POST /v1/systemone`; a UFW inbound rule is added for the port (skipped when bound to loopback) and a bounded HTTP health gate runs after (re)start.

**Features:**
- Idempotent venv install, pinned version (`LAYA_VERSION`, default `0.3.19`), `--check`/`--force`
- Auto-detects `LAYA_DEVICE` (cuda/cpu) via `nvidia-smi`; CPU installs use CPU-only torch wheels
- Renders `templates/laya/laya.service` via `envsubst` (no inline heredocs), installs to `/etc/systemd/system/laya.service`, enables + starts the service
- Bearer-token auth: `LAYA_API_KEY` (env var wins), else read back from `/srv/laya/.env` (mode 600, `EnvironmentFile=` in the unit — the token is never rendered into the unit file), else generated via `openssl rand -hex 24`; never rotated on re-runs, printed in the summary. `/v1/systemone` requires `Authorization: Bearer <key>`; `/health` stays open
- UFW rule via `lib/helpers.sh` (`ufw_firewall_section`), bounded health gate polls `GET /health` for `{"status":"ok","loaded":[...],"device":"..."}` (`LAYA_HEALTH_TIMEOUT` default `300`)
- Service user is the invoking user (`LAYA_USER` / `SUDO_USER`-aware) so HF model caches land in that user's home
- Writes `start-laya.sh` convenience script (foreground `laya-serve`, defaults `127.0.0.1:8000`, all `LAYA_*` env vars overridable) from `templates/laya/start-laya.sh`
- See the companion skill `skills/laya/SKILL.md` for how to call the deployed model, and `docs/research/laya-system1-model-research.md` for the underlying research

#### `setup-ollaya.sh`
Installs [Ollaya](https://github.com/ollaya-dev/ollaya) ("Ollama for decision models", serves `laya`, `winnow`, `decider`, ... behind a TypeSafe-compatible `/v1/systemone` API) and runs `ollaya serve` as the native systemd service `ollaya.service` under the system user `ollaya`. Binds `OLLAYA_HOST` (default `0.0.0.0:11435`); models live in `/srv/ollaya/models`.

**Features:**
- Uses the official release installer (downloaded to a temp file, sha256-verified, latest release by default, `OLLAYA_VERSION` pins a specific one) with `OLLAYA_NO_SERVICE=1`; skipped when the target version is already installed (re-runs upgrade if a newer release exists) (`--force` to re-run), `--check` for status
- Renders `templates/ollaya/ollaya.service` via `envsubst`; `OLLAYA_API_KEY` from env > `/srv/ollaya/.env` (mode 600, `EnvironmentFile=`) > `openssl rand -hex 24`, never rotated
- Health gate: unauthenticated `GET /` ("Ollaya is running"), then authenticated `GET /api/version`
- Pulls `OLLAYA_PULL_MODELS` (default `laya`) via idempotent `POST /api/pull`
- UFW rule via `ufw_firewall_section` (skipped on loopback bind); requires glibc >= 2.38 and `zstd`
- See the companion skill `skills/ollaya/SKILL.md` for using the `ollaya` CLI and API, and `docs/research/ollaya-research.md` for the research

#### `setup-colqwen.sh`
Generates a ColQwen2.5 embedding-service Docker project (FastAPI + colpali-engine on an NVIDIA NGC PyTorch base image). Serves multi-vector embeddings (dim 128) for document images and text queries — the retrieval side of visual document RAG. The script only generates the project; build and start it yourself. Models are mounted read-only from the HF cache at the identical path (adapter `base_model_name_or_path` entries resolve) and are never downloaded (fully offline: `HF_HUB_OFFLINE=1`).

**Features:**
- `POST /embed/queries` and `POST /embed/images` (multi-vector, one embedding per input, in order)
- `GET /health` readiness probe (200 only after the model is loaded)
- Fails loudly instead of serving wrong data: build aborts if pip replaced the NGC CUDA torch; startup aborts if LoRA adapter weights were silently dropped
- Generated `./test.sh` smoke test (health, embeddings incl. dim check, error cases)
- Tested combination for CUDA 13.0 / driver 580.x hosts (e.g. DGX Spark): NGC `25.10-py3` + colpali-engine `0.3.13` — see comments in the generated `.env` before changing versions

#### `setup-vllm.sh`
Deploys vLLM as a Docker-based OpenAI-compatible inference server. Supports NVIDIA (CUDA), AMD (ROCm), and CPU backends with auto-detection. Mounts the HuggingFace cache directory so models downloaded via `huggingface-cli` are automatically available.

**Features:**
- Auto-detects GPU backend (NVIDIA, AMD, or CPU fallback)
- Multi-GPU tensor parallelism support
- LM Studio models directory auto-mount
- Optional Traefik reverse-proxy integration
- Input validation for all configuration values
- Supports `--nvidia`, `--amd`, `--cpu`, `--force`, `--check` flags

#### `setup-vllm-omni.sh`
Deploys **vLLM-Omni** — the official vLLM sub-project for omni-modality serving (TTS/speech, diffusion, image/video generation, any-to-any models like Qwen3-Omni / Cosmos3) — as a Docker-based, OpenAI-compatible server. Uses prebuilt Docker Hub images (no local build), auto-detects the GPU backend, and serves via `vllm serve <model> --omni`. Runs alongside `setup-vllm.sh` on its own port and directory.

**Features:**
- Prebuilt images: `vllm/vllm-omni` (NVIDIA, amd64/arm64) and `vllm/vllm-omni-rocm` (AMD)
- Auto-detects NVIDIA / AMD / CPU backend (CPU is impractical for generative models)
- Model-agnostic: without `VLLM_OMNI_MODEL` the container is not started (prints next steps)
- Optional Traefik reverse-proxy integration
- Idempotent; supports `--force` and `--check`

#### `setup-tensorfold-spark-qwen38-flash.sh`
Deploys **Qwen3.8 Flash Next** on one DGX Spark (GB10, 128 GB unified memory) via TensorFold's Zig engine (`tensorfold-native`), **managed by llama-swap** (no standalone stack). Clones the pinned MiaAI-Lab recipe into `/srv/tensorfold`, runs its `scripts/prepare.sh` (prebuilt image + ~122 GiB checkpoint `azampatti/Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound`, pinned revision), and merges a `qwen3.8-flash-next` entry into the llama-swap catalog (`models.yml`) + `sync-models.py`. llama-swap owns the container lifecycle: `serve.cmd` runs the upstream `start.sh` (blocking, `FOREGROUND=1`), `cmdStop` stops it, and requests are proxied from port 9292 to TensorFold on `TENSORFOLD_PORT` (default 8888, fixed host-network port). Spark is hard-required (the recipe is Spark-sized).

**Features:**
- Pinned recipe commit; the TensorFold engine pin (`TF_REF db281878`, image `tensorfold-qwen38:zig-db28187`) is applied by the recipe's `prepare.sh`. The checkpoint revision is pinned inside the recipe (`MODEL_REVISION`)
- Serve levers (context, parallel, KV dtype, vision, ...) are upstream settings — set them in `/srv/tensorfold/.env` (mode 600; see `scripts/config.sh` there). A re-run re-renders only the keys the script owns (`FOREGROUND`, `PORT`, `HOST`) and keeps every line you added
- Kernel cache, locks, prepared marker and logs live under `KERNEL_CACHE_DIR` / `TENSORFOLD_STATE_DIR` (defaults `/srv/tensorfold/.cache` and `/srv/tensorfold/.state`; flags `--kernel-cache`, env `KERNEL_CACHE_DIR`/`TENSORFOLD_STATE_DIR`) — llama-swap runs `start.sh` as root with `ProtectHome=read-only`, so nothing writable may sit in `$HOME`. A populated cache under the legacy `~/.cache/tensorfold-qwen38` is reported, never moved
- Pre-flight: llama-swap installed, CDI GPU spec, Spark detection, `hf` CLI — then, in that order, "checkpoint cached?" (any `snapshots/*/config.json` + weights, revision-independent), "engine image present?", and free disk (~160 GB) checked **only for what still has to be downloaded**: a re-run with checkpoint + image on disk converges even on a full filesystem. Still before any download, `config.yaml` is probed for writability with the same contract `sync-models.py` applies (read-only, silent when llama-swap has no config yet) — a cold install against the `root:root 644` file `setup-llama-swap.sh` creates therefore fails in seconds instead of after the ~122 GiB download, and `--check` reports it as the `Config:` line. An advisory cross-check warns when the sibling 27B install advertises the same TensorFold port
- Catalog merge is additive and idempotent (entry replaced only if the rendered template changed); `sync-models.py` restarts llama-swap only on config change. When only the global `healthCheckTimeout` raise touched `config.yaml`, the script restarts llama-swap itself — the add-only sync would otherwise never load the raised value
- Smoke test through llama-swap (default timeout 900 s — ~122 GiB checkpoint load, ~66 GiB of it GPU-resident): the load is triggered in the background and `/running` is polled with a bounded deadline before the completion is asserted. `--skip-smoke` still proves `/health` and `/v1/models`, and warns that the model itself was not exercised
- Idempotent, converge-by-default; supports `--force` (stop model + force re-merge) and `--check`. The pinned checkout converges with `git fetch` + `checkout --force` (a dirty tree is reported first)
- **Trust boundary:** llama-swap (root, systemd) execs `start.sh` and `prepare.sh` out of `/srv/tensorfold`, so anyone who can write that checkout owns the host
- Shared logic: `lib/tensorfold-helper.sh` holds the parts both TensorFold tasks run identically (pre-flight, the "what still needs downloading" gate, pinned checkout, `.env` render, catalog merge, llama-swap health-timeout bump / sync / smoke test, `--check` signals). The script keeps the recipe-specific constants and passes them in.

#### `setup-tensorfold-spark-qwen38-27b.sh`
Deploys **Qwen3.8-27B** on one DGX Spark (GB10, 128 GB unified memory) via **TensorFold v0.6.0 (Python engine** `c464617`, image `tensorfold-qwen38-27b:v0.6.0`, prebuilt `ghcr.io/miaai-lab/qwen3.8-27b-dgx-spark-tensorfold:v0.6.0-fb91a0019fdc` with local build fallback), **managed by llama-swap** (no standalone stack). Clones the pinned MiaAI-Lab recipe into `/srv/tensorfold-27b`, runs its `scripts/prepare.sh` (image + ~19 GB checkpoints `Vontra/Qwen3.8-27B-MLX-4bit` + `z-lab/Qwen3.8-27B-DFlash2`), and merges a `qwen3.8-27b-tf` entry into the llama-swap catalog (`models.yml`) + `sync-models.py`. llama-swap owns the container lifecycle: `serve.cmd` runs the upstream `start.sh` (blocking, `FOREGROUND=1`), `cmdStop` stops it, and requests are proxied from port 9292 to TensorFold on `TENSORFOLD_27B_PORT` (default 8889 — Flash Next holds 8888, fixed host-network port). Spark is hard-required (the recipe is Spark-sized).

**Features:**
- Pinned recipe commit; the TensorFold engine pin (`TF_VERSION v0.6.0`, patches `fb91a0019fdc`) is applied by the recipe's `prepare.sh`
- **Checkpoint revisions:** the recipe exposes `MODEL_ID`/`DRAFT_ID` but no `MODEL_REVISION`, so `prepare.sh` always resolves the newest revision of `Vontra/Qwen3.8-27B-MLX-4bit` and `z-lab/Qwen3.8-27B-DFlash2`. The script records the SHAs it resolved in `/srv/tensorfold-27b/.checkpoint-revisions`, compares them against the local cache *and* the current upstream `main` on every re-run and with `--check`, and warns loudly on drift (never fatal — a usable cached checkpoint still converges). **Upstream ask:** mirror the Flash Next recipe's `MODEL_REVISION`/`DRAFT_REVISION` into this recipe's `scripts/config.sh`; residual risk until then is recorded in `docs/research/2026-10-15-qwen38-27b-dgx-spark-tensorfold.md` — detection is best-effort, a cache eviction plus a re-run can install weights this entry was never validated against
- Serve levers (context, parallel, KV pool, YaRN, KV dtype, prefill-fp8, vision, drafts, ...) are upstream settings — set them in `/srv/tensorfold-27b/.env` (mode 600; see `scripts/config.sh` there). A re-run re-renders only the keys the script owns (`FOREGROUND`, `PORT`, `HOST`) and keeps every line you added
- Kernel cache + lock files + prepared marker under `KERNEL_CACHE_DIR` (default `/srv/tensorfold-27b/.cache`, service-writable, `--kernel-cache`; llama-swap runs as root with `ProtectHome=read-only`)
- Pre-flight: llama-swap installed, CDI GPU spec, Spark detection, `hf` CLI — then, in that order, "both checkpoints cached?" (any `snapshots/*/config.json` + weights; checkpoints are not revision-pinned), "engine image present?", and free disk (~60 GB) checked **only for what still has to be downloaded**: a re-run with everything on disk converges even on a full filesystem. Still before any download, `config.yaml` is probed for writability with the same contract `sync-models.py` applies (read-only, silent when llama-swap has no config yet) — a cold install against the `root:root 644` file `setup-llama-swap.sh` creates therefore fails in seconds instead of after the ~19 GB download, and `--check` reports it as the `Config:` line. An advisory cross-check warns when the sibling Flash Next install advertises the same TensorFold port
- Catalog merge is additive and idempotent (entry replaced only if the rendered template changed); `sync-models.py` restarts llama-swap only on config change. When only the global `healthCheckTimeout` raise touched `config.yaml`, the script restarts llama-swap itself — the add-only sync would otherwise never load the raised value
- Smoke test through llama-swap (default timeout 600 s — 19 GB load + one-time kernel compile): the load is triggered in the background and `/running` is polled with a bounded deadline before the completion is asserted. `--skip-smoke` still proves `/health` and `/v1/models`, and warns that the model itself was not exercised
- Model id `qwen3.8-27b-tf`, aliases `qwen3.8-27b-tensorfold` / `qwen3.8-27`. No case-only alias (upstream's `SERVED_NAME` `Qwen3.8-27B` is what the *container* calls itself): `qwen3.8-27b` belongs to the llama.cpp GGUF entry, and a client that lower-cases model names must not silently land on the other runtime. **Known limitation:** llama-swap rewrites the request's `model` to the served name, so the response's `model` field is `Qwen3.8-27B`, not the id you asked for
- Idempotent, converge-by-default; supports `--force` (stop model + force re-merge) and `--check`. The pinned checkout converges with `git fetch` + `checkout --force` (a dirty tree is reported first)
- ~97 GiB resident at the full auto KV pool / ~20 GiB idle with `KV_POOL_GB=0`. **Does not coexist with Flash Next at defaults** — use llama-swap's one-model-at-a-time swap. Co-loading needs reduced settings on one side and `TENSORFOLD_MEMORY_RESERVE_GIB=4` in `/srv/tensorfold-27b/.env` only: this recipe defaults to 0, while Flash Next already keeps 10 GiB (do not lower it — 4 there would weaken its admission floor). At defaults the 27B `auto` KV pool refuses to start rather than thrashing the host
- **Trust boundary:** llama-swap (root, systemd) execs `start.sh` and `prepare.sh` out of `/srv/tensorfold-27b`, so anyone who can write that checkout owns the host
- Shared logic: same `lib/tensorfold-helper.sh` as `setup-tensorfold-spark-qwen38-flash.sh` (pre-flight, the "what still needs downloading" gate, pinned checkout, `.env` render, catalog merge, llama-swap health-timeout bump / sync / smoke test, `--check` signals). The script keeps the recipe-specific constants and passes them in.

#### `setup-strix-halo-tuning.sh`
Prepares an **AMD Strix Halo** machine (Ryzen AI MAX+ 395 / Radeon 8060S / `gfx1151`) for large-model inference by writing the two drop-ins the models depend on: a GRUB drop-in `/etc/default/grub.d/99-kwisatz-strix-halo.cfg` carrying `amdgpu.gttsize` + `ttm.pages_limit` (the GPU aperture and the TTM pages that back it) plus the IOMMU/recovery arguments, and `/etc/sysctl.d/99-strix-halo-llm.conf` with `vm.swappiness`. **This is the only script in the repo that writes GRUB or sysctl** — by design, because nothing else in the tree touches the kernel command line, the blast radius is machine-wide, the "reboot required" message needs exactly one owner, and the two model tasks only *read* the result (they never run `update-grub` and never write `/etc/sysctl.d`). Writes nothing on a machine that fails the `gfx1151` gate.

**Features:**
- **One knob:** `GPU_RESERVE_GIB` (default `120`, flag `--reserve`) derives both kernel arguments, so the pair cannot drift apart. The pair is what matters: the model is paged into the aperture, and `gttsize` (MiB) and `ttm.pages_limit` (4 KiB pages) are read by two different subsystems. `--check` therefore has a dedicated `mismatched` state and reports it explicitly, because that is the failure that looks like "the model just crashes at 90 GB" rather than like a boot error. Do not replace the derived pair with the widely-copied `gttsize=131072` + `pages_limit=31457280`, which is 128 GiB of window against 120 GiB of pages
- Every drop-in is rendered from `templates/strix-halo-tuning/` with `envsubst` as the invoking user and installed with `sudo install -m 644`; `sudo envsubst` is never used. A re-render that matches the file on disk is a no-op, and a foreign file that was already there gets exactly one `.bak` (a re-run never buries it under `.bak.bak`)
- ZRAM swap is detected and disabled (`swapoff` + `systemctl mask` of whichever unit created it) because compressed RAM is the page pool on this part — paging weights in then competes with the model for the pages it is being paged into. A real swap partition is deliberately left alone, no package is ever removed, and what was found is printed
- `loginctl enable-linger` so the user's services survive logout; `vm.swappiness=10` for the same reason (`VM_SWAPPINESS`). Linger is per-account, so it follows `TUNING_USER` (defaults to the invoking user, `SUDO_USER` when the script is run with root privileges) rather than `id -un` — running the script through `sudo` would otherwise enable it for root and leave the operator's services dead after logout
- **Runs as the invoking user**, not as root: apt, `install`, `sysctl`, `swapoff`, `systemctl`, `loginctl`, `update-grub` are all `sudo`-wrapped. Privilege is settled in the first step before anything is written — an existing credential is reused, `sudo -v` asks once when a terminal is attached, and a run with no terminal stops with both remedies printed instead of hanging. `sudo -E ./script` works too (`SUDO_USER`-aware)
- Packages `rocm-smi`, `mesa-vulkan-drivers`, `linux-firmware` via `apt-get install --no-install-recommends`, skippable with `STRIX_INSTALL_PACKAGES=0` (warn-only); nothing is ever removed
- `--check` prints derived-vs-detected side by side (kernel, RAM, GPU reserve, memlock, swap, devices, memory budget) and the exact `sudo update-grub && sudo reboot` command. The reboot is the documented **non-convergeable** case: written-but-not-active prints the written-vs-active comparison and **exits 0**, and the model tasks refuse to start until it is done
- It never reboots, never prompts, and takes no `--interactive` flag in v1 — everything is either a re-render or a printed command. Env: `GPU_RESERVE_GIB`, `VM_SWAPPINESS`, `AMDGPU_EXTRA_ARGS`, `STRIX_INSTALL_PACKAGES`, `STRIX_HW_CHECK`, `TUNING_USER`

#### `setup-gufo-strix-halo-qwen38-flash.sh`
Deploys **Qwen3.8 Flash Next** on AMD Strix Halo via the **Gufo** inference engine (`ghcr.io/gufo-org/toolboxes/gufo-runtime`, tag `GUFO_IMAGE_TAG` default `0.8.1` — the registry publishes tags without a `v` prefix — plus the verified `GUFO_IMAGE_DIGEST`, which is what makes the reference immutable), **managed by llama-swap** (no standalone stack): `serve.cmd` runs `/srv/gufo-qwen38-flash/gufo-serve.sh` (a blocking `docker run --rm` on the host network), `cmdStop` stops the container, and requests are proxied from port 9292 to Gufo on `GUFO_FLASH_PORT` (default 8901). Weights come from `unsloth/Qwen3.8-Flash-Next-GGUF` (`UD-Q4_K_XL`: four shards under a `UD-Q4_K_XL/` directory, ~111 GB, plus `mmproj-BF16.gguf` for vision and `MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf` for speculation). Strix Halo is hard-required, and so is this task's tuning being **active**.

**Features:**
- **Gate order is the design**, cheapest first: docker → `envsubst`/`python3`+PyYAML/`hf` → llama-swap → the Strix Halo gate (the driver's KFD node reporting GC 11.5.1 / gfx1151, kernel ≥ 6.18.9, ≥ ~125 GiB RAM — no PCI device id is matched, since AMD ships the same IP under different ids) → the GPU-reserve state → dockerd's locked-memory limit → `/dev/kfd`/`/dev/dri` → zram. Only then "what still needs downloading" (weights by file presence, image by `docker inspect`), free disk **for the missing pieces only** (`STRIX_FLASH_MIN_FREE_GB=120`, `GUFO_IMAGE_GB=25`), and the `config.yaml` writability probe — so an untuned box and an unwritable catalog both fail in seconds, not after 115 GB
- `gufo-prepare.sh --list-files` is the **single source of truth for the weight file list**: the download gate probes it and the download loop runs it, so an upstream file rename cannot silently turn "cached" into "not cached" (and an unavoidable 115 GB re-download nobody can explain). Patterns, not filenames, so a sharded checkpoint needs no edit when upstream pushes another shard — and "the pattern matched" is not the answer: the gate reads the declared shard count out of the filename (`-N-of-M`) and requires the whole set, checked next to the file the glob matched, because a checkpoint that is 1-of-4 passes any glob and fails at load hours later with an error that mentions nothing about the missing shards. The same rule decides which snapshot is current: serve uses the newest **complete** one and says so when it passes over a part-fetched newer one
- `checkEndpoint: /v1/models`, **not** `/health`: Gufo opens its socket before the weights are resident, so "the port answers" is not readiness. The smoke test asks for 32 tokens, deliberately small enough not to trip a long-context engine bug, and distinguishes a proxy failure (llama-swap integration) from an engine failure (Gufo itself). `--skip-smoke` still proves `/health` and that `/v1/models` lists the id, and prints the "the model was not exercised" warning
- `GUFO_FLASH_HEALTH_TIMEOUT=1800` raises llama-swap's **global** `healthCheckTimeout` (per-model values are ignored by llama-swap, and the kwisatz template renders 500 s); `sync-models.py` restarts llama-swap only when its config changed, and the one case where the raise changed the file but the sync wrote nothing is restarted deliberately, with the stale-container hint printed
- **Engine version drift:** the image id is recorded in `/srv/gufo-qwen38-flash/.engine-version` after every run and compared on `--check`, so "the tag moved under you" is distinguishable from "you are still running what we installed". `GUFO_IMAGE_DIGEST` is what pins it. **Checkpoint revisions are recorded, not pinned** (`STATE_DIR/prepared`), with an advisory warning when upstream `main` moved — the same trade-off as the Spark 27B: a hard `--revision` in the download line would make a normal re-run re-fetch 115 GB after any upstream push
- Everything runtime lives in `/srv/gufo-qwen38-flash/.env` (mode 600): ports, paths, the engine ref, `HSA_OVERRIDE_GFX_VERSION=11.5.1` / `HSA_ENABLE_SDMA=0` (gfx1151 is not in ROCm's autodetect table), `GUFO_SESSIONS`, `GUFO_CACHE_DISK_STAGING_BYTES` (off by default — 8 GiB resident this machine would rather give the model), and the escape hatches `GUFO_EXTRA_ARGS` / `GUFO_SPEC_ARGS` / `CONTAINER_EXTRA_ARGS`. `GUFO_ENTRYPOINT` names the binary for the `--entrypoint` flag (the pinned runtime ships *without* one — `serve llm …` would be exec'd as a command and die in runc with `exec: "serve": executable file not found`), and `GUFO_GPU_GROUP` is the supplementary group passed to the container for the GPU device nodes (default: the numeric gid of `/dev/kfd`; the image's user is in no group, and without it HIP reports the misleading "no ROCm-capable device is detected"). A re-run re-renders the keys it owns and carries every line you added over verbatim; nothing secret is ever substituted into a generated file (`HF_TOKEN` is referenced from `.env`, never baked into a wrapper)
- **Speculation ships on** for this model (`GUFO_SPEC_ARGS='--speculative mtp'`, upstream's validated recipe with the shared-`Q8_0` sidecar), and the *path flag is derived from the backend named in `GUFO_SPEC_ARGS`*: `--speculative mtp` → `--mtp-model`, `dflash2` → `--dflash-model`, `dspark` → `--dspark-model`, with the resolved snapshot path inside the HF cache appended. The wrapper never guesses a spelling it cannot check, because Gufo exits 2 on an unknown option — a wrong pair is a container that will not start, not a slow model. `GUFO_SPEC_ARGS=` turns it off. Nothing exports the path as `GUFO_DRAFT_MODEL`: the engine reads no such key, and a variable that looks authoritative is the worst kind of documentation
- Coexistence is an aperture question, not a disk question: both stacks at `UD-Q4_K_XL` is 119.9 GiB of weights against a 120 GiB reserve, which is not tight — it does not fit. What fits is this stack at `UD-IQ4_XS` (93.7 GB) beside the 27B (17.6 GB), leaving ~16 GiB for KV cache and sidecars; otherwise load one at a time through llama-swap. `--check` prints the arithmetic (in GiB, because the reserve is counted in GiB) and a `Sibling:` line when the other stack is installed (and prints nothing when it is not)
- Model id `qwen3.8-flash-next-gufo`, aliases `Qwen3.8-Flash-Next-GGUF` / `qwen3.8-flash-gufo`; `--served-model-name` is the catalog id. No case-only alias, and `qwen3.8` / `Qwen3.8-Flash-Next` stay with the TensorFold entry. **Known limitation:** llama-swap rewrites the request's `model` to the served name, so the response's `model` field is not necessarily the id you asked for
- Flags `--port`, `--health-timeout`, `--dir`, `--hf-cache`, `--state-dir`, `--quant`, `--force`, `--skip-smoke`, `--check`, `--help`; `--port 8902` or a changed `--dir` does *not* rewrite an existing llama-swap entry (add-only sync) even though `models.yml` is updated — the documented fix is to delete the model's section from `/srv/llama-swap/config/config.yaml` and re-run
- **Trust boundary:** llama-swap (root) execs `gufo-serve.sh` out of `/srv/gufo-qwen38-flash`, so anyone who can write that directory owns the host. The wrappers are rendered from this repo, are mode 0755, and carry no secrets
- Shared logic: `lib/strix-halo-helper.sh` holds what both Strix tasks run identically (hardware/kernel/RAM gates, the GPU-reserve state machine, the download gate, the engine pull, wrapper/`.env` render, the catalog round-trip, the smoke test, the `--check` vocabulary). It deliberately does *not* share functions with `lib/tensorfold-helper.sh` — the two stacks have no validated shared path yet, so copies say so at the copy site instead of coupling

#### `setup-gufo-strix-halo-qwen38-27b.sh`
Deploys **Qwen3.8-27B** on AMD Strix Halo via **Gufo**, **managed by llama-swap** (no standalone stack): `serve.cmd` runs `/srv/gufo-qwen38-27b/gufo-serve.sh` (blocking `docker run --rm`, host network), `cmdStop` stops the container, requests are proxied from 9292 to Gufo on `GUFO_27B_PORT` (default 8902 — Flash Next holds 8901). Weights come from `unsloth/Qwen3.8-27B-GGUF` (`UD-Q4_K_XL`, 17.6 GB / 16.4 GiB) with `mmproj-BF16.gguf`, plus the DFlash2 draft from `z-lab/Qwen3.8-27B-DFlash2-GGUF` (`Q4_K_M`). Same shape and same library as the Flash-Next task; the two differ only in constants.

**Features:**
- Same gate order, same single-source weight list, same `/v1/models` readiness endpoint, same recorded-not-pinned revisions and engine-version drift reporting, same converge-by-default re-run policy — see `setup-gufo-strix-halo-qwen38-flash.sh` above; nothing here is different except the numbers
- `GUFO_27B_MIN_FREE_GB=45` / `GUFO_IMAGE_GB=25` for a cold install; `GUFO_27B_HEALTH_TIMEOUT=600`
- **Speculation is on by default here** (`--speculative dflash2`), because that is the configuration the ~70 tok/s single-user / ~123 tok/s at 8 users numbers were measured with. It is still one `.env` line away from being off (`GUFO_SPEC_ARGS=`), so a Gufo bump that renames the flag costs speed rather than an outage
- The draft lives in a **different repo** than the weights, so the file list is `(repo, pattern)` pairs rather than a flat list, and `gufo-serve.sh` resolves the draft's snapshot inside the HF cache — the container mounts the *whole cache read-only at its own host path* (HF snapshot files are relative symlinks into `../../blobs/`, so mounting only the snapshot directory leaves every weight file dangling), which covers weights and draft with the same mount, and copying the draft under `/models` would put a second ~2 GB under the service dir and break "weights live in the user's cache"
- Model id `qwen3.8-27b-gufo`, alias `Qwen3.8-27B-GGUF`. Deliberately *not* aliased: `qwen3.8-27` (TensorFold 27B), `qwen3.8` (TensorFold Flash-Next), and `Qwen3.8-27B` — which lower-cases straight onto the llama.cpp entry `qwen3.8-27b`, where a client that normalises model names would silently land. That llama.cpp entry is also expected to be the *unreliable* one on this hardware: `models.yml.default` ships it with `--spec-type draft-mtp` and without `-fa 1` / `--no-mmap` / `-ngl 999`, which is the configuration the Strix Halo threads report as hitting the RADV device-lost failure. Making that entry Strix-safe is a separate, hardware-independent change, not this task's
- Coexistence: this stack is the comfortable half (16.4 GiB), so it is the one to keep resident when both are installed — and "both resident" still means Flash-Next at `UD-IQ4_XS`, since both at `UD-Q4_K_XL` fills the aperture. `--check` prints the `Sibling:` line and the memory budget for exactly that decision
- Flags and env: `--port`, `--health-timeout`, `--dir`, `--hf-cache`, `--state-dir`, `--quant`, `--force`, `--skip-smoke`, `--check`, `--help`; `GUFO_27B_PORT`, `GUFO_27B_HEALTH_TIMEOUT`, `PROJECT_DIR`, `HF_CACHE_DIR`, `STATE_DIR`, `GUFO_IMAGE`/`GUFO_IMAGE_TAG`/`GUFO_IMAGE_DIGEST`, `GUFO_MODEL_REPO`, `GUFO_MODEL_REVISION`, `GUFO_QUANT`, `GUFO_DRAFT_REPO`, `GUFO_SPEC_ARGS`, `GUFO_ENTRYPOINT`, `GUFO_GPU_GROUP` (the serve `.env` levers, see the Flash-Next section), `STRIX_27B_MIN_FREE_GB`, `GPU_RESERVE_GIB` (read-only here), `STRIX_ALLOW_UNTUNED`, `STRIX_HW_CHECK`, `STRIX_SIBLING_DIR`
- **Trust boundary:** llama-swap (root) execs `gufo-serve.sh` out of `/srv/gufo-qwen38-27b`, so anyone who can write that directory owns the host. The sibling cross-check (`STRIX_SIBLING_DIR`, default `/srv/gufo-qwen38-flash`) reports a port collision, a duplicate model id, and "both installed" once each on install and on `--check` — and prints nothing when only one stack is present

#### `setup-omnivoice.sh`
Builds the OmniVoice.cpp `tts-server` (an OpenAI-compatible text-to-speech HTTP server) from source for the detected GPU backend (Vulkan / CUDA / CPU) and runs it as a native systemd service under a dedicated non-root user. There is no official Docker image, so the single self-contained binary is built from source and installed to `/usr/local/bin`. Models come from the non-gated `Serveurperso/OmniVoice-GGUF` repo (no HF token needed). Defaults to a loopback bind (the server has no TLS/auth); a non-loopback bind adds a UFW rule. A bounded `GET /health` gate proves the stack is up before reporting success.

**Features:**
- Auto-detects the GPU backend (Vulkan / CUDA / CPU) and builds with the matching `buildvulkan.sh` / `buildcuda.sh` / `buildcpu.sh`
- OpenAI-compatible TTS API: `POST /v1/audio/speech`, `POST`/`GET`/`DELETE /v1/audio/voices`, `GET /v1/models`, `GET /health`
- Non-root `omnivoice` service user with GPU (`render`/`video`) group membership for Vulkan
- Models under `/srv/omnivoice/models`, build source kept under `/srv/omnivoice/src` for rebuilds
- Converging re-runs: models never re-downloaded, build skipped unless the binary/ref/backend changed, service restarted only when the rendered unit changed
- `--check`, `--force`, `--interactive`; key env vars: `OMNIVOICE_BACKEND`, `OMNIVOICE_PORT`, `OMNIVOICE_HOST`, `OMNIVOICE_BASE_MODEL`, `OMNIVOICE_TOKENIZER_MODEL`, `OMNIVOICE_REF`

#### `setup-omnigent.sh`
Deploys Omnigent — an open-source meta-harness providing a common orchestration layer over multiple AI coding agents (Claude Code, Codex, Cursor, Pi, etc.) — via Docker Compose with Postgres + FastAPI. Also installs the runner CLI (`omnigent`) on the host for local agent execution.

**Features:**
- Docker Compose deployment with Postgres backend
- Runner CLI installed on host for local agent execution
- Optional Traefik reverse-proxy integration
- Auto-generated secure secrets in `.env` file
- Health check polling (up to 120s)
- UFW firewall rule configuration (direct mode)

#### `setup-agent-docker-runner.sh`
Installs the Agent Docker Runner (ADR) CLI, a tool that runs coding agents inside isolated Docker containers with a single command. Supports multiple agents: pi, opencode, claude, codex.

**Features:**
- Runs any supported agent in isolated Docker containers
- Single CLI command: `adr run <agent> -- <args>`
- Auto-builds container images for all agents
- Configuration examples included
- Supports pi, opencode, claude code, and GitHub Copilot Workspace (codex)

#### `setup-nanobot.sh`
Clones the Nanobot agent repository, builds the Docker image, and runs the onboarding flow.

#### `setup-hermes.sh`
Installs Hermes Agent natively inside a dedicated KVM virtual machine created with virt-runner. The VM is the sandbox: Hermes gets a whole machine (local terminal backend, passwordless sudo) while the host controls what the VM may reach. Re-running converges the existing VM; it is never destroyed or re-created.

**Features:**
- Runs `setup-virtualization.sh` / `setup-virt-runner.sh` automatically when the prerequisites are missing
- Ubuntu guest (default 4 GB RAM, 2 vCPU, 50 GB disk) with a static address on the libvirt `default` network
- Official Hermes installer at a pinned commit (`HERMES_COMMIT`), gateway as a systemd user service
- Host-enforced egress allowlist (`HERMES_ALLOWED_ENDPOINTS`, e.g. `"host:3000 192.168.1.20:8080-8090"`): internet open, listed LAN/host endpoints allowed, all other private addresses blocked
- Optional `hermes serve` for Hermes Desktop / the dashboard on the LAN (`HERMES_SERVE=true`, `HERMES_SERVE_ALLOW_FROM`), optionally behind Traefik (`HERMES_TRAEFIK=true`, `HERMES_DOMAIN`)
- Connects the main model to your own OpenAI-compatible LLM endpoint — llama-swap / vLLM / llama.cpp-server (`HERMES_LLM_BASE_URL`, `HERMES_LLM_MODEL`, optional `HERMES_LLM_API_KEY`): provider `custom` (plain chat-completions wire, key read via `model.key_env=OPENAI_API_KEY`), base URL and model converged on every re-run; the endpoint is auto-added to the egress allowlist when it is on this host or another IPv4, and the API key is stored only inside the guest (`~/.hermes/.env`, never rotated)
- Host shares: `/srv/hermes/workspace` → `/workspace`, `/srv/hermes/backups` → `/mnt/backups` (daily `hermes backup` zips + a plain-text config mirror in `/srv/hermes/backups/current/`); Hermes state (SQLite) stays on the VM disk
- Host-backup ready: everything under `/srv/hermes` — live workspace, daily backup archives, and the `current/` config mirror (config.yaml, .env, SOUL.md, memories/, skills/, cron/, hooks/, skins/) — is inside the default scope of `setup-backup-client.sh` (borg). Full restores use the newest archive via `hermes import`; `current/` is for browsing and single-file recovery without extracting an archive
- The gateway service runs from the first install on; configure it with `virt-runner ssh hermes`, `hermes setup`, `hermes gateway restart`
- Needs a virt-runner with `create --mount` (currently its `develop` branch: `VIRT_RUNNER_BRANCH=develop`)
- Migration from the former Docker-based setup: `docs/hermes-docker-to-vm-migration.md` (manual, one-off)

#### `setup-unsloth.sh`
Installs **Unsloth Studio** (the browser-based web UI for running and training AI models) and optionally the **Unsloth Desktop** native app. Studio is installed by default; Desktop requires `UNSLOTH_INSTALL_DESKTOP=true`. Optionally runs Studio as a systemd service (`UNSLOTH_INSTALL_SERVICE=true`).

**Features:**
- Browser-based web UI accessible at `http://localhost:8888` by default
- Runs and trains LLMs, diffusion image/video, GGUF, and audio models
- Native Desktop app (optional) for macOS, Windows, and Linux
- Optional systemd service (`UNSLOTH_INSTALL_SERVICE=true`) for persistent background operation
- Supports Python version pinning (`UNSLOTH_PYTHON`), GGUF-only mode (`UNSLOTH_NO_TORCH`), and custom install directory (`UNSLOTH_STUDIO_HOME`)
- Downloads installer script to a temp file before execution (never pipes curl to bash directly)

**Environment variables (all optional):**
- `UNSLOTH_INSTALL_DESKTOP` — Install Unsloth Desktop app (`false` by default, set to `true` or `1`)
- `UNSLOTH_INSTALL_SERVICE` — Install Unsloth Studio as systemd service (`false` by default, set to `true`)
- `UNSLOTH_STUDIO_USER` — Runtime user for systemd service (defaults to `$USER`)
- `UNSLOTH_STUDIO_PORT` — Port for Unsloth Studio (`8888` by default)
- `UNSLOTH_STUDIO_BIND` — Bind address (`127.0.0.1` by default)
- `UNSLOTH_STUDIO_HOME` — Custom install directory (`/srv/unsloth` by default)
- `UNSLOTH_PYTHON` — Pin Python version for Unsloth (auto by default)
- `UNSLOTH_NO_TORCH` — Skip PyTorch for GGUF-only mode (`false` by default)

**Usage examples:**
```bash
# Studio only (default)
./tasks/setup-unsloth.sh

# Studio + Desktop
UNSLOTH_INSTALL_DESKTOP=true ./tasks/setup-unsloth.sh

# Studio + systemd service
UNSLOTH_INSTALL_SERVICE=true ./tasks/setup-unsloth.sh

# Studio + Desktop + systemd service
UNSLOTH_INSTALL_DESKTOP=true UNSLOTH_INSTALL_SERVICE=true ./tasks/setup-unsloth.sh

# Custom port, bind to all interfaces
UNSLOTH_STUDIO_PORT=9000 UNSLOTH_STUDIO_BIND=0.0.0.0 ./tasks/setup-unsloth.sh
```

---

#### `setup-pi.sh`
Installs the latest Node.js via nvm and the **Pi coding agent** npm package globally.

#### `setup-ai-agent-skills.sh`
Installs the **AI agent skills stack** for a target user from the `ai_agent_skills` repo: ensures a local clone (clone / fast-forward pull, plain `fetch` fallback on local changes), installs selected pi skills into `~/.pi/agent/skills/` via the repo's `install-skill.sh`, installs agent profiles into `~/.pi/agent/agents/` via `install-agent.sh` (all or named; `*.chain.md` files are skipped by the repo tooling), and installs the herdr-cli helper scripts (`runagent`, `agent_profile.py`, `run-*-herdr.sh`, `pipeline-herdr.sh`, sourced `herdr-common.sh`) into `~/.local/bin` — rewritten only when content changed, `herdr-common.sh` kept non-executable. Verified with `runagent --list`. Idempotent; runs via `sudo -u <user>` when invoked as root for another user. Prerequisites (documented, not checked): `setup-basics` (herdr), `setup-pi` (pi), `setup-agent-sandbox` (asb). Env: `AI_SKILLS_REPO_URL` (default `ssh://git@192.168.178.57:2223/denkfabrik/ai_agent_skills`), `AI_SKILLS_USER` (default: current user), `AI_SKILLS_DIR` (default `~/skills/ai_agent_skills`), `AI_SKILLS_TO_INSTALL` (default `herdr-cli pi-cli ponytail karpathy-guidelines`), `AI_AGENTS_TO_INSTALL` (default `all`).

#### `setup-agentsview.sh`
Installs **agentsview** (local viewer for AI coding-agent session logs) as the pinned release binary (default `0.44.0`, sha256-verified against the release `SHA256SUMS`) in `~/.local/bin` and writes `~/.agentsview/config.toml` (mode 600) with update checks disabled; anonymous telemetry is disabled via `AGENTSVIEW_TELEMETRY_ENABLED=0` (env-only setting) in `~/.profile` and the service unit. Also installs the systemd **system** service `agentsview.service` running the agentsview server (web UI + API + background sync, `agentsview serve`) on `AGENTSVIEW_PORT` (default `7777`) bound to `AGENTSVIEW_HOST` (default `0.0.0.0`); the config gets `require_auth = true` with a generated bearer token (agentsview has no env-var for it, so it lives in `config.toml`; read back on re-runs, never rotated, printed in the summary), a bounded `/api/v1/stats` health gate runs after (re)start, and a UFW inbound rule is added when bound to a non-loopback address. The unit runs as the invoking user (`SUDO_USER`-aware) so that user's agent logs get indexed; re-runs converge (unit re-applied + service restarted only when the rendered unit changed). Sudo prompts interactively where needed (passwordless sudo not required; `lib/helpers.sh` ufw helpers fall back to interactive sudo when a TTY is present). Modes: **local** (default; agentsview auto-detects `~/.claude/projects`, `~/.codex/sessions`, `~/.local/share/opencode`, `~/.pi/agent/sessions`, ...) and **hub** (`AGENTSVIEW_SESSION_SOURCES='agent|dir|machine-id;...'` renders `[[session_sources]]` for directories synced from other machines). With `AGENTSVIEW_PG_URL` set, installs a systemd **user** unit `agentsview-pg-push.service` (`agentsview pg push --watch`); the URL lives only in `~/.agentsview/pg.env` (mode 600, read back on re-runs). An existing `config.toml` is not overwritten unless `AGENTSVIEW_FORCE_CONFIG=true` (diff is shown). Other env: `AGENTSVIEW_VERSION` (`latest` allowed), `AGENTSVIEW_BIN_DIR`, `AGENTSVIEW_DATA_DIR`, `AGENTSVIEW_MACHINE_NAME`, `AGENTSVIEW_PORT`, `AGENTSVIEW_HOST`, `AGENTSVIEW_HEALTH_TIMEOUT` (default `120`). Insight generation (optional, off by default): `AGENTSVIEW_INSIGHTS_URL` + `AGENTSVIEW_INSIGHTS_MODEL` render an `[insights]` block so `agentsview insight generate` calls that OpenAI-compatible endpoint instead of a cloud provider (URL without model is an error — agentsview requires both together); `AGENTSVIEW_INSIGHTS_API_KEY` goes to `~/.agentsview/insights.env` (mode 600, read back on re-runs, never rotated) while config.toml only names the variable (`api_key_env`), because that key resolves against the **daemon's** environment — the unit sources the file via `EnvironmentFile=-…/insights.env`, the same pattern as `pg.env`; `AGENTSVIEW_INSIGHTS_TIMEOUT` defaults to `300s` (llama-swap model loading alone can take ~2 min). `allow_http = true` is derived from the URL when it is plain `http://` on a non-loopback host and is then reported as a warning (unencrypted transcript content); `AGENTSVIEW_HOST=127.0.0.1` is recommended for insight-only hosts since generation never needs a remote API. An existing config.toml is not rewritten, so enabling insights on an already-configured host needs `AGENTSVIEW_FORCE_CONFIG=true` (the run detects this case and says so). Research: `docs/research/agentsview.md`.

#### `setup-agent-sandbox.sh`
Configures the **bubblewrap (bwrap) sandboxing prerequisites** on the host so sandboxed coding-agent runs work out of the box on Ubuntu 24.04+: installs `bubblewrap`, lifts the AppArmor "unprivileged userns" restriction **for bwrap only** (one-file profile `/etc/apparmor.d/bwrap`, skipped when AppArmor is inactive), hard-verifies bwrap with a bounded smoke test, and installs the **`asb` wrapper** to `/usr/local/bin/asb` (verified with a real sandboxed one-shot). `asb` runs `pi`/`opencode` (or a bare `sh`) in a bwrap sandbox where the workspace is the only general writable path (agent state dirs `~/.pi`/`~/.local/share/opencode` are mounted rw because agents write sessions/logs there; `~/.local/bin`, `~/.config/opencode` and system dirs are read-only), env is cleared to an allowlist, herdr integration is preserved (`HERDR_*` forwarding, socket bind, `HERDR_AGENT` hint), and symlinked skills/prompts/commands in the agent's state dirs (pi/opencode/claude/codex, incl. `~/.agents/skills`) get their resolved targets bound read-only so linked skill repos keep working (dangling links are skipped). Idempotent; env: `SANDBOX_APT_PACKAGES` (default `bubblewrap`), `BWRAP_VERIFY_TIMEOUT` (default `15`).

#### `sync-models.py`
Python tool (entrypoint + `sync_models/` package) implementing the declarative **model catalog**: downloads local model weights via the `hf` CLI (`--dry-run` probe, idempotent `--local-dir` mode, disk-space warning), additively appends missing model entries to the llama-swap `config.yaml` (existing entries and all other sections are never modified), restarts llama-swap only when the config changed and polls `/health` afterwards, and merges catalog providers/models into `~/.pi/agent/models.json` and `~/.config/opencode/opencode.json` (add missing, fix managed fields, touch nothing else). Strictly additive and idempotent. Catalog resolution: `MODELS_YML` → `models.yml` (gitignored) → `models.yml.default`; env vars `LLAMA_SWAP_CONFIG`, `PI_MODELS_JSON`, `OPENCODE_CONFIG`, `LLAMA_SWAP_HEALTH_TIMEOUT`; flags `--no-restart`, `--agents pi,opencode`.

**Known limitation:** the download probe appends `--dry-run` to each command and parses the output. The upstream TensorFold recipes' `scripts/prepare.sh` reject unknown arguments, so those two entries always probe "unparseable" and sync runs the real command (conservative by design, and a cheap no-op while the recipe's own `.prepared` marker is present). It only costs a log line plus the probe's own disk-space estimate; the TensorFold scripts do their own presence-then-disk gate. Supporting it needs `--dry-run` in the recipes or a probe-less download command in the spec — neither is a one-liner here.

#### `setup-deepseek-harness.sh`
Installs **DeepSeek Harness** (`dsh`) — an open-source agent harness from DeepSeek AI with a plugin-first architecture. Ensures NVM + Node.js 22.19+ are available, then installs `dsh` globally. Run `dsh web` afterwards for the Web UI at `http://127.0.0.1:3080`.

---

### Speech & Dictation

#### `setup-whispering.sh`
Downloads the Whispering speech-to-text AppImage, creates a start script (`~/whispering`) and a desktop shortcut. Backs up any existing binary before downloading.

#### `setup-music-gen.sh`
Installs **ACE-Step 1.5** (MIT) — a text-to-song generator with vocals/lyrics — natively under systemd (`ace-step.service`, async REST API on port 9294). Pinned to upstream git tag `v0.1.8` via `ACESTEP_VERSION` — ACE-Step 1.5 is published under `v0.1.x` tags (there is no `v1.5` tag). GPU vendor auto-detect: AMD ROCm hosts (gfx1151 — docker deliberately not used there, ROCm/userland matching) get ROCm torch wheels, NVIDIA hosts (e.g. DGX Spark) get CUDA wheels (`MUSIC_GEN_GPU_VENDOR`/`MUSIC_GEN_TORCH_INDEX`, cu128 default on arm64). Preview mode installs a CPU-only musicgen-small CLI (`~/music-preview`) for non-GPU boxes; the instrumental MusicGen service (:9293) remains the separate vault plan. ROCm pitfalls embedded: no `HSA_OVERRIDE_GFX_VERSION` on gfx1151 ("no matching kernel image"), `ACESTEP_LM_BACKEND=pt` (vLLM is CUDA-only), and WAV/FLAC output only — MP3 export is broken on ROCm builds.

---

### Project Management & Collaboration

#### `setup-forgejo.sh`
Installs Forgejo (a Gitea fork) as a Docker container. Supports optional Traefik reverse-proxy integration via `FORGEJO_TRAEFIK_ENABLED`.

#### `setup-planka.sh`
Installs Planka, a self-hosted Kanban board, via Docker Compose with PostgreSQL. Auto-generates a secret key and supports interactive or headless admin user creation.

#### `setup-postiz.sh`
Deploys **Postiz** (self-hosted social-media scheduler, 28+ platforms) via Docker Compose: Postiz app + PostgreSQL + Redis + the full Temporal stack (auto-setup, PostgreSQL, Elasticsearch, UI) — Postiz v2.12+ requires Temporal for cron/scheduled posting. Based on the official `gitroomhq/postiz-docker-compose` compose, slimmed (no `spotlight` debug profile, no `temporal-admin-tools` tty container; `docker exec -it temporal temporal …` covers CLI needs).

**Features:**
- Pinned immutable images (`ghcr.io/gitroomhq/postiz-app:v2.24.0`, `postgres:17-alpine` for the Postiz DB, `postgres:16` for the Temporal DB, `redis:7.2`, `elasticsearch:7.17.27`, `temporalio/auto-setup:1.28.1`, `temporalio/ui:2.34.0`)
- Direct mode: publishes `HTTP_PORT` (default `4007`); opt-in Traefik mode (`POSTIZ_TRAEFIK=true POSTIZ_DOMAIN=…`) removes the port and routes via `PROXY_NETWORK` (default `proxy`) with Let's Encrypt TLS
- Secrets (`JWT_SECRET`, `POSTGRES_PASSWORD`, `TEMPORAL_POSTGRES_PASSWORD`, optional `OPENAI_API_KEY`) auto-generated on first run, stored in `/srv/postiz/.env` (mode 600), reused on re-runs (never rotated); the compose file keeps only literal `${VAR}` placeholders resolved at runtime via `--env-file`
- Temporal debug ports loopback-only (`127.0.0.1:7233`, Temporal UI on `127.0.0.1:18080`)
- **Admin bootstrap (API):** the script creates the first organization + SUPERADMIN user via `POST /api/auth/register` (login-first on re-runs, idempotent; Postiz has no seed mechanism — `docs/research/postiz-auto-config-2026-09-30.md`), stores the org's auto-generated public API key as `POSTIZ_API_KEY` in the `.env`, and locks public signup afterwards (`POSTIZ_DISABLE_REGISTRATION=true` default — Postiz still allows exactly the first registration while the org count is 0)
- Direct mode sets `NOT_SECURED=true`: over plain HTTP the auth cookie would otherwise be flagged `Secure` and browsers drop it (login 200 but no session)
- Re-runs converge: re-render, reuse secrets, `docker compose up -d`, `wait_for_healthy` gate (`WAIT_TIMEOUT` default `300` — ES+Temporal are slower than the 180 s house default) + HTTP readiness poll
- Post-install checklist printed at the end (login with the admin user, platform integrations, MCP server wiring) — social-platform OAuth credentials are UI-owned, never in the compose/env template

**Env:** `POSTIZ_HOME` (`/srv/postiz`), `HTTP_PORT` (`4007`), `POSTIZ_TRAEFIK`/`POSTIZ_DOMAIN`/`PROXY_NETWORK`, `POSTIZ_HOST_IP`, `POSTIZ_IMAGE` + the Temporal-stack image vars, `TEMPORAL_UI_PORT` (`18080`), `WAIT_TIMEOUT` (`300`), `OPENAI_API_KEY`, `POSTIZ_DISABLE_REGISTRATION` (`true`), `POSTIZ_ADMIN_EMAIL` (machine user's email), `POSTIZ_ADMIN_ORG` (`my organization`), `POSTIZ_ADMIN_PASSWORD` (auto-generated, in the `.env`).

> **Upgrade procedure:** bump `POSTIZ_IMAGE` to the newest GHCR release tag and re-run the script (or `docker compose --env-file /srv/postiz/.env -f /srv/postiz/docker-compose.yml pull && up -d` in `/srv/postiz`) — Postiz migrations run on boot. Plan: `docs/plans/postiz-setup.md`.

---

### Communication

#### `setup-matrix.sh`
Deploys a private, self-hosted **Matrix** team chat behind the shared Traefik proxy: Synapse + PostgreSQL 17 + Matrix Authentication Service (MAS) + Element Web + `.well-known` delegation. Operator and team guide: [README_MATRIX.md](README_MATRIX.md).

**Features:**
- `MATRIX_SERVER_NAME` (required, **immutable** after the first run — a different value is a hard error) → hosts `matrix.` (Synapse), `auth.` (MAS), `chat.` (Element Web), `rtc.` (calls), `admin.` (admin UI) under it by default
- MAS always on: Element X login/QR login, invite-only accounts (`mas-cli manage register-user`), first admin created at first install
- Private by default (`MATRIX_FEDERATION=false`, no port 8448); `true` federates via `.well-known` delegation on :443
- Optional components as compose profiles (stored in `.env`): `MATRIX_RTC=true` (voice/video calls: LiveKit SFU + lk-jwt-service, publishes 7881/tcp + 7882/udp, UFW rules), `MATRIX_ADMIN_UI=true` (Ketesa, LAN/VPN allowlist), `MATRIX_WELLKNOWN=traefik|synapse|external`, `MATRIX_METRICS=true` (Prometheus labels)
- Secrets generated once into `/srv/matrix/.env` (mode 600), never rotated; Synapse/MAS read them from mode-600 files (`*_path` / `*_file`), the DB passwords via `PGPASSWORD` — no secret in any generated config except the documented lk-jwt appservice registration
- Signing keys (Synapse, MAS) generated once, never overwritten
- Converges on re-run (toggles, domains, image bumps); changed config files restart only their service; `/_synapse/admin` is never public (`MATRIX_ADMIN_ALLOW_CIDRS`)
- Backup integration: `--services matrix` dumps both databases (`synapse`, `mas`) and archives the server identity (`.env`, signing key, secrets) as `matrix-<ts>.identity.tar`; `restore-db` re-creates both databases with C collation

### CI/CD

#### `setup-concourse.sh`
Deploys **Concourse CI** (web, TSA, worker, PostgreSQL) with Docker Compose, generates TSA/session/worker keys, and configures a `fly` CLI target. Supports direct port exposure or Traefik reverse-proxy integration.

#### `setup-dagu.sh`
Deploys **Dagu** (self-hostable workflow orchestrator) via Docker Compose. The host Docker socket is mounted so workflows can run container steps. No Traefik integration — accessed via configurable bind address.

**Features:**
- DAG-based workflow orchestration (alternative to Airflow/Cron)
- Web UI for managing and monitoring DAGs
- Host Docker socket mounted for container steps
- Shared volume at `./data` including `./data/dags` for workflow definition files (`.dagu.yml`)
- Builtin RBAC authentication with auto-generated credentials
- Data persisted in a named Docker volume

> **Note:** The Docker socket grant means workflows can control the host Docker daemon. Use only for trusted workflows. The admin password is stored in `/srv/dagu/.env` (mode 600).

#### `setup-kestra.sh`
Deploys **Kestra** (event-driven workflow & orchestration platform) in standalone mode via Docker Compose with a dedicated PostgreSQL backend. Supports direct port access (bound to a configurable IP, default `127.0.0.1:8084`) or opt-in Traefik reverse-proxy integration with TLS.

**Features:**
- Standalone Kestra (`server standalone`) with Postgres backend for repository, queue and data
- Pinned immutable images (`kestra/kestra:v2.0.0`, `postgres:16`) — Kestra recommends exact `v<X.X.X>` tags for production; Postgres is pinned to avoid major-version data-dir incompatibility
- Basic-auth credentials and Postgres password auto-generated on first run, stored in `/srv/kestra/.env` (mode 600), reused on re-runs (never rotated); the compose file keeps only literal `${VAR}` placeholders resolved at runtime
- Host Docker socket mounted for Kestra docker script tasks (trusted workflows only)
- Re-runs converge: re-render, reuse secrets, `docker compose up -d`

> **Note:** The Docker socket grant means Kestra workflows can control the host Docker daemon. Use only for trusted workflows.

---

### Storage & File Sharing

#### `setup-nextcloud.sh`
Deploys Nextcloud, a self-hosted file sync and collaboration platform, via Docker Compose. Supports optional Traefik reverse-proxy integration for secure HTTPS access.

**Features:**
- Production stack: `nextcloud:34-apache` + PostgreSQL + authenticated Redis + cron sidecar
- Redis provides distributed caching and transactional file locking (mandatory for production)
- Traefik mode (HTTPS, HTTP→HTTPS redirect, `.well-known` DAV redirect, HSTS) or LAN/direct mode with UFW rule
- Secrets in `/srv/nextcloud/.env` (mode 600), generated once and never rotated; the compose file keeps only literal `${VAR}` tokens
- PostgreSQL-only backend; existing MariaDB/SQLite installs are refused up-front
- Pinned images — update Nextcloud deliberately, one major at a time (33 → 34 → 35)
- Backup integration: `setup-backup-server.sh --services nextcloud` (`pg_dump -Fc` + data copy)

#### `setup-n8n.sh`
Deploys n8n, a workflow automation platform, via Docker Compose with PostgreSQL backend. Supports optional Traefik reverse-proxy integration for secure HTTPS access.

**Features:**
- Visual workflow builder with 200+ integrations
- Self-hosted with full data control
- Supports webhooks, schedules, and triggers
- PostgreSQL backend for persistence
- Optional Traefik reverse-proxy integration

#### `setup-samba.sh`
Installs and configures Samba file sharing.

---

### Graphics & Whiteboarding

#### `setup-excalidraw.sh`
Pulls and runs the Excalidraw virtual whiteboard as a Docker container with an `always` restart policy.

---

### Remote Access & Desktop

#### `setup-anydesk.sh`
Installs AnyDesk remote desktop from the official apt repository.

#### `setup-brave.sh`
Installs the Brave browser from its official apt repository.

#### `setup-netbird.sh`
Deploys self-hosted NetBird (a WireGuard-based mesh VPN) as Docker containers: the combined server (management + signal + relay + embedded STUN + embedded IdP) and the dashboard, routed through the Traefik reverse proxy (installed via `setup-traefik.sh` first when it is not running), plus an optional routing-peer client for LAN exposure.

**Network requirements** (router port forwarding to the server):
- `443/tcp` → Traefik: dashboard, API, gRPC, relay and login (HTTPS)
- `80/tcp` → Traefik: Let's Encrypt HTTP challenge and HTTPS redirect (not needed with the DNS challenge, `DNS_PROVIDER=cloudflare`)
- `3478/udp` (`STUN_PORT`) → STUN, published directly because it cannot go through Traefik; without it NetBird still works, but more peer connections fall back to the relay instead of going peer to peer
- `NETBIRD_DOMAIN` must resolve publicly to the router's external IP (use dynamic DNS if that IP changes)
- No UDP port range is needed and clients need no inbound ports; behind carrier-grade NAT (no public IPv4) port forwarding cannot make the server reachable

**Routing peer (`NETBIRD_CLIENT_ENABLED=true`)** — the container that forwards the LAN into the mesh:
- Create a **reusable** setup key (Settings → Setup Keys, auto-assign the `Routing Peers` group). The key enrolls the peer once; its identity then lives in the `netbird-client` volume, so a re-run only needs it for a new peer or after a session expiry. The stack's own `NETBIRD_SETUP_KEY` is not a client variable — the client's env name is `NB_SETUP_KEY`, which the 0.77.x client does read (`docs/research/netbird-setup-review-2026-10-03.md` claimed otherwise; corrected 2026-10-21) — so the container passes the key as an explicit `netbird up --setup-key` flag.
- The script fails (not warns) if the peer is not authenticated: `netbird status --check ready` must go through before success is reported.
- `Signal:` must read **Connected** and `Relays: n/n` non-zero in `docker exec netbird-client netbird status`. `Management: Connected` alone is not enough — a `config.yaml` whose `exposedAddress` omits `:443` leaves every peer logged in but never connected.
- After enrollment, assign the peer as **Router** of the LAN Network in the dashboard (Networks → *your network* → Routers, masquerade on) — without a router the LAN subnet resources are unreachable.

---

### Development Tools

#### `setup-neovim.sh`
Installs Neovim directly on the host machine (Ubuntu/Debian) with lazy.nvim plugin manager, LSP support via nvim-lspconfig, and essential productivity plugins. Installed via official PPA for latest stable version.

**Features:**
- lazy.nvim fast plugin manager with on-demand loading
- nvim-lspconfig for Language Server Protocol support
- telescope.nvim fuzzy finder
- nvim-cmp intelligent code completion
- treesitter advanced syntax highlighting
- gitsigns git integration
- oil.nvim modern file explorer

#### `setup-zed.sh`
Installs the Zed editor on Linux using the official installation script. Supports both stable and preview channels.

---

### Virtualization

#### `setup-virt-runner.sh`
Installs the virt-runner CLI tool and all host prerequisites needed to run the VM-based integration test suite. Clones the virt-runner repository, sets up KVM, libvirt, storage pools, user permissions, and installs the CLI tool via uv.

**Features:**
- Clones the virt-runner repository (default: https://github.com/Kubementat/virt-runner.git)
- Runs `install-prerequisites.sh` for KVM, libvirt, pools, and user permissions
- Installs virt-runner as a uv tool
- Verifies the installation
- Idempotent: safe to re-run on an already-configured system

**Environment variables (all optional):**
- `VIRT_RUNNER_REPO` — URL of the virt-runner repository
- `VIRT_RUNNER_DIR` — Local directory to clone to (default: `~/dev/os_projects/virt-runner`)
- `VIRT_USERNAME` — User to add to libvirt/kvm groups (default: current user)

**Usage:**
```bash
# Automated setup
./tasks/setup-virt-runner.sh

# Custom repository and directory
VIRT_RUNNER_REPO=https://github.com/Kubementat/virt-runner.git \
VIRT_RUNNER_DIR=~/dev/virt-runner ./tasks/setup-virt-runner.sh
```

> **Note:** After installation, you may need to log out and back in for group membership changes to take effect, or run `newgrp libvirt`.

#### `setup-virtualization.sh`
Installs or updates libvirt (virtualization API) and virt-manager (graphical VM manager) on Debian/Ubuntu-based systems. Configures the libvirt daemon, default networks, and adds the user to the libvirt group.

**Features:**
- Installs QEMU/KVM, libvirt-daemon, bridge-utils, virtiofsd (for virt-runner `create --mount` host directory shares)
- Graphical virt-manager VM management
- Automatic default network configuration
- User permission setup for libvirt access
- Supports both fresh install and update modes

---

### SSH Utilities

#### `setup-ssh-tunnel-user.sh`
Creates a locked-down SSH user with no shell access, configured exclusively for port-forwarding tunnels.

> **Note:** See `utilities/ssh-port-forward.sh` for SSH tunneling utilities.

---

### Monitoring & Observability

#### `setup-monitoring.sh`
Deploys a containerized observability stack (Prometheus, Grafana, Node Exporter, cAdvisor) via Docker Compose. Prometheus auto-discovers containers labeled `prometheus.scrape=true` (and `prometheus.port=<port>`) via Docker service discovery and exposes a hot-reloadable Lifecycle API. **cAdvisor** provides per-container CPU/memory/disk/network metrics. Grafana is pre-provisioned with a Node Exporter and a cAdvisor dashboard (no manual import). Data is persisted under `/srv/monitoring` and re-runs never destroy existing state (no `down -v`).

**Exposure modes:**
- **Direct** (default): Grafana at `http://<server-ip>:3100` (published on `0.0.0.0`, reachable from the local network) and the Prometheus UI at `http://127.0.0.1:9090` (loopback only, since the Prometheus UI has **no authentication**). Only the Grafana port gets an UFW allow rule; if you publish Prometheus beyond loopback (`PROMETHEUS_BIND_ADDRESS`), restrict it manually (e.g. `ufw allow from <subnet> to any port 9090 proto tcp`).
- **Traefik** (`GRAFANA_TRAEFIK=true`): Grafana routed via the shared proxy network at `https://GRAFANA_DOMAIN`; Prometheus stays internal. Requires `GRAFANA_DOMAIN` and a running Traefik stack with the shared `proxy` network.

**Usage examples:**
```bash
# Direct mode (default): Grafana on the LAN (0.0.0.0), Prometheus on 127.0.0.1
./tasks/setup-monitoring.sh

# Direct mode with everything on loopback
GRAFANA_BIND_ADDRESS=127.0.0.1 ./tasks/setup-monitoring.sh

# Traefik mode
GRAFANA_TRAEFIK=true GRAFANA_DOMAIN=grafana.example.com ./tasks/setup-monitoring.sh
```

> **Note:** To monitor a service, label its container `prometheus.scrape=true` and `prometheus.port=<port>`. The Grafana admin password is stored in `/srv/monitoring/grafana/.env` (mode 600). Reload Prometheus config without a restart: `docker compose -f /srv/monitoring/docker-compose.yml exec prometheus wget -q --post-data='' http://localhost:9090/-/reload`.

### Backup

#### `setup-backup-server.sh`
Turns one machine into the central **Borg** backup storage host **and** starts a working self-backup in one step: installs `borgbackup`, prepares storage (a mounted **drive** — verified fstab-persistent — or a **local directory** on the main fs when no drive is present; the script never formats or edits fstab), creates the per-client repo layout (`<mount>/automatic`, `<mount>/manual`) and fixes group/ownership, then runs the client in local mode (`--initial`) so a real snapshot exists. A bare `./tasks/setup-backup-server.sh` with **no arguments** gives a working self-backup (auto-detected scope + services, local-disk storage). The server is a "dumb" storage host — it stores no passphrases and runs no scheduling (`borg serve` is implicit in sshd). Idempotent; `--check` reports status for monitoring. Runs as root or a sudo-capable user (per-command `sudo`).

#### `setup-backup-client.sh`
Adds any machine to the backup fleet: installs `borgbackup`, **auto-detects** the backup scope (`/home/<user>`, `/etc`, `/srv`, `+ /var/lib/docker/volumes` when Docker is running) and the Docker services to dump (installed/running ones) when `--paths`/`--services` are omitted, initializes the machine's repository (remote over SSH **or** local path), generates a 32-char repo passphrase into `~/.config/borg/<client>.pass` (mode 600), and installs the wrapper `/usr/local/bin/borg-backup-<client>` (rendered from `templates/backup-client/` via `envsubst`) plus a daily systemd timer (`Persistent=true`, 15 min jitter). With `--services`, Docker-based databases are dumped **consistently** before each `borg create` (engine-level `pg_dump`/`mysqldump`/`sqlite3 .backup`/`forgejo dump` via `lib/docker-backup.sh`) and staged into the same archive — so an archive never contains a database copied mid-write. Wrapper subcommands: `create`, `list`, `check [--full]`, `restore <snap> [--dest DIR] [paths…]`, `restore-db <snap> <service> --yes` (destructive DB restore).

**Usage examples:**
```bash
# 1. Zero-config: one command → working self-backup (local-disk mode):
./tasks/setup-backup-server.sh
./tasks/setup-backup-server.sh --check

# 2. Storage host with an external drive (already mounted + fstab-persistent):
BACKUP_MOUNT=/mnt/backup ./tasks/setup-backup-server.sh

# 3. Remote client (key-based SSH to the server):
sudo ./tasks/setup-backup-client.sh --client mybox \
     --host backup.example.com --port 22 --user alice \
     --repo-path /var/backups/automatic \
     --paths "/home/alice /etc /srv" \
     --services "forgejo,planka,kestra" --initial

# 4. Manage:
sudo /usr/local/bin/borg-backup-mybox list
sudo /usr/local/bin/borg-backup-mybox restore mybox-2026-09-13T04:29:18 --dest /tmp/restore
```

> **Notes:** Supported `--services` (dump dispatcher in `lib/docker-backup.sh`): `forgejo, planka, kestra, nextcloud, n8n, concourse, openwebui, omnigent, matrix`. Services whose raw data must never be copied mid-write can be quiesced around the whole run with `--stop-services` (short `docker compose stop`/`up -d` window). With `nextcloud` in `--services` the backup user is added to the group owning `<NEXTCLOUD_HOME>/data` (`www-data`) — otherwise the 0770 data dir and `config.php` are unreadable and borg silently skips all user files. The staging dir (`/var/backup-staging` default) must not be inside `--paths`. Local-disk mode protects against software corruption / accidental deletion but **not** disk failure — mount a separate drive for that. `--no-self-backup` / `--no-initial` on the server script opt out of the automatic self-backup. Installs that customized a service's `CONTAINER_NAME` must mirror it into the backup-side `<SVC>_CONTAINER` override (e.g. `FORGEJO_CONTAINER`). Spec: [specification/features/setup-backup-server.md](specification/features/setup-backup-server.md); research: [docs/research/docker-volume-backup-research.md](docs/research/docker-volume-backup-research.md).

---

## Utility Scripts (`utilities/`)

### `run-llama-server.sh`
A generalized launcher for llama.cpp's llama-server with sensible defaults based on your manual configuration. Automatically enables flash attention, GPU layers, and KV cache settings. When run without `--model`, it lists all available `.gguf` models in `$HOME/.lmstudio/models/`.

**Key features:**
- Uses your default parameters (temperature, context size, GPU layers, etc.)
- Automatically enables `--no-mmap`, `--kv-unified`, and `--flash-attn`
- Lists models on `$HOME/.lmstudio/models/` when `--model` is omitted
- All parameters can be overridden via arguments or environment variables

**Default parameters:**
| Parameter | Default |
|-----------|---------|
| HOST | `0.0.0.0` |
| PORT | `1236` |
| TEMPERATURE | `0.6` |
| TOP_K | `40` |
| TOP_P | `0.95` |
| REPEAT_PENALTY | `1.00` |
| PRESENCE_PENALTY | `0.00` |
| PARALLEL | `1` |
| THREADS_COUNT | `14` |
| PRIO | `1` |
| CONTEXT_SIZE | `100000` |
| BATCH_SIZE | `512` |
| FLASH_ATTENTION | `on` |
| GPU_LAYERS | `all` |
| KV_CACHE_TYPE | `q4_0` |

**Usage examples:**
```bash
# List all available .gguf models in ~/.lmstudio/models/ and exit
./utilities/run-llama-server.sh

# Start server with your default model and parameters
./utilities/run-llama-server.sh

# Start server with a specific model (uses all defaults)
./utilities/run-llama-server.sh --model ~/models/Qwen2.5-7B-Instruct.gguf

# Custom port and host
./utilities/run-llama-server.sh --model ~/models/model.gguf --port 1236 --host 0.0.0.0

# Override specific parameters
./utilities/run-llama-server.sh --model model.gguf --temperature 0.8 --ctx-size 50000

# Disable flash attention (override default)
./utilities/run-llama-server.sh --model model.gguf -fa off

# Set environment variables for customization
export PORT=1237
export TEMPERATURE=0.7
./utilities/run-llama-server.sh --model model.gguf
```

**Environment variables (all optional):**
- `MODEL_PATH` - Default model path
- `HOST`, `PORT` - Server binding
- `TEMPERATURE`, `TOP_K`, `TOP_P`, `REPEAT_PENALTY`, `PRESENCE_PENALTY`, `PARALLEL` - Generation parameters
- `THREADS_COUNT`, `PRIO`, `CONTEXT_SIZE`, `BATCH_SIZE`, `FLASH_ATTENTION`, `GPU_LAYERS`, `KV_CACHE_TYPE` - Performance parameters
- `KV_UNIFIED` - Enable unified KV cache (default: true)

### `ssh-port-forward.sh`
Simple SSH tunnel wrapper for creating secure port forwards from a local machine to a remote server.

**Usage:**
```bash
./ssh-port-forward.sh <local_port> <remote_host> <remote_port> <ssh_user> [ssh_port]
```

**Parameters:**
- `local_port` - Local port to forward from
- `remote_host` - Remote server hostname or IP
- `remote_port` - Port on the remote server to forward to
- `ssh_user` - SSH username for the remote server
- `ssh_port` - SSH port on the remote server (optional, defaults to 22)

**Example:**
```bash
# Forward local port 3333 to remote server 192.168.0.3 port 3333
./ssh-port-forward.sh 3333 192.168.0.3 3333 myuser 2224
```

This creates an SSH tunnel that forwards connections from `localhost:3333` through the SSH connection to `192.168.0.3:3333`. The tunnel remains active until you press Ctrl+C.

### `sync-server-files.sh`
Syncs a directory from a remote AI server to a local machine (laptop, dev machine, ...) using rsync over SSH. Useful for pulling down repositories, agent workspaces (e.g. Hermes), or service data directories from the server.

**Key features:**
- Incremental sync — only changed files are transferred
- Handles Docker volume ownership (UID 10000) gracefully by stripping ownership metadata on the destination
- Pre-flight checks: connectivity to the server, existence of the remote path
- Optional `--delete` mode to mirror the remote directory exactly
- Optional `--sudo` for reading restricted files on the remote side
- Syncs one directory per invocation — invoke once per directory to sync multiple

**Environment variables:**
| Variable | Description | Default |
|----------|-------------|---------|
| `SYNC_REMOTE_USER` | SSH user on the server (**required**) | — |
| `SYNC_REMOTE_HOST` | Server IP or hostname (**required**) | — |
| `SYNC_SSH_PORT` | SSH port | `2224` |
| `SYNC_DELETE` | Delete local files not on remote (`yes` to enable) | `no` |
| `SYNC_SUDO` | Use sudo on remote side (`yes` to enable; also `--sudo` flag) | `no` |

**Options:**
- `--source-directory <path>` — Remote directory on the server to sync (required)
- `--target-directory <path>` — Local directory to sync into (required)
- `--dry-run` — Show what would be transferred without doing it
- `--verbose` — Show rsync output in detail
- `--sudo` — Use sudo on remote side for reading restricted files
- `--help` — Show help and exit

**Usage examples:**
```bash
# Sync the hermes agent workspace from the server
SYNC_REMOTE_USER=alice SYNC_REMOTE_HOST=192.168.1.100 \
  ./utilities/sync-server-files.sh --source-directory /srv/hermes --target-directory ~/backups/hermes

# Mirror a directory (also delete local files removed on the server)
SYNC_REMOTE_HOST=192.168.1.100 SYNC_DELETE=yes \
  ./utilities/sync-server-files.sh --source-directory /srv/openwebui --target-directory ~/backups/openwebui

# Read restricted files with sudo on the remote side
SYNC_REMOTE_HOST=192.168.1.100 SYNC_SUDO=yes \
  ./utilities/sync-server-files.sh --source-directory /srv/forgejo --target-directory ~/backups/forgejo --sudo

# Preview without transferring
SYNC_REMOTE_HOST=192.168.1.100 \
  ./utilities/sync-server-files.sh --source-directory /srv/hermes --target-directory ~/backups/hermes --dry-run --verbose
```

**Sudo configuration (only needed with `--sudo` / `SYNC_SUDO=yes`):**
Since rsync runs over SSH without a tty, sudo cannot prompt for a password. Grant passwordless sudo for rsync on the remote server:

```bash
sudo visudo
# Add (adjust username as needed):
alice ALL=(ALL) NOPASSWD: /usr/bin/rsync
```

This only grants passwordless access to rsync, not to arbitrary commands. For tighter restrictions, limit to specific paths:
```
alice ALL=(ALL) NOPASSWD: /usr/bin/rsync --server * /srv/hermes
```
