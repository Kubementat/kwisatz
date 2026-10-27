# Agent Prompt: Integrate Music Generation into kwisatz

date: 2026-10-22
status: ready-for-impl-agent
target_repo: kwisatz (remote `forgejo` — NEVER push to `origin`)
sibling_docs:
  - vault: `30-Reports/research-reports/2026-10-22-musicgen-service-on-evobox.md` (MusicGen FastAPI service on evobox, port 9293)
  - vault: kokoro-TTS install prompt (same two-part structure; keep this doc parallel to it)

---

## Context — target state / definition of done

Julian runs a jazz/funk/rap project (live instrumentation + AI). The lab needs **text-to-song
generation with vocals and lyrics**, self-hosted, reachable over HTTP like the other GPU
services. The MusicGen handoff (vault doc above) covers the **instrumental/SFX** workhorse
on evobox port **9293**. This task adds the **full-song** capability and packages the whole
music stack as a kwisatz task.

Definition of done:

1. On evobox (Strix Halo, gfx1151, 128 GB unified, Ubuntu 24.04): a vocals-capable song
   generator runs natively and answers over HTTP; verification blocks below all pass.
2. `tasks/setup-music-gen.sh` exists in kwisatz, shellcheck-clean, idempotent, discovered by
   `run-setup.sh`, with `--help` matching the implementation.
3. `machine-config.yml.example` and `AUTOMATIONS.md` updated; PR into `develop` on a worktree
   branch. No `VERSION` edits, no tags.

Recommended stack (justified in §Model survey):

- **Primary (vocals): ACE-Step 1.5** — MIT code *and* weights, official AMD/ROCm support,
  built-in async REST API (`acestep-api`, default :8001 → we use **9294**), confirmed working
  by owners on Strix Halo (ROCm 7.2) and RX 7000.
- **Fallback (vocals, maximally permissive): DiffRhythm 2** — Apache-2.0 code *and* weights,
  full-length songs with lyric alignment, diffusion-based (fast, non-AR).
- **Instrumental/SFX: MusicGen** — stays as per the vault plan (:9293), with a license caveat (§Survey).
- **Watchlist: YuE2** — best open benchmark quality, but weights need a commercial license
  for companies (free for individual musicians) and the pipeline is NVIDIA-oriented (24 GB VRAM). Do not install now.

---

## Part 1 — Install & run music generation

### 1.0 Prerequisites (mirror of the vault MusicGen doc Phase 0 — reuse, do not re-invent)

```bash
rocminfo | grep -m1 gfx1151 && ls -l /dev/kfd /dev/dri
groups | grep -E 'render|video'
python3 --version            # 3.11 or 3.12 required by ACE-Step
ss -tlnp | grep -E '929[0-9]' || echo "929x free"
df -h /media/storage         # ~15 GB for ACE-Step core models + ~25 GB for MusicGen set
```

### 1.1 Primary: ACE-Step 1.5 on evobox (native, systemd)

```bash
# venv with ROCm torch FIRST, then ACE-Step with --no-install-package torch so uv does not
# replace it with a CUDA wheel:
cd /opt && sudo mkdir -p ace-step && sudo chown $USER ace-step && cd ace-step
curl -LsSf https://astral.sh/uv/install.sh | sh
git clone https://github.com/ACE-Step/ACE-Step-1.5.git && cd ACE-Step-1.5
uv venv --python 3.12
uv pip install torch torchaudio --index-url https://download.pytorch.org/whl/rocm7.1
uv sync --no-install-package torch --no-install-package torchaudio
```

Environment for the service (`.env` in the repo dir — mirrors the ROCm pitfalls of the vault doc):

```ini
# gfx1151 is NATIVE: do NOT copy HSA_OVERRIDE_GFX_VERSION from the repo's
# start_*_rocm scripts — that override targets RDNA2/3 consumer cards and
# breaks gfx1151 ("no matching kernel image").
ACESTEP_LM_BACKEND=pt              # vLLM LM backend is CUDA-only; use PyTorch
MIOPEN_FIND_MODE=FAST
ACESTEP_CHECKPOINTS_DIR=/media/storage/ace-step-models
ACESTEP_API_KEY=<generate: openssl rand -hex 32>
ACESTEP_OFFLOAD_TO_CPU=false       # 128 GB unified: XL fits without offload
```

Verify GPU before serving:

```bash
uv run python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

Launch the REST API server (Gradio UI available on demand via `uv run acestep`):

```bash
uv run acestep-api --host 0.0.0.0 --port 9294 --config_path acestep-v15-xl-turbo --lm_model_path acestep-5Hz-lm-1.7B
```

Systemd unit `ace-step.service` (same pattern as the vault MusicGen unit: single process,
`LD_PRELOAD=/opt/rocm/lib/libhsa-runtime64.so.1` **only if** the torch smoke test segfaults —
per vault pitfall #2; `unset PYTORCH_HIP_ALLOC_CONF`; `render video` access via supplementary groups).

Smoke test (async API — task submitted, polled, audio fetched):

```bash
TASK=$(curl -s -X POST http://192.168.122.1:9294/release_task \
  -H "Authorization: Bearer $ACESTEP_API_KEY" -H 'Content-Type: application/json' \
  -d '{"prompt":"jazz funk fusion with rap vocals, upright bass, Rhodes","lyrics":"[verse]\nyour bars here","audio_duration":60,"thinking":true,"audio_format":"flac","vocal_language":"en"}' | jq -r .data.task_id)
until s=$(curl -s -X POST http://192.168.122.1:9294/query_result -H "Authorization: Bearer $ACESTEP_API_KEY" \
  -H 'Content-Type: application/json' -d "{\"task_ids\":[\"$TASK\"]}" | jq -r '.data[0].status'); [ "$s" = "1" ] || [ "$s" = "2" ]; do sleep 5; done
echo "status=$s"
```

Acceptance: status `1` and the returned audio URL serves a non-empty FLAC with audible vocals.
**ROCm output-format pitfall:** MP3 export can fail on ROCm builds (torchcodec/ffmpeg linkage).
Default the service and all clients to **flac or wav**. LoRA training additionally needs a
manually compiled `torchcodec` (see vllm's `install_torchcodec_rocm.sh`) — out of scope; inference only.

Model sizing on 128 GB unified memory: the ≥24 GB tier applies — `acestep-v15-xl-*` (4B DiT,
~9 GB weights) plus `acestep-5Hz-lm-1.7B` (or 4B LM) fit without offload. Turbo = 8 steps,
fast drafts; sft/base = 50 steps for final quality. Duration 10 s–600 s per generation.

### 1.2 Fallback: DiffRhythm 2 (Apache-2.0 everything)

Use if ACE-Step hits a gfx1151 blocker or if a downstream product needs belt-and-braces
licensing. Clone `ASLP-lab/DiffRhythm2`, same ROCm wheel source as §1.1, weights
`ASLP-lab/DiffRhythm2` (fp16 variants exist on the Hub). It is non-autoregressive block flow
matching → fast, full-length songs, precise lyric alignment. Wrap it later in the same
FastAPI pattern as the MusicGen service if adopted; verify with one English and one
German lyrics generation before wiring automation. Note: benchmark quality below ACE-Step
(WildSongBench 5.24 vs 6.01) and vocal style skews Mandarin-pop in some checkpoints — listen-check.

### 1.3 Instrumental/SFX: MusicGen (unchanged from vault plan)

Execute the vault handoff doc as-is on **:9293** (`transformers`, bf16, no HSA override,
`musicgen-stereo-large`, etc.). Do not duplicate its steps here. Add one line to your report
recording the **CC-BY-NC 4.0 weights license** (§Survey) so release decisions see it.

### 1.4 CPU-preview path (non-GPU machines, e.g. this Hermes VM)

`musicgen-small` via CPU torch wheels + uv venv in ~4 GB RAM, ~9× slower than realtime on
2 vCPUs — fine for prompt previewing before committing GPU time (verified in this lab).
ACE-Step also runs CPU-only (minutes per song, works out of the box per AMD community
reports) but is too slow for a 2-vCPU VM; keep the preview on musicgen-small.

### 1.5 Docker — decision: NO for the GPU host

`rocm/pytorch` images with `--device /dev/kfd --device /dev/dri` work on datacenter GPUs,
but for gfx1151 the container's ROCm userland must be ≥7.x and match the host driver;
community evidence for Strix Halo (e.g. `IgnatBeresnev/comfyui-gfx1151`) is exactly that —
a hand-adapted image. The vault decision (native install on the GPU host, systemd, same as
llama-swap) stands: fewer moving parts, direct access to the host's verified ROCm 7.x stack.
kwisatz's generic docker-first pattern is deferred: `templates/music-gen/` is **not** created
in v1; revisit only if a CUDA server also needs the service (then a CUDA-mode compose is
trivial). This trade-off is recorded in the AUTOMATIONS.md entry.

---

## Part 2 — kwisatz integration deliverables

Work in a `git worktree` feature branch off `develop`; PR into `develop`; remote **`forgejo`
only** (never `origin`). New `tasks/` script ⇒ MINOR bump, but **do not touch `VERSION` or
tags** — the user cuts releases.

1. **`tasks/setup-music-gen.sh`** — single task, GPU-host mode + client-preview mode.
   - Header: banner comment (Description/Options/Usage), `set -euo pipefail`,
     `SCRIPT_DIR`/`LIB_PATH` idiom sourcing `../lib/helpers.sh`, `show_help`.
   - Mode switch via env: `MUSIC_GEN_MODE=server|preview` (default `server`).
     - `server`: installs ACE-Step 1.5 per §1.1 into `/opt/ace-step`, writes
       `ace-step.service` + `.env` (mode 600, API key generated once, reused on re-run —
       "reuse secrets, converge by default" per `specification/project/conventions.md`),
       ufw-opens `MUSIC_GEN_PORT` (default 9294) to the LAN if `MUSIC_GEN_OPEN_LAN=true`.
     - `preview`: uv venv + CPU torch + `musicgen-small` + a tiny CLI (`~/music-preview`)
       for non-GPU boxes.
   - Env overrides: `MUSIC_GEN_PORT`, `ACESTEP_VERSION` (pinned tag),
     `ACESTEP_CHECKPOINTS_DIR` (default `/opt/ace-step/models`), `MUSICGEN_MODEL_DIR`,
     `MUSIC_GEN_PYTHON` (escape hatch), `FORCE`/`--force` (reinstall vs converge).
   - Idempotency: version marker file trick (see `setup-whispering.sh`), never clobber
     `.env` or checkpoints; re-run re-renders the unit and `systemctl restart`.
   - Built-in smoke test: `GET :9294/health`-equivalent + one 10-second DiT-only
     (`thinking=false`) generation, assert non-empty FLAC; exit non-zero on failure.
   - gfx1151 guard: script must refuse to set `HSA_OVERRIDE_GFX_VERSION` when
     `rocminfo | grep -q gfx1151`, and `unset PYTORCH_HIP_ALLOC_CONF` in the unit.
   - `shellcheck tasks/setup-music-gen.sh` clean; `--help` lists every env var above.
2. **`machine-config.yml.example`** — add next to the `setup-whispering` block (alphabetical
   fit under the same group), `yamllint`-clean:
   ```yaml
   setup-music-gen:
     enabled: false
     description: Install ACE-Step 1.5 song generation service (GPU) or CPU music preview
     env:
       MUSIC_GEN_MODE: server
       MUSIC_GEN_PORT: '9294'
     args: []
   ```
3. **`AUTOMATIONS.md`** — extend section `### Speech & Dictation` (rename to
   `### Speech, Dictation & Music` is allowed): add `#### setup-music-gen.sh` — 3–5 lines:
   ACE-Step 1.5 (MIT) REST API on :9294, native systemd on AMD gfx1151 GPU hosts (docker
   deliberately not used there — ROCm/userland matching), MusicGen instrumental service
   cross-referenced, CPU preview mode, MP3→FLAC ROCm pitfall.
4. **`templates/music-gen/`** — **skipped in v1** (see §1.5 docker decision). Re-add only
   with a justified CUDA-server use case.
5. **Workflow & quality gates**: worktree branch → shellcheck/yamllint (`.sh`/`.yml`) →
   run the VM-based automation test for the new task per `./tests/README.md` → PR into
   `develop` on `forgejo` → no tag, no `VERSION` change. Reuse `lib/` helpers (inspect
   `lib/` first, per AGENTS.md).

---

## Model survey (research basis, 2026-10-22)

| Model | License (code / weights) | Vocals+lyrics | Max length | VRAM | ROCm/gfx1151 | API server | Verdict |
|---|---|---|---|---|---|---|---|
| ACE-Step 1.5 | MIT / MIT | ✅ 50+ langs | 600 s | ≥4 GB DiT-only; XL 4B ≥12 GB (offload), ≥20 GB native | ✅ official ROCm support; Strix Halo + ROCm 7.2 confirmed by owners | ✅ `acestep-api` + Gradio + ComfyUI nodes | **Primary** |
| DiffRhythm 2 | Apache-2.0 / Apache-2.0 | ✅ lyric alignment | full song | modest (fp16 variants) | community, torch-ROCm standard | ❌ (wrap yourself) | **Fallback** |
| MusicGen family | MIT / **CC-BY-NC 4.0** | ❌ instrumental | ~30 s chunks | small→large 1–8 GB | ✅ proven in this lab | vault plan FastAPI :9293 | Instrumental/SFX workhorse; flag NC for any commercial release |
| YuE2-3B | Apache-2.0 repo; weights: free for individuals/musicians incl. monetized output, **companies need a commercial license** (HF card: CC BY-NC 4.0) | ✅ SOTA (beats Suno v5 on WSB best-of-8) | full song | 24 GB VRAM + 24 GB RAM, NVIDIA BF16 focus | ⚠️ unproven | ❌ (Python pipeline + agent skill) | Watchlist; personal use OK, commercial landmine |
| Stable Audio Open 1.0 | MIT code / Stability AI community-style weights ("commercial use → stability.ai/license") | ❌ | 47 s | ~10 GB | partial | ❌ | Skip — no vocals, short, license friction |
| TangoFlux family | mixed (variants Apache-2.0 / non-commercial) | ❌/humming | ~40 s | low | n/a | ❌ | Not notable enough vs ACE-Step in 2026 |

Quality context (WildSongBench, from YuE2 repo, 2026-09): YuE2 6.96 (best-of-8) > Suno v5
6.87 > ACE-Step 1.5 6.01 > DiffRhythm 2 5.24. ACE-Step compensates with speed (<10 s/song on
RTX 3090 turbo), editing features (cover, repaint, stems, vocal2BGM, LRC timestamps) and
LoRA training for Julian's own style — the practical pick for a self-hosted studio loop.

## License landmines found

- **MusicGen weights are CC-BY-NC 4.0** (all sizes, incl. stereo/melody) despite MIT code —
  the existing vault handoff does not mention this. Fine for private lab jams; must not be
  used in anything commercial/monetized.
- **YuE2 weights**: personal musicians may monetize output, but **companies require a paid
  commercial license**; HF model card additionally carries CC BY-NC 4.0 — ambiguous, keep out
  of any product.
- **Stable Audio Open**: commercial use requires a Stability license — avoid bundling.
- ACE-Step 1.5 and DiffRhythm 2 are clean MIT / Apache-2.0 end-to-end (verified on GitHub repo
  metadata and HF model cards on 2026-10-22).

## Sources (consulted 2026-10-22)

- https://github.com/ace-step/ACE-Step-1.5 — ACE-Step 1.5 features, MIT license, AMD/ROCm support, model zoo, XL VRAM tiers.
- https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/INSTALL.md — install/uv flow, ROCm launch scripts (HSA override warning), LM backends, model selection table.
- https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/API.md — async REST API (`/release_task`, `/query_result`), params (duration 10–600 s, thinking, audio_format), `ACESTEP_API_KEY`.
- https://huggingface.co/ACE-Step/Ace-Step1.5/discussions/4 — Strix Halo + ROCm 7.2 working report, comfyui-gfx1151 container, torchcodec/LoRA caveat.
- https://github.com/ace-step/ACE-Step/discussions/404 — RX 7900 XT ROCm fixes: LM backend `pt`, MP3 export failure on ROCm (use WAV/FLAC), float16 notes.
- https://huggingface.co/ASLP-lab/DiffRhythm2 + https://deepwiki.com/xiaomi-research/diffrhythm2/10.2-license-and-attribution — DiffRhythm 2 Apache-2.0 code+weights, full-length lyric-aligned songs.
- https://github.com/multimodal-art-projection/YuE — YuE2 quality/benchmarks, license terms (personal free / companies commercial license), 24 GB NVIDIA requirement.
- https://huggingface.co/facebook/musicgen-large (and musicgen-melody-large) — "Code MIT, weights CC-BY-NC 4.0".
- https://huggingface.co/stabilityai/stable-audio-open-1.0 — 47 s max, no vocals, commercial-use license friction.
- Vault: `/workspace/vault/30-Reports/research-reports/2026-10-22-musicgen-service-on-evobox.md` — environment facts, gfx1151 pitfall table, service pattern reconciled here.
