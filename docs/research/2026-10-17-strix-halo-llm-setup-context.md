# Research Brief — Running Qwen3.8 Flash-Next & Qwen3.8-27B on AMD Strix Halo (2026-10-17)

**Implemented by:** `docs/plans/2026-10-17-strix-halo-qwen38-setup.md`, as
`tasks/setup-strix-halo-tuning.sh` (the GPU reserve) and
`tasks/setup-gufo-strix-halo-qwen38-{flash,27b}.sh`, with the shared logic in
`lib/strix-halo-helper.sh`.

Collect from the vault (`/home/ubuntu/vault/30-Reports/research-reports/`); see also the
strix-halo-llm skill. Full source files:
`2026-10-11-strix-halo-dgx-spark-llm-guide.md`, `gufo-strix-halo-inference-engine.md`,
`2026-10-11-strix-halo-vs-dgx-spark-llm.md`, `2026-09-20-strix-halo-llm-ram-optimization.md`.

## 1. Target hardware — AMD Strix Halo (Ryzen AI MAX+ 395)

- Radeon 8060S RDNA 3.5 (`gfx1151`), 128 GB unified LPDDR5X-8000, ~215-256 GB/s.
  No discrete VRAM; decode is bandwidth-bound. Model size limited by system RAM.
- OS target: Ubuntu Server 26.04 LTS, kernel >= 6.18.9 (6.18.4 has a gfx1151 stability bug).
- Packages: podman, crun (rootless GPU group passthrough), mesa-vulkan-drivers,
  rocm-smi (monitoring only). Disable ZRAM (vm.swappiness=10). loginctl enable-linger.

### Kernel / BIOS tuning (the machine-setup part)
- `/etc/default/grub.d/99-amdgpu-llm.cfg` drop-in:
  `amd_iommu=off amdgpu.gttsize=122880 ttm.pages_limit=31457280 amdgpu.noretry=0 amdgpu.gpu_recovery=1`
  (120 GiB GPU-reserve variant; pages = GiB*262144, MiB = GiB*1024 — derive BOTH knobs
  from one GPU_RESERVE_GIB value. Known pitfall: mismatched gttsize/pages_limit knobs.)
- `sudo update-grub && sudo reboot`. Verify:
  `/sys/class/drm/card1/device/mem_info_gtt_total`, `rocm-smi --showmeminfo all`.
- BIOS: UMA Frame Buffer minimum (512 MB-2 GB); IOMMU disabled (~6-7% bandwidth gain).
- Helper: `amd-ttm` (pipx package amd-debug-tools) for live GTT tuning.
- ROCm env: `HSA_OVERRIDE_GFX_VERSION=11.5.1`, `HSA_ENABLE_SDMA=0`.
- Rootless podman trap: `--group-add keep-groups` (crun keep_original_groups), NOT
  `--group-add video/render`; ROCm needs both /dev/kfd and /dev/dri.

## 2. The two target models on Strix Halo (validated 2026-10-11)

| Model | Arch | GGUF quant | Size | Fits | Engine | Decode |
|---|---|---|---|---|---|---|
| Qwen3.8-Flash-Next | MoE 125B/6B active (+51B PLE) | UD-IQ4_XS 94 GB (IQ3_XS 82 GB safer) | 93.7 GB | yes (tight) | llama.cpp Vulkan/ROCm, Gufo | 18 (no MTP) / 33 (Vulkan MTP) / 47 (ROCm MTP); Gufo higher at long ctx |
| Qwen3.8-27B | Dense 27B | Q4_K_M 18 GB (Q8_K_XL also) | 17.7 GB | yes | llama.cpp/Ollama, Gufo | ~13 (llama.cpp); Gufo 70.56 tok/s tg, 123 agg@8 users (DFlash2) |

- Both fit comfortably in 128 GB unified RAM together (112 GB weights) — unlike the
  DGX Spark TensorFold recipes where only one can be resident. KV cache at long
  context adds 15-25 GB (Flash-Next); budget under the ~120 GiB GPU reserve.
- Flash-Next needs the qwen4exp support fix in llama.cpp (PR #27941 / #28501 row-id
  hoisting; EngramHalo fork referenced) — pinned llama.cpp ref must include it.
- Vulkan MTP pitfall: `--spec-type draft-mtp` crashes RADV mid-prompt past ~tens of
  thousands of tokens (llama.cpp issue #27306). MTP-off survives past 125k.
  ROCm MTP is the stable long-context path; Vulkan MTP tuned to 33 tok/s median
  (drluoto) with `--spec-draft-p-min 0.0`, no ngram-mod.

### Engine options for the two models
1. **llama.cpp** (Vulkan/RADV or ROCm backend). Flags on gfx1151: `-fa 1 --no-mmap
   -ngl 999`, `-b 256` for MoE, MTP via `--spec-type draft-mtp`. Existing
   `setup-llama-cpp.sh` already builds the AMD Vulkan path; ROCm/MTP/`--no-mmap`
   are NOT covered there.
2. **Gufo** (github.com/gufo-org/gufo, MIT, v0.8.0 2026-10-05) — purpose-built
   Strix Halo engine, native HIP gfx1151 kernels, OpenAI-compatible (Chat
   Completions, Responses, Anthropic Messages). Prefill +242% to +886% vs
   llama.cpp at depth; multi-user batching; model-native speculation:
   Flash-Next = adaptive MTP, 27B = DFlash2 (needs
   z-lab/Qwen3.8-27B-DFlash2-GGUF Q4_K_M draft, same sidecar as the Spark recipe).
   Deploy: ghcr.io/gufo-org/toolboxes/gufo-runtime:latest via podman/Docker with
   `--device /dev/kfd --device /dev/dri --group-add keep-groups --ulimit memlock=-1`,
   or build (Nix / cmake presets + ROCm 7.2.3/GCC 15.3 + hipblaslt/rocblas).
   Notes: >= v0.5.0 mandatory (prompt-cache fix #335); `--served-model-name` must
   match client IDs; readiness on `/v1/models` not TCP; greedy default;
   `--cache-disk-staging-bytes 8589934592` for 262K Flash-Next.
3. Ollama (systemd drop-ins listed above) — fine for the 27B, not competitive
   for Flash-Next.
4. vLLM (TheRock nightly, TRITON_ATTN) — works but the two vault guides rate
   llama.cpp + Gufo higher for this silicon.

### GGUF checkpoints (unsloth mirrors, same lineage as the Spark GGUFs)
- unsloth/Qwen3.8-Flash-Next-GGUF UD-IQ4_XL (4 shards) + shared-Q8_0 MTP sidecar,
  mmproj-BF16.gguf for vision.
- unsloth/Qwen3.8-27B-GGUF Q4_K_XL / Q8_K_XL + z-lab/Qwen3.8-27B-DFlash2-GGUF.

## 3. What to mirror: the TensorFold Spark pattern (the repo's own gold standard)

`tasks/setup-tensorfold-spark-qwen38-flash.sh` + `tasks/setup-tensorfold-spark-qwen38-27b.sh`
+ shared `lib/tensorfold-helper.sh` + `templates/tensorfold-spark-qwen38-{flash,27b}/`
(models-entry.yml, serve.env). Structure to replicate:

- Pinned upstream recipe cloned to `/srv/<name>`, force-checkout converge on re-run.
- All shared steps factorized into a lib; per-task scripts keep only recipe constants.
- Pre-flight: docker, tooling (envsubst/python3+PyYAML/hf), llama-swap installed,
  hardware check (there: DGX Spark via nvidia-smi; here: gfx1151 via
  rocmsmi/PCI id or `amdgpu` detection), config.yaml writable BEFORE downloads,
  "what still needs downloading" gate (presence first, free-disk only for the
  missing pieces, converge on re-run with full disk).
- `.env` render that preserves operator-added keys (converge-by-default).
- Additive models.yml merge via `tasks/merge-model-entry.py`; llama-swap sync via
  `tasks/sync-models.py`; global healthCheckTimeout raise; smoke test through
  llama-swap with background trigger + bounded poll.
- `--check` status output, `--force`, `--skip-smoke`, `--help` kept exact.
- Model entries: llama-swap owns container lifecycle (serve.cmd / cmdStop / proxy),
  ttl: 0, aliases, agent contextWindow/maxTokens/reasoning/input metadata.
- AUTOMATIONS.md and machine-config-inference.yml.example updated in the same change.

## 4. Design decisions the plan must make (state trade-offs, pick defaults)

1. Engine per model: Gufo for both (best long-ctx/agentic, single stack) vs
   llama.cpp for the 27B (cheap, already half-automated by setup-llama-cpp.sh) +
   Gufo for Flash-Next. Or llama.cpp+ROCm-MTP for both with a tuning drop-in.
2. Whether a separate `setup-strix-halo-tuning.sh` (grub drop-in, sysctl, ZRAM off,
   verification probes, `--check`) is a prerequisite task the model setups gate on,
   or embedded checks.
3. Coexistence: both models loadable simultaneously here (unlike Spark); what do
   llama-swap `parallel`/ttl settings and the 120 GiB GPU reserve imply; port map.
4. Docker vs rootless podman for Gufo (container trap: keep-groups), templates/
   layout, `.env` at /srv/<svc>/.env, secrets policy from conventions.md.
5. Naming so the entries coexist with the Spark entries already in models.yml:
   e.g. `qwen3.8-flash-next-gufo` / `qwen3.8-27b-gufo` — the plain names are taken.
6. Idempotency of the kernel-parameter step (grub reboot required — how to detect
   and what to print; never silently reboot).
7. Per the repo conventions: scripts in tasks/, shared logic in lib/ (only what
   is genuinely shared), templates/<component>/, tests/README.md VM-based test
   plan, lint (shellcheck/yamllint), docs/research pointer, AUTOMATIONS.md update.

## 5. Repo conventions you must follow

Read `AGENTS.md`, `specification/project/conventions.md`,
`skills/kwisatz-assistant/SKILL.md`, and `lib/` before writing the plan.
Write the plan file to `docs/plans/<date>-strix-halo-qwen38-setup.md`.
Plan deliverable: tasks, file-by-file outline, acceptance criteria per task,
open questions. The plan will be implemented later in a feature branch —
plan only, do NOT implement.
