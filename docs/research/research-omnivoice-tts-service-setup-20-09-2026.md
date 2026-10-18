# OmniVoice.cpp TTS REST API — Productive Service Setup (Research)

Date: 2026-09-20
Scope: how to run the OmniVoice.cpp `tts-server` (OpenAI-compatible TTS HTTP
server) **productively as a service on an Ubuntu systemd host**, feeding an
implementation plan for a `tasks/setup-omnivoice.sh` in this repo.

Companion doc (endpoint/CLI copy of the upstream server README):
`docs/research/research-omnicvoice-tts-19-09-2026.md`.

**Legend.** Every claim is tagged:
- **[VERIFIED]** — read directly from the upstream source, CMake, build
  scripts, Hugging Face API, or the upstream issues.
- **[INFERRED]** — reasoned from verified facts (e.g. VRAM from model size);
  not stated by upstream.
- **[UNVERIFIED]** — could not be confirmed; treat as a risk to re-check at
  implementation time.

Upstream: <https://github.com/ServeurpersoCom/omnivoice.cpp>
(default branch `master`, MIT, 176★, 47 forks, pushed 2026-09-18, 12 open
issues) **[VERIFIED via GitHub API]**.

---

## 1. Verified `tts-server` CLI options

Read from `tools/tts-server.cpp` (the argument parser in `main`) **[VERIFIED]**:

| Option | Required | Default | Meaning |
|---|---|---|---|
| `--model <gguf>` | yes | — | LLM GGUF (F32 / BF16 / Q8_0) |
| `--codec <gguf>` | yes | — | Codec GGUF (`omnivoice-tokenizer-*.gguf`) |
| `--host <ip>` | no | `127.0.0.1` | Listen address |
| `--port <n>` | no | `8080` | Listen port |
| `--lang <str>` | no | `None` | Language label when a request omits one |
| `--no-fa` | no | (off) | Disable flash attention |
| `--clamp-fp16` | no | (off) | Clamp hidden states to FP16 range |

That is the **complete** server flag set. The parser calls `print_usage` +
`return 1` on any unknown flag, so there are **no** hidden options.

**Flags that do NOT exist on the server** (correcting the task's hypothesis
and several llama.cpp/vllm habits):
- No `--threads` / thread count.
- **No GPU device selection** (no `--device`/`--gpu`/`-ngl`). The GPU backend
  is chosen at **build time** (`GGML_VULKAN`/`GGML_CUDA`), not runtime. On a
  multi-GPU host there is no server flag to pick the device. **[VERIFIED]**
- No log-level flag.
- No data-dir / voices-dir flag (voices are not file-backed — §7).
- No `--steps` and no `--dump <dir>` — those belong to the `omnivoice-tts`
  CLI tool, not `tts-server`. **[VERIFIED]**

`server_config` (in `src/tts-server.h`) defaults `host = "127.0.0.1"`,
`port = 8080` **[VERIFIED]**. The listener sets `SO_REUSEADDR` so a restart
can rebind a port still in `TIME_WAIT` **[VERIFIED]**.

### HTTP endpoints (all confirmed in `src/tts-server.h`) **[VERIFIED]**
- `POST /v1/audio/speech` — synthesize (body: `input`, `voice`, `language`,
  `instructions`, `response_format`=`wav`|`pcm`, `seed`).
- `POST /v1/audio/voices` — register a cloned voice (`name`, `ref_text`,
  and exactly one of `wav_b64` / `rvq_b64`).
- `GET /v1/audio/voices` — list registered voice names.
- `DELETE /v1/audio/voices/{name}` — drop a voice.
- `GET /v1/models` — the single loaded model.
- `GET /health` — liveness probe → `{"status":"ok"}`.

CORS is permissive (`Access-Control-Allow-Origin: *`). The HTTP layer is
`cpp-httplib`, **no TLS** — production must front it with Traefik (TLS) or
bind loopback-only and expose via ufw-restricted direct access. **[VERIFIED
(CMakeLists comment + headers)]**

---

## 2. Models, quantization, download

### Real Hugging Face repo **[VERIFIED via HF API]**
The correct repo is **`Serveurperso/OmniVoice-GGUF`** — **not gated**, so
**no HF token / API key is required** to download.

> ⚠️ **Upstream bug:** the shipped `models.sh` uses
> `REPO="Serveurperso/omnivoice.cpp-GGUF"`, a repo that **does not exist**
> (HF API returns nothing; the org listing shows `OmniVoice-GGUF`, not
> `omnivoice.cpp-GGUF`). The upstream README correctly says
> `OmniVoice-GGUF`. **A setup script must NOT reuse `models.sh` verbatim —
> it would fail.** Download from `Serveurperso/OmniVoice-GGUF`.

### Available files (exact byte sizes from the HF tree API) **[VERIFIED]**
| File | Bytes | ≈ |
|---|---|---|
| `omnivoice-base-BF16.gguf` | 1,230,624,768 | 1.14 GiB |
| `omnivoice-base-F32.gguf` | 2,455,648,160 | 2.29 GiB |
| `omnivoice-base-Q4_K_M.gguf` | 407,485,216 | 388 MiB |
| `omnivoice-base-Q8_0.gguf` | 656,395,008 | **626 MiB** ← recommended |
| `omnivoice-tokenizer-BF16.gguf` | 373,308,160 | 356 MiB |
| `omnivoice-tokenizer-F32.gguf` | 734,300,704 | **699 MiB** ← recommended |
| `omnivoice-tokenizer-Q4_K_M.gguf` | 252,474,112 | 241 MiB |
| `omnivoice-tokenizer-Q8_0.gguf` | 288,889,600 | 275 MiB |

### Recommended quantization **[VERIFIED — policy stated in README + `quantize.sh` + issue #18 usage]**
- **Base LM: `Q8_0` (626 MiB).** Quantisation policy is "Q8_0 only on the base
  LM" (612 M-param Qwen3 backbone).
- **Tokenizer: keep at native dtype — `F32` (699 MiB).** `quantize.sh` comment:
  "base LM Q8_0 (tokenizer stays at native dtype)"; the checkpoint stores the
  codec at F32 so the GGUF stays F32 to avoid a rounding pass.
- **Default download set:** `omnivoice-base-Q8_0.gguf` +
  `omnivoice-tokenizer-F32.gguf` ≈ **1.3 GB total** (matches upstream
  `models.sh` intent and the issue-#18 field test).
- Lower-VRAM option: `base-Q4_K_M` + `tokenizer-Q4_K_M` (~630 MiB total);
  higher-fidelity: `base-BF16` + `tokenizer-F32` (~1.8 GB). Issue #18's
  operator ran with `base-Q4_K_M` + `tokenizer-Q8_0` without issue.

### Download method **[VERIFIED — matches repo convention]**
The repo installs the **`hf`** CLI (`tasks/setup-basics.sh`; `huggingface-cli`
is deprecated and `hf` is the current entry point, as noted in
`setup-vllm.sh`). Not gated → no token.

```
hf download Serveurperso/OmniVoice-GGUF \
  omnivoice-base-Q8_0.gguf omnivoice-tokenizer-F32.gguf \
  --local-dir <models-dir>
```

---

## 3. Build options

Build scripts (note: it is **`buildcpu.sh`**, not `build.sh`) **[VERIFIED]**:

| Script | CMake invocation | Backend |
|---|---|---|
| `./buildcpu.sh` | `-DGGML_BLAS=ON` | CPU (BLAS) |
| `./buildvulkan.sh` | `-DGGML_VULKAN=ON` | AMD / Intel (Vulkan) |
| `./buildcuda.sh` | `-DGGML_CUDA=ON -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc` | NVIDIA (CUDA) |
| `./buildall.sh` | `-DGGML_CPU_ALL_VARIANTS=ON -DGGML_CUDA=ON -DGGML_VULKAN=ON -DGGML_BACKEND_DL=ON` | all, runtime DL |
| `./buildsycl.sh` | SYCL | Intel SYCL |

`cmake ..` → `cmake --build . --config Release -j $(nproc)`; output binaries in
`build/`: `tts-server`, `omnivoice-tts`, `omnivoice-codec`, `quantize`,
`test-abi-c`.

Key CMake options **[VERIFIED from `CMakeLists.txt`]**:
- `GGML_VULKAN`, `GGML_CUDA`, `GGML_BLAS`, `GGML_METAL`, `GGML_SYCL`,
  `GGML_CPU_ALL_VARIANTS`, `GGML_BACKEND_DL` (build backends as `.so` loaded
  at runtime via `dlopen`), `GGML_CUDA_GRAPHS` (default **ON**; runtime opt-out
  `GGML_CUDA_DISABLE_GRAPHS=1`), `OMNIVOICE_SHARED` (opt-in `libomnivoice.so`).
- `CMAKE_CUDA_ARCHITECTURES` defaults to Turing→Blackwell
  (`75-virtual;80-virtual;86-real;89-real;120a-real;121a-real` when CUDA ≥
  12.8); override with `-DCMAKE_CUDA_ARCHITECTURES=native` for local builds.

Prereqs: `build-essential`, `cmake`, `git`; `ggml` is a **git submodule**
(`git clone --recurse-submodules`). For CUDA, `nvcc` must be present
(upstream hard-codes `/usr/local/cuda/bin/nvcc`). For Vulkan, the host needs
`mesa-vulkan-drivers` + `vulkan-tools` to verify.

> `buildall.sh` (all backends + `GGML_BACKEND_DL`) is the natural choice for a
> **single Docker image** that must work on NVIDIA, AMD, or CPU without
> rebuilding — the runtime picks the available backend.

### Prebuilt artifacts **[VERIFIED]**
- **No GitHub releases** (API returns none) → no official prebuilt binaries.
- **No `Dockerfile` / compose file anywhere in the repo.**
- **No official Docker Hub image** (search for "omnivoice" returns nothing).

**Consequence:** a Docker deployment requires **writing and maintaining a
custom `Dockerfile`** (clone + build from source with the chosen toolchain).
There is no `docker pull` shortcut. This is the single most important fact for
the deployment decision (§5).

---

## 4. GPU / runtime requirements

- **Backends:** CPU, CUDA (NVIDIA), Vulkan (AMD/Intel), ROCm, Metal, SYCL
  **[VERIFIED — README/description]**.
- **NVIDIA (CUDA):** needs the CUDA toolkit (`nvcc`) at build time and
  NVIDIA drivers at runtime. In Docker this is the standard
  `nvidia-container-toolkit` passthrough (`driver: nvidia` reservation).
- **AMD/Intel (Vulkan):** needs `mesa-vulkan-drivers`; the **service user**
  must be able to open `/dev/dri/renderD*` → membership in the `render` group
  (Debian/Ubuntu) or `video`. In Docker: pass `/dev/dri` + `group_add: [video]`
  (this exact pattern is already in `templates/vllm-omni/docker-compose.amd.*.yml`).
  **[INFERRED for the group name on the exact target; the `/dev/dri`+`group_add`
  device pattern is VERIFIED from the repo templates.]**
- **CPU fallback:** `./buildcpu.sh` (BLAS). Usable for low-volume/latency-
  tolerant use; **[INFERRED]** not realtime — it is a generative 612 M LLM +
  audio codec. No upstream benchmark found.
- **Minimum VRAM:** the existing research doc says "4 GB min / 8 GB
  recommended". This number is **NOT in the upstream README** (the upstream
  README has no hardware section) → treat as **[INFERRED]**. It is a plausible
  floor for the recommended `Q8_0`+`F32` config: ~1.3 GB weights plus
  activation/KV headroom. The `F32` base (2.3 GB) needs noticeably more.
- **CPU ISA:** modern x86_64/AVX2 (ggml). **[INFERRED]**.

---

## 5. Deployment recommendation: systemd-native vs docker-compose

Both patterns already exist in this repo:
- **Docker Compose** is the dominant pattern for GPU AI services: `setup-vllm.sh`
  (direct/LAN-only) and `setup-vllm-omni.sh` (Traefik-capable), plus
  `setup-colqwen.sh`. All share: `PROJECT_DIR=/srv/<svc>`, `.env` (mode 600)
  rendered from `templates/<svc>/env.template`, a rendered `docker-compose.yml`,
  GPU passthrough YAML, `restart: unless-stopped`, `wait_for_healthy` gate,
  opt-in Traefik labels or direct port + ufw.
- **Host-level "build a binary / run a service"** exists too: `setup-llama-cpp.sh`
  (build from source → `/opt` → `/usr/local/bin`, **no** systemd unit), and
  `setup-llama-swap.sh` / `setup-unsloth.sh` / `setup-opencode.sh`
  (install a binary → **systemd unit**).

### The decisive facts
1. **There is no official Docker image** (§3) → the Docker path means the
   setup script must **build a custom image from source** (C++ + ggml +
   vulkan/cuda toolchain in the image). Heavier, slower, larger, and harder to
   pin/reproduce without a registry.
2. The product is a **single self-contained binary** (`tts-server`) + 2 model
   files — the exact shape the host "install binary → systemd" scripts handle.
3. **Voice persistence is in-memory** (§7): the natural on-disk unit is a set
   of `.rvq`+transcript files that get **re-registered after (re)start**. That
   is cleanest as **host files under `/srv/omnivoice/`** + a registration step,
   which pairs naturally with a systemd unit (an `ExecStartPost` or a tiny
   helper invoked after `/health` is up).
4. **Vulkan host access is trivial** with systemd: a dedicated `User=` plus
   `SupplementaryGroups=render` (or `video`) — no container runtime, no
   `nvidia-container-toolkit`, no `seccomp=unconfined`.
5. The **upstream's own documented primary example is a systemd unit**
   (`/etc/systemd/system/omnivoice.service`, `Restart=always`, `WorkingDirectory`).

### Recommendation
**Primary: systemd-native** — build from source into `/srv/omnivoice` (or
`/opt/omnivoice`), run `tts-server` under a dedicated non-root service user
with the GPU render/video group, managed by a systemd unit with a bounded
`/health` readiness gate. Rationale: it matches the upstream's canonical
example, avoids inventing/maintaining a Docker image that upstream does not
ship, keeps voice `.rvq` persistence as plain host files, and makes Vulkan
device access a one-line group assignment. It aligns with the repo's existing
"binary + systemd" services (llama-swap/unsloth/opencode).

**Documented alternative: Docker Compose** — if the operator wants consistency
with `setup-vllm-omni.sh` (and the repo's dominant GPU convention) or wants
isolation. It is fully viable: ship a `Dockerfile` in `templates/omnivoice/`
that runs `buildall.sh` (all backends + `GGML_BACKEND_DL`) so one image works on
NVIDIA/AMD/CPU; use the repo's existing GPU passthrough YAML (NVIDIA
`driver: nvidia` reservation; AMD `/dev/dri` + `group_add: video`); mount
`/srv/omnivoice/voices` for `.rvq` persistence; `restart: unless-stopped`;
`wait_for_healthy` + `/health` poll; opt-in Traefik. **Cost:** the custom image
build and its lifecycle (no upstream image to pin).

> Whichever path is chosen, the implementation must follow the repo's
> **conventions** (`specification/project/conventions.md`): converge-by-default
> re-run, secrets/layout in `/srv/omnivoice/.env` (mode 600) with `${VAR}` kept
> literal, `wait_for_healthy`-style health gate with a bounded timeout, ufw for
> firewall (never iptables).

---

## 6. Networking: port, bind, Traefik, ufw

- **Default bind is `127.0.0.1:8080`** **[VERIFIED]**. `8080` is a likely
  conflict (many services use it) — pick a dedicated high port and make it an
  env/flag. **Suggested:** `OMNIVOICE_PORT` default e.g. **`8977`** (arbitrary,
  free-range) **[INFERRED — verify no conflict on the target]**. Container-
  internal port stays `8080`; publish map `${OMNIVOICE_PORT}:8080`.
- **Two exposure modes (repo convention, cf. openwebui/forgejo/vllm-omni):**
  - **Traefik (recommended for anything beyond loopback/LAN):** bind
    `127.0.0.1` (host) or keep the container on the `proxy` network, add the
    standard labels (`traefik.enable=true`, `traefik.docker.network=${PROXY_NETWORK}`,
    `Host(`${OMNIVOICE_DOMAIN}`)`, `entrypoints=websecure`,
    `tls.certresolver=letsencrypt`, `loadbalancer.server.port=8080`), require
    `OMNIVOICE_DOMAIN`, and pre-flight with `ensure_proxy_network`.
    **[VERIFIED — the label block is copied verbatim from
    `templates/openwebui/docker-compose.traefik.yml` / `vllm-omni` AMD
    traefik template.]**
  - **Direct / LAN-only:** publish on the host port and restrict with **ufw**
    (repo rule: always ufw, never iptables). Use `ufw_firewall_section` /
    `ufw_add_rule` from `lib/helpers.sh`. If bound to `0.0.0.0`, ufw is the only
    boundary — restrict to the LAN subnet. **[VERIFIED helpers exist]**
- **Health verification:** poll `GET /health` (returns 200 `{"status":"ok"}`)
  with a bounded timeout after start; in Docker wrap with `wait_for_healthy`
  (compose healthcheck + the script-level `/health` poll), exactly as
  `setup-vllm.sh` does. **[VERIFIED]**
- **Reusables in `lib/helpers.sh`** **[VERIFIED — read the file]:**
  `wait_for_healthy <timeout> <ids...>`, `env_file_get`/`env_file_write`
  (mode-600 env files), `ensure_proxy_network`, `ensure_traefik_running`,
  `ufw_available`/`ufw_active`/`ufw_rule_exists`/`ufw_add_rule`/
  `ufw_firewall_section`, `detect_arch`, `mktempfile`, `fetch_and_run`,
  `run_preflight_checks`, `is_apt_package_installed`.
  Note: there is **no** existing `wait_for_http` helper — the HTTP `/health`
  poll is written inline per-task (as in `setup-vllm.sh`); a systemd-native
  path would do the same inline `curl -sf` loop.

---

## 7. Voice persistence (critical for restarts & `/srv/omnivoice` layout)

**The voice registry is IN-MEMORY ONLY.** In `tools/tts-server.cpp`:
`static std::unordered_map<std::string, voice_entry> g_voices;` guarded by
`g_voices_mutex`. There is **no** file I/O, no configured data dir, and **no**
startup load of voices from disk — the only `.rvq` read is of an **uploaded
base64 payload** at registration time. **[VERIFIED from source]**

The maintainer confirms the design intent (issue #18): "it stays resident in
RAM … **Nothing persists between requests** … the table stays externally
maintained, as you expected, it just no longer touches the disk." And issue #7:
the maintainer's answer to "how to save a voice" is to **produce the latents
with the codec tool (`omnivoice-codec`) and reuse the `.rvq`** — i.e. the disk
persistence unit is the `.rvq`, not the server. **[VERIFIED — issues]**

**Consequences for a service:**
- **Every restart loses all registered voices.** They must be re-registered.
- **Persistence pattern:** keep per-voice `.rvq` files (from
  `omnivoice-codec --model <tokenizer.gguf> -i ref.wav`, which is bit-identical
  to the `--ref-wav` path) plus the `ref_text` transcript on disk, and run a
  **registration step** (a small `for` loop calling `POST /v1/audio/voices`)
  after the server's `/health` is up. On a systemd unit this is a small
  `ExecStartPost=`/post-ready helper; in Docker, a one-shot registration
  container or a step in the setup script. The issue-#18 operator demonstrates
  exactly this: `for f in *.rvq; do curl -X POST .../v1/audio/voices ...; done`.
- **Caveat (issue #7/#18):** the code-based (`.rvq`) path does **not** carry the
  reference loudness that `--ref-wav` does — apply your own gain if you need
  matched volume between voices. **[VERIFIED]**
- A `.rvq` payload **must come from the same codec quantisation** the server
  runs, or the voice is decoded in the wrong space (README). So encode with the
  **same tokenizer file** the server uses. **[VERIFIED — README]**

**Suggested `/srv/omnivoice` layout** **[INFERRED design]**:
```
/srv/omnivoice/
  .env                     # mode 600 (layout values; no secrets expected)
  models/
    omnivoice-base-Q8_0.gguf
    omnivoice-tokenizer-F32.gguf
  voices/
    <name>.rvq             # pre-encoded reference (same tokenizer as server)
    <name>.txt             # ref_text transcript
  (binary at /srv/omnivoice/build/tts-server or /usr/local/bin/tts-server)
```

---

## 8. Gotchas / known issues

From the upstream issue tracker + source **[VERIFIED]**:

1. **In-memory voices (biggest operational gotcha):** restarts wipe the
   registry; must re-register from `.rvq` files (§7). No built-in
   load-on-start flag exists.
2. **Broken `models.sh`:** ships `REPO="Serveurperso/omnivoice.cpp-GGUF"`
   (non-existent). Correct repo is `Serveurperso/OmniVoice-GGUF`. Do not copy
   `models.sh` verbatim (§2).
3. **Concurrency: single GPU context, synthesis serialized FIFO.**
   `g_synth_mutex` serializes all `/v1/audio/speech` (and WAV-encoding voice
   registration) calls. There is **no** parallelism/batching; N concurrent
   clients queue. Plan for a single in-flight synthesis. **[VERIFIED — source
   + README "Concurrency"]**
4. **No runtime GPU/device/thread knobs** on the server (§1) — tune via build
   backend and model quantization, not flags.
5. **Unicode/encoding (issue #16, open):** feeding non-English (KO/ZH) text as
   the *prompt* produced gibberish on **Windows/PowerShell** due to stdin
   encoding; the maintainer pushed a stdin encoding fix. On Linux with proper
   UTF-8 in the JSON body this is far less of a risk, but **pass UTF-8 text in
   the JSON `input`** and re-test CJK at implementation time. **[VERIFIED —
   issue; Linux behavior UNVERIFIED]**
6. **Cross-language accent bleed (issue #18):** one call = one accent; mixing
   languages in a single utterance bleeds. Use one call per language block
   (`language` field overrides the server default per request). **[VERIFIED]**
7. **Cantonese (yue) inconsistency (issue #17, open)** — quality caveat for
   that language specifically. **[VERIFIED — open issue]**
8. **No TLS in `tts-server`** (plain `cpp-httplib`) → must front with Traefik or
   keep loopback + ufw (§6).
9. **Model memory:** the F32 base is 2.3 GB; if VRAM is tight use Q8_0/Q4_K_M
   base. OOM on under-provisioned GPUs is the main build/runtime risk.
   **[INFERRED]**
10. **`ggml` is a submodule** — a non-`--recurse-submodules` clone produces a
    build failure (missing `ggml/`). **[VERIFIED — CMake `add_subdirectory(ggml)`]**

**Not observed:** no OOM/crash/Vulkan-specific open issues in the tracker at
this time (12 open issues, none about production build crashes or Vulkan
device access). **[UNVERIFIED — absence of evidence; re-check at
implementation]**

---

## 9. Recommended setup (summary)

**Form factor:** systemd-native service (primary), Docker Compose (documented
alternative). Build for the detected backend; default to the recommended
`base-Q8_0` + `tokenizer-F32` model set.

**High-level plan for `tasks/setup-omnivoice.sh`:**
1. **Preflight:** Ubuntu check, `build-essential`/`cmake`/`git` present,
   `hf` CLI present (else point to `setup-basics.sh`), GPU backend
   auto-detect (nvidia-smi / lspci / `/dev/dri`+`vulkaninfo`, same logic as
   `setup-llama-cpp.sh`/`setup-vllm.sh`).
2. **Install dir + service user:** `PROJECT_DIR=/srv/omnivoice` (or
   `/opt/omnivoice`); create a non-root `omnivoice` user; add it to the GPU
   `render`/`video` group (Vulkan) for `/dev/dri` access.
3. **Build from source:** `git clone --recurse-submodules` → run the
   backend-specific build (`buildvulkan.sh` / `buildcuda.sh` / `buildcpu.sh`),
   pinning a ref for reproducibility (llama-cpp's ref-resolution pattern).
4. **Download models:** `hf download Serveurperso/OmniVoice-GGUF
   omnivoice-base-Q8_0.gguf omnivoice-tokenizer-F32.gguf --local-dir
   /srv/omnivoice/models` (no token; NOT gated). Do **not** reuse the broken
   `models.sh`.
5. **Config:** render `/srv/omnivoice/.env` (mode 600) with layout values
   (`OMNIVOICE_PORT`, `OMNIVOICE_HOST`, `OMNIVOICE_LANG`, backend, model paths);
   keep `${VAR}` literal where runtime-resolved.
6. **Service unit (systemd):** `User=omnivoice`, `WorkingDirectory=/srv/omnivoice`,
   `SupplementaryGroups=render` (Vulkan) / appropriate for CUDA,
   `Restart=on-failure` (or `always`), `ExecStart=/srv/omnivoice/build/tts-server
   --model .../omnivoice-base-Q8_0.gguf --codec .../omnivoice-tokenizer-F32.gguf
   --host <bind> --port 8080 --lang <lang>`, plus resource limits
   (`MemoryMax=`/`CPUQuota=` as appropriate), and a post-ready voice
   registration step.
   **Docker alternative:** `Dockerfile` (buildall) + `docker-compose.yml` with
   the repo's GPU passthrough YAML, `.env` (600), `restart: unless-stopped`,
   `volumes: /srv/omnivoice/voices`, opt-in Traefik labels.
7. **Networking:** default loopback (`127.0.0.1`) + Traefik for anything
   external; or direct host port + ufw restriction. Expose host port
   `OMNIVOICE_PORT` (avoid 8080 conflict) → container/port `8080`.
8. **Health gate (convention):** bounded `curl -sf http://127.0.0.1:8080/health`
   poll after `systemctl start` (or `wait_for_healthy` + compose healthcheck in
   Docker); non-zero exit on timeout. **Prove the stack is up before reporting
   success.**
9. **Voice persistence:** keep `/srv/omnivoice/voices/*.rvq`+`*.txt`; after the
   server is healthy, register each via `POST /v1/audio/voices` (re-run on
   every start). Document that restarts otherwise lose voices.
10. **Re-run policy:** converge by default — re-render `.env`/unit/compose,
    reuse stored values, `systemctl reload-or-restart` / `docker compose up -d`,
    re-verify `/health`. Never rotate a stored value.

**Key numbers / facts to carry into the plan:**
- CLI: only `--model`, `--codec`, `--host` (127.0.0.1), `--port` (8080),
  `--lang` (None), `--no-fa`, `--clamp-fp16`. No device/threads/log/dir flags.
- Models: `Serveurperso/OmniVoice-GGUF` (not gated); recommended
  `omnivoice-base-Q8_0.gguf` (626 MiB) + `omnivoice-tokenizer-F32.gguf`
  (699 MiB) ≈ 1.3 GB.
- No official Docker image / releases → source build required (host or custom
  image via `buildall.sh`).
- Voices: in-memory only; persist as `.rvq`+transcript and re-register after
  (re)start.
- Concurrency: serialized FIFO, one GPU context.
- No TLS in the server → Traefik or loopback+ufw.

---

## Sources

Upstream (default branch `master`, fetched 2026-09-20):
- Repo / metadata: <https://github.com/ServeurpersoCom/omnivoice.cpp>
- README: <https://raw.githubusercontent.com/ServeurpersoCom/omnivoice.cpp/master/README.md>
- CMake options: <https://raw.githubusercontent.com/ServeurpersoCom/omnivoice.cpp/master/CMakeLists.txt>
- Server CLI (flag parser + in-memory registry): <https://raw.githubusercontent.com/ServeurpersoCom/omnivoice.cpp/master/tools/tts-server.cpp>
- Server endpoints / config defaults / concurrency: <https://raw.githubusercontent.com/ServeurpersoCom/omnivoice.cpp/master/src/tts-server.h>
- Build scripts: `buildcpu.sh`, `buildvulkan.sh`, `buildcuda.sh`, `buildall.sh` (same raw base)
- `models.sh` (contains the broken repo name): <https://raw.githubusercontent.com/ServeurpersoCom/omnivoice.cpp/master/models.sh>
- Architecture (quantization policy, flag tables): <https://raw.githubusercontent.com/ServeurpersoCom/omnivoice.cpp/master/docs/ARCHITECTURE.md>
- Issues: #7 (save voice), #18 (persistent voice identity / in-RAM registry), #16 (Unicode), #17 (Cantonese), #12 (server cloning):
  <https://github.com/ServeurpersoCom/omnivoice.cpp/issues>

Hugging Face:
- Model repo + file sizes (not gated): <https://huggingface.co/Serveurperso/OmniVoice-GGUF>
  (tree API: <https://huggingface.co/api/models/Serveurperso/OmniVoice-GGUF/tree/main>)

This repo (patterns + helpers reused by the plan):
- `lib/helpers.sh` (`wait_for_healthy`, `env_file_get`/`env_file_write`, ufw
  helpers, `ensure_proxy_network`), `specification/project/conventions.md`
  (converge-by-default, secrets, health verification, ufw-only).
- `tasks/setup-vllm.sh`, `tasks/setup-vllm-omni.sh`, `tasks/setup-llama-cpp.sh`,
  `tasks/setup-openwebui.sh`, `tasks/setup-forgejo.sh`.
- `templates/vllm/docker-compose.yml.tmpl`, `templates/vllm-omni/docker-compose.amd.traefik.yml`
  (GPU passthrough + Traefik label blocks), `templates/openwebui/docker-compose.traefik.yml`.
