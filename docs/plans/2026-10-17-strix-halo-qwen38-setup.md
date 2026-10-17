# Plan: Qwen3.8-Flash-Next & Qwen3.8-27B on AMD Strix Halo (Gufo, managed by llama-swap)

**Date:** 2026-10-17 · **Branch:** `develop` (implementation goes into a `git worktree` feature branch) · **Status:** PLAN ONLY — this change ships no scripts, no templates, no lib.
**Research:** `docs/research/2026-10-17-strix-halo-llm-setup-context.md` (consolidated brief; vault sources: `2026-10-11-strix-halo-dgx-spark-llm-guide.md`, `gufo-strix-halo-inference-engine.md`, `2026-10-11-strix-halo-vs-dgx-spark-llm.md`, `2026-09-20-strix-halo-llm-ram-optimization.md`)
**Pattern to mirror:** `tasks/setup-tensorfold-spark-qwen38-flash.sh` + `…-27b.sh` + `lib/tensorfold-helper.sh` + `templates/tensorfold-spark-qwen38-{flash,27b}/` — the repo's own gold standard for "engine X, one machine, llama-swap-managed".
**Rules honoured here:** `specification/project/conventions.md` (Re-run policy: converge by default · Secrets and templating · Stack health verification · Templating), `AGENTS.md` (scripts in `tasks/`, shared logic in `lib/`, `templates/<component>/`, AUTOMATIONS.md kept current).

---

## 0. Scope

**Ships (all new; the working TensorFold/DGX-Spark path is untouched):**

| Kind | Path |
|---|---|
| machine-prep task | `tasks/setup-strix-halo-tuning.sh` |
| model tasks | `tasks/setup-gufo-strix-halo-qwen38-flash.sh`, `tasks/setup-gufo-strix-halo-qwen38-27b.sh` |
| shared library | `lib/strix-halo-helper.sh` |
| templates | `templates/strix-halo-tuning/`, `templates/gufo-strix-halo-qwen38-flash/`, `templates/gufo-strix-halo-qwen38-27b/` |
| docs/config | `AUTOMATIONS.md` (3 new entries), `machine-config.yml.example`, `CONTEXT.md` (2 new terms), cross-link from the research doc |

**Does not ship:** llama.cpp-on-`gfx1151` automation (only its serve-flag gaps are documented), vLLM/TheRock, rootless podman as the shipped runtime, native Gufo builds, any patch of upstream Gufo, and any change to `setup-llama-cpp.sh`, `setup-llama-swap.sh`, `sync_models/`, `merge-model-entry.py`, or the TensorFold tasks.

**Why this is a new family and not a flag on the Spark scripts:** the hardware gate, the memory story (120 GiB GTT reserve, both models *can* co-exist), the container device contract (`/dev/kfd`, `/dev/dri`, memlock), the readiness endpoint (`/v1/models`) and the whole machine-prep prerequisite are Strix Halo properties. The TensorFold tasks are hard-wired to `nvidia-smi`/CDI/`prepare.sh`; reusing them with flags would couple two working installs to one another (the same reasoning that ended the "one script with `--model`" discussion in `docs/plans/tensorfold-27b-llama-swap.md`, decision 1).

---

## 1. Recommended decisions (with the alternatives considered)

### D1 — Engine: **Gufo for both models**

| | Gufo (recommended) | llama.cpp Vulkan/RADV | llama.cpp ROCm |
|---|---|---|---|
| Flash-Next long ctx | validated: 131 K prefill 1335 tok/s (+886 %), 3.5 min for a 250 K cold prompt | 952 s for the same prompt; `--spec-type draft-mtp` hits the RADV DeviceLost bug (#27306) past ~10 K | ~10–15 % faster than Vulkan but needs the pinned `qwen4exp` fix and `--no-mmap` |
| 27B | DFlash2, 70.6 tok/s single / 123 tok/s @ 8 users | ~13–15 tok/s, single slot | similar to Vulkan |
| Ops | one container, `/v1/models` readiness, prompt cache (≥ v0.5.0 required) | already half-automated by `setup-llama-cpp.sh` | needs a ROCm-enabled llama.cpp build that `setup-llama-cpp.sh` does not do today |

**Recommendation:** Gufo v0.8.0 for both. The 27B also gets a *documented* llama.cpp alternative: the existing `qwen3.8-27b` catalog entry plus the gfx1151 flags (`-fa 1 --no-mmap -ngl 999`, §3.4) — no new script, because that route is a catalog/`setup-llama-cpp` concern and automating a second engine would double the surface (§10). The alternative "llama.cpp for the 27B + Gufo for Flash-Next" is **not** recommended: one engine per machine is the simpler operational story and Gufo is the only engine with validated numbers for both models on this silicon.

### D2 — Machine prep is a **prerequisite task**, not an embedded check

`setup-strix-halo-tuning.sh` owns GRUB (`amdgpu.gttsize`/`ttm.pages_limit`/IOMMU/gpu_recovery), ZRAM off, `vm.swappiness=10`, `loginctl enable-linger`, `rocm-smi`/`mesa-vulkan-drivers`, and every hardware verification probe. The two model tasks **source the same library and only read state** (never `update-grub`, never write `/etc/sysctl.d`, never touch GRUB).

Reasons: nothing in this repo writes GRUB or sysctl today (grep confirms zero `grub`/`sysctl`/`zram` usage), the blast radius is machine-wide and needs its own `--check`, and the "reboot required" message belongs to exactly one owner. The model tasks gate on it (§6.1) *before* any download.

### D3 — Container runtime: **rootful Docker**, image pinned by digest

* Repo standard (`setup-docker.sh`, ufw/traefik, and `cmdStop: docker stop …` in every llama-swap entry so far).
* llama-swap's service user defaults to `root` (`setup-llama-swap.sh` → `LLAMA_SWAP_USER`), so `--device /dev/kfd --device /dev/dri` works without the namespace gymnastics.
* The research's `--group-add keep-groups` / crun trap is a **rootless podman** problem. Shipping docker means the flag is unnecessary; the template keeps a single `CONTAINER_EXTRA_ARGS` lever so a podman operator can add `--userns=keep-id --group-add keep-groups` without editing files (§9, open decision A).
* `tests/lint.sh` guard 2 forbids floating `image:` references in `templates/` → the image arrives as `${GUFO_IMAGE}` and the task script renders a **digest pin** (`GUFO_IMAGE@sha256:…`), never `:latest`.

### D4 — Coexistence: **one model resident by default**, both-on is opt-in with reduced weights

Flash-Next IQ4_XS (93.7 GB) + 27B (17.7 GB) = ~112 GB of weights inside a 120 GiB GPU reserve, i.e. <10 GB of headroom for KV cache, the MTP/DFlash2 sidecars, page cache and the OS — the second load is an OOM/thrash roulette, not a slow start. Unlike the Spark pair this *is* physically possible (the Spark tasks say the opposite), so the difference is documented rather than engineered away:

* both entries ship `ttl: 0` (never auto-unload, Spark precedent) and each serve command is sized so **one** loaded model leaves a KV budget,
* `--check` prints a resident-memory budget line with the arithmetic,
* the documented co-load recipe is `Flash-Next IQ3_XS (82 GB) + 27B Q4_K_M (~18 GB)` with the KV/session knobs named in §3.5 — operator-side `.env` settings, not a script mode.

### D5 — Names and ports (must not collide with what `models.yml` already owns)

| | Flash-Next | 27B |
|---|---|---|
| catalog `name` | `qwen3.8-flash-next-gufo` | `qwen3.8-27b-gufo` |
| aliases | `Qwen3.8-Flash-Next-GGUF`, `qwen3.8-flash-gufo` | `qwen3.8-27b-dflash2` |
| container | `qwen38-flash-gufo` | `qwen38-27b-gufo` |
| service dir | `/srv/gufo-qwen38-flash` | `/srv/gufo-qwen38-27b` |
| host port (llama-swap proxies to it) | `8901` | `8902` |
| defaults | `GUFO_FLASH_PORT` | `GUFO_27B_PORT` |

Taken names avoided: `qwen3.8-flash-next` (TensorFold), `qwen3.8-27b` (`models.yml.default` llama.cpp), `qwen3.8-27b-tf` (TensorFold), aliases `qwen3.8`, `qwen3.8-27`, `Qwen3.8-Flash-Next`. **No case-only aliases** — same reasoning as the 27B-TensorFold entry (`AUTOMATIONS.md`): a client that lower-cases model ids must not silently land on a different runtime. Ports 8888/8889 belong to TensorFold; 8901/8902 collide with nothing in the repo (audited: 8000, 8010, 8080, 8084, 9000, 9090, 9292, 8888/8889, 11435, 1234, 2222/2224, 3000, 3333, 4096, 443, 5000, 5432, 5678, 6379, 6443, 6768, 3389).

`--served-model-name` must equal the catalog `name` (Gufo *rejects* unknown model ids — unlike llama.cpp), so the rendered entry passes `--served-model-name qwen3.8-flash-next-gufo`. Known limitation inherited from llama-swap (documented in `AUTOMATIONS.md` for the TensorFold 27B): the response's `model` field is the served name, not the requested id.

### D6 — Pinning: no recipe repo exists, so pin in three layers

TensorFold pins a recipe *repo* and calls its `prepare.sh`/`start.sh`. Gufo has no per-model recipe repo — **we own those two scripts ourselves** (rendered from `templates/…/gufo-{serve,prepare}.sh`, re-rendered on every run = converge). Pinning therefore becomes:

1. **engine:** `GUFO_IMAGE` (tag for humans) + `GUFO_IMAGE_DIGEST` (the pin actually used); record `gufo --version` after the first run in `/srv/<svc>/.engine-version`, re-check with `--check`, warn (never fail) on drift — the same bookkeeping shape as `tensorfold_checkpoint_revision_*` on the Spark 27B.
2. **weights:** `unsloth/Qwen3.8-Flash-Next-GGUF` (UD-IQ4_XL shards + shared-Q8_0 MTP sidecar + `mmproj-BF16.gguf`) and `unsloth/Qwen3.8-27B-GGUF` (Q4_K_XL) + `z-lab/Qwen3.8-27B-DFlash2-GGUF` (Q4_K_M). Revisions are **recorded, not pinned** (`.checkpoint-revisions`, reused helper) and drift is an advisory warning — same trade-off and the same residual risk statement as the Spark 27B, because pinning a `--revision` into the download line would make a normal re-run re-download 94 GB after an upstream push.
3. **layout:** `PROJECT_DIR`, `HF_CACHE_DIR`, ports — env vars, resolved after argument parsing (the review lessons F1/F3 apply verbatim).

### D7 — Kernel parameters: write-and-notify, never reboot, gate before the download

The tuning script renders the drop-in, runs `update-grub`, and prints `sudo reboot` — it never reboots and never `exit 0`s silently (conventions: "cases that cannot converge onto a running stack"). The model scripts read `/proc/cmdline` + `mem_info_gtt_total` before any download and **hard-fail** with the exact remediation command; `STRIX_ALLOW_UNTUNED=1` is the documented escape hatch for bring-up. (`STRIX_HW_CHECK=warn` is the CI/no-hardware escape hatch.)

### D8 — Two sibling scripts + one shared library

The Spark pair is the precedent: ~65 % of the two Strix Halo scripts (pre-flight order, download gate, pinned checkout equivalent, `.env` render, catalog merge, health-timeout raise, sync, smoke test, `--check` signals) is identical, so it lives in `lib/strix-halo-helper.sh`; per-model constants (checkpoint set, sizes, port, health timeout, template dir, model id) stay in the scripts. `lib/tensorfold-helper.sh` is **not** refactored and **not** sourced: its shared blocks are NVIDIA/CDI/`prepare.sh`-shaped and both consumers of it are working installs.

---

## 2. Design overview

```
                         Ubuntu Server 26.04, kernel >= 6.18.9, 128 GB unified
                         ┌──────────────────────────────────────────────────────┐
 T1 setup-strix-halo-    │  GRUB drop-in /etc/default/grub.d/99-kwisatz-…       │
    tuning.sh ──────────►│  GPU_RESERVE_GIB=120  ⇒ gttsize=122880,              │
   (writes + verifies)   │                        pages_limit=31457280          │
                         │  zram off · vm.swappiness=10 · linger · rocm-smi     │
                         └──────────────────────────────────────────────────────┘
                                        ▲  read-only checks (lib/strix-halo-helper.sh)
                                        │
 T2/T3 setup-gufo-strix-halo-qwen38-* ──┘
   ├─ pre-flight (docker, tooling, llama-swap, gfx1151, memlock, tuning state)
   ├─ "what still needs downloading?" gate (presence first, disk only for what is missing)
   ├─ pull pinned engine image · hf download shards (idempotent)
   ├─ render /srv/<svc>/{.env,gufo-serve.sh,gufo-prepare.sh} (converge; operator keys kept)
   ├─ merge catalog entry → models.yml (tasks/merge-model-entry.py, additive)
   ├─ raise llama-swap's GLOBAL healthCheckTimeout · tasks/sync-models.py
   └─ smoke test through llama-swap (background trigger + bounded poll)

 runtime: llama-swap (root, systemd, ProtectHome=read-only)
   serve.cmd = bash /srv/<svc>/gufo-serve.sh   → blocks on `docker run --rm …`
   cmdStop   = docker stop -t 30 qwen38-<model>-gufo
   proxy     = http://127.0.0.1:890{1,2}  ·  checkEndpoint = /v1/models  ·  ttl: 0
 API surface:  http://localhost:9292/v1  (model: qwen3.8-{flash-next,27b}-gufo)
```

**Structural difference vs TensorFold, stated once:** there is no upstream `prepare.sh`/`start.sh` to clone. The two wrappers we render *are* the recipe, which is exactly why the pinning story (D6), the file-list gate (§6.3) and the trust boundary need saying out loud in the new AUTOMATIONS entries: anyone who can write `/srv/gufo-qwen38-*` owns the host, because llama-swap (root) execs those files.

---

## 3. Hardware & memory contract

### 3.1 Facts the scripts assume

| Item | Value / source |
|---|---|
| Silicon | Ryzen AI MAX+ 395 · Radeon 8060S RDNA 3.5 · `gfx1151` |
| Memory | 128 GB unified LPDDR5X-8000, ~215–256 GB/s, no discrete VRAM → decode is bandwidth-bound |
| OS | Ubuntu Server 26.04 LTS, kernel **≥ 6.18.9** (6.18.4 has a `gfx1151` stability bug) |
| Host packages | `rocm-smi` (monitoring only), `mesa-vulkan-drivers`; `linux-firmware` for the iGPU |
| BIOS | UMA frame buffer 512 MB–2 GB (minimum); IOMMU disabled (~6–7 % bandwidth) |
| ROCm env in container | `HSA_OVERRIDE_GFX_VERSION=11.5.1`, `HSA_ENABLE_SDMA=0` |

### 3.2 The two knobs derived from one number (the known pitfall)

`GPU_RESERVE_GIB` (default **120**) is the single lever; both kernel knobs are computed from it, never copied from a blog post:

```
amdgpu.gttsize   = GPU_RESERVE_GIB × 1024        # MiB   → 122880
ttm.pages_limit  = GPU_RESERVE_GIB × 262144      # pages → 31457280
```

The full drop-in line additionally carries `amd_iommu=off amdgpu.noretry=0 amdgpu.gpu_recovery=1`. Guard: the widely-copied `gttsize=131072` + `pages_limit=31457280` pair disagrees by 8 GiB — `--check` reports a *mismatched-knobs* state explicitly when it finds it in `/proc/cmdline`, because that is the failure that looks like "the model just crashes at 90 GB".

### 3.3 Verification probes (`lib/strix-halo-helper.sh`)

| Probe | How | Verdict |
|---|---|---|
| Strix Halo present | `amdgpu` driver bound on a PCI device with `vendor 0x1002`, `device ∈ {0x15BF}` (Radeon 8060S), fallback: `rocm-smi --showid`/`rocminfo` mentioning `gfx1151` | hard error (`STRIX_HW_CHECK=warn` downgrades) |
| Kernel | `uname -r` ≥ 6.18.9 (sorted compare) | error, remediation `setup-upstream-kernel.sh` / apt upgrade + reboot |
| RAM | `MemTotal ≥ 125 GiB` | warn ("this recipe is sized for 128 GB") |
| GPU reserve | `/proc/cmdline` `amdgpu.gttsize=`/`ttm.pages_limit=` both present **and** consistent, plus `mem_info_gtt_total` readable on the amdgpu-bound `cardN` (glob `card*`, never `card1` — the index is not stable) | error + "reboot required" if written-but-inactive |
| Locked memory | dockerd's own `Max locked memory` (`/proc/$(pgrep -x dockerd)/limits`) | error with the exact `docker.service.d/` drop-in (restarting docker kills running stacks — say so) |
| Devices | `/dev/kfd` + `/dev/dri/renderD*` exist | error |
| Swap | `swapon --show` has no `zram*`; `vm.swappiness` ≤ 10 | warn |
| Engine | `docker image inspect ${GUFO_IMAGE}@${DIGEST}` + `gufo diagnose` | present / missing (drives the download gate) |

`--check` prints all of the above plus the memory budget and the llama-swap/catalog state; a non-Strix machine therefore degrades to one clear error line, like `tensorfold_require_dgx_spark` does.

### 3.4 Serve flags the Gufo entry must get right (from the validated runs)

* Flash-Next: 262 K context, adaptive MTP with the shared-Q8_0 sidecar, `--cache-disk-staging-bytes 8589934592` only when the RAM budget in §3.5 allows, `mmproj-BF16.gguf` for vision.
* 27B: `--speculative dflash2` + `z-lab/Qwen3.8-27B-DFlash2-GGUF` Q4_K_M draft (the same sidecar the Spark recipe uses), `--sessions` sized for multi-user.
* Both: `--host 127.0.0.1` + `--network host` + fixed port (loopback-only, API consumed through llama-swap — same trust posture as TensorFold's `HOST=127.0.0.1`), `--served-model-name <catalog name>`, readiness on `/v1/models`, greedy default documented (`chat_template_kwargs.enable_thinking:false` for the 32-token smoke request, exactly like the Spark smoke tests).
* If a llama.cpp path is ever wired: `-fa 1 --no-mmap -ngl 999`, `-b 256` for the MoE, and no `ngram-mod`/`draft-mtp` speculation on Vulkan. Note that `models.yml.default`'s `qwen3.8-27b` entry currently ships `--spec-type draft-mtp` with no `-fa/--no-mmap/-ngl`, i.e. it is *not* Strix-Halo-safe as-is (§9, decision C).

### 3.5 Memory budget shown in `--help` and `--check`

| Model | Weights | KV @16 K | KV @128 K | Sidecars | Note |
|---|---|---|---|---|---|
| Flash-Next UD-IQ4_XL | 93.7 GB | ~3 GB | 15–25 GB | MTP Q8_0, mmproj | fits inside a 120 GiB reserve, tight |
| Flash-Next UD-IQ3_XS | 82 GB | ~3 GB | 15–25 GB | " | the safe variant / co-load variant |
| 27B Q4_K_XL | 17.7 GB | ~4 GB | ~16 GB | DFlash2 ~1.5 GB | comfortable alone |
| both at once | 111.4 GB | — | — | | <10 GB headroom → not the default (D4) |

---

## 4. Task decomposition

Run in a feature branch; each row is one reviewable commit. "Dep" = must already be merged/applied.

| # | Deliverable | Dep | Done when |
|---|---|---|---|
| T1 | `lib/strix-halo-helper.sh` — hardware probes, GTT math, download gate, engine-pull, wrapper render, catalog merge/sync, smoke test, `--check` signals | — | shellcheck clean; sourced by all three tasks; every function guarded with `declare -F`, documented in the header like `lib/tensorfold-helper.sh` |
| T2 | `templates/strix-halo-tuning/{99-kwisatz-strix-halo.cfg,99-strix-halo-llm.conf}` + `tasks/setup-strix-halo-tuning.sh` (`--check`, `--reserve`, `--force`, `--help`) | T1 | writes nothing on a non-Strix box; re-run is a no-op; prints reboot hint exactly once; yamllint/n/a + shellcheck clean |
| T3 | `templates/gufo-strix-halo-qwen38-flash/` + `tasks/setup-gufo-strix-halo-qwen38-flash.sh` | T1, T2 | full converge-by-default install/converge path on a Strix Halo box; `--help` lists every flag *and* env var it actually reads |
| T4 | `templates/gufo-strix-halo-qwen38-27b/` + `tasks/setup-gufo-strix-halo-qwen38-27b.sh` | T1, T2, T3 | same for the 27B; the two scripts differ only in constants (§5.3) |
| T5 | Cross-service polish: sibling port check, coexistence text, trust-boundary text | T3, T4 | a box with both installed prints no false alarms |
| T6 | `AUTOMATIONS.md` ×3 entries, `machine-config.yml.example` ×3 entries, `CONTEXT.md` ×2 terms | T1–T4 | `./run-setup.sh status` parses the example config with the new entries; docs match the scripts |
| T7 | Test/verification pass (VM run where runnable + the manual checklist in §8) | T1–T6 | §8 all green, findings folded back into the scripts |
| T8 | Optional: `specification/features/strix-halo-gufo-qwen38/behaviors.md` | T6 | open decision D (below) |

Dependency graph: `T1 → (T2 ∥ nothing) ; T1 → T3 → T4 → T5 → T6 → T7`. T2 and T3 can be built in parallel once T1's function signatures are frozen — freeze them in the first 30 lines of T1's commit message/description.

---

## 5. File-by-file outline

### 5.1 `lib/strix-halo-helper.sh` (new, ~450–600 lines)

Header block: purpose (shared logic for the three Strix Halo tasks), usage (source `lib/helpers.sh` first, then this), what it deliberately does *not* share with `lib/tensorfold-helper.sh` and why. All definitions `if ! declare -F … > /dev/null 2>&1; then … fi`, publishing `STRIX_*` globals that callers read once.

| Function | Contract |
|---|---|
| `strix_require_docker`, `strix_require_tooling`, `strix_require_llama_swap` | Same messages/exit codes as their tensorfold twins (`docker info`, `envsubst`/`python3`+PyYAML/`hf`, `/srv/llama-swap` + `systemctl cat llama-swap`). Plus: warn when `LLAMA_SWAP_USER` is not in the `docker` group. |
| `strix_hal_gpu` | Detection + human name, sets `STRIX_GPU_OK`/`STRIX_PCI_ID` (§3.3) |
| `strix_require_strix_hal <sizing_note>` | Hard gate (or warn with `STRIX_HW_CHECK=warn`), prints the sizing sentence |
| `strix_require_kernel_and_ram` | Kernel ≥ 6.18.9 (error), RAM ≥ 125 GiB (warn) |
| `strix_gtt_state` | Parses `/proc/cmdline` + `mem_info_gtt_total`; sets `STRIX_GTT=active\|inactive\|mismatched\|absent`, `STRIX_REBOOT_REQUIRED`, `STRIX_RESERVE_GIB_DETECTED`; one derived-vs-actual comparison helper so the "mismatched knobs" case is its own message |
| `strix_require_tuning` | Calls the three above; when not active: `error` with the exact `GPU_RESERVE_GIB=… ./tasks/setup-strix-halo-tuning.sh && sudo update-grub && sudo reboot` and the `STRIX_ALLOW_UNTUNED=1` note. Called **before** the download gate. |
| `strix_require_locked_memory` | dockerd memlock check + exact systemd drop-in remediation |
| `path_has_gguf_snapshot <dir> <file>…` | The GGUF-shaped analogue of `path_has_hf_snapshot`: the snapshot dir must contain *every* required `.gguf` (weights, sidecar, mmproj). Revision deliberately not part of the probe (a cache populated under another revision is still a finished download). |
| `strix_resolve_pending_downloads` | Options `--model-label/--model-gb/--image-gb/--repo-dir/--required-from <script> --image-ref --hf-cache/--quiet`; presence first, `require_free_space` only for what is missing; sets `STRIX_NEEDS_MODEL`/`STRIX_NEEDS_IMAGE`/`STRIX_PENDING_GB`/`STRIX_PENDING`. The required-file list is read from the *wrapper* (`gufo-prepare.sh --list-files`), so there is exactly one list of weights in the tree (§5.2) |
| `strix_pull_engine_image <ref>` | `docker pull --quiet` guarded by "already present"; converges offline when present |
| `strix_render_wrapper <template> <target> <varlist…>` | envsubst as the invoking user into `mktempfile`, install `sudo install -m 0755`; never `sudo envsubst` |
| `strix_render_serve_env <template> <target> <port>` | Copy of `tensorfold_render_serve_env`'s converge semantics (keys we own = `PORT`, `GUFO_*` layout keys; every other `KEY=` line the operator added is carried over verbatim; mode 600 via `env_file_write`). Kept as a copy, not a call, because the tensorfold one is tied to `FOREGROUND`/`HOST` semantics we no longer need — say so in a comment |
| `strix_merge_model_entry` / `strix_sync_llama_swap` / `strix_llama_swap_raise_health_timeout` | Thin wrappers over `tasks/merge-model-entry.py`, `tasks/sync-models.py` and the global `healthCheckTimeout` raise (identical contract to the tensorfold twins, including the "the raise touched config.yaml but the sync wrote nothing → restart llama-swap ourselves" case) |
| `strix_smoke_test` / `strix_require_llama_swap_up` | Same shape as the tensorfold ones (background trigger + bounded `/running` poll + assert a non-empty answer; `--skip-smoke` still proves `/health` + `/v1/models`). One change: the readiness endpoint is `/v1/models`, because Gufo opens its port before the weights are resident |
| `strix_record_engine_version` / `strix_checkpoint_revision_{record,recheck}` | Version/revision bookkeeping under `/srv/<svc>/.engine-version` and `.checkpoint-revisions`, advisory only |
| `strix_status_*` | The `--check` vocabulary: `engine`, `weights`, `gtt`, `swap`, `disk`, `catalog`, `llama-swap entry`, `llama-swap writable`, `container`, `proxy`, `memory budget`, `engine version drift` |

Deliberately **not** here: the GRUB/sysctl writers (T2 only — sourcing them into a model script would let a model install rewrite a kernel command line).

### 5.2 `templates/strix-halo-tuning/` + `tasks/setup-strix-halo-tuning.sh`

```
templates/strix-halo-tuning/
  99-kwisatz-strix-halo.cfg   # GRUB drop-in; envsubst: ${GTT_SIZE_MIB} ${TTM_PAGES_LIMIT} ${EXTRA_ARGS}
  99-strix-halo-llm.conf      # sysctl: vm.swappiness=${VM_SWAPPINESS}
```

`setup-strix-halo-tuning.sh` (~350 lines), flags `--reserve <GiB>`, `--check`, `--force`, `--skip-update-grub`, `--help`; env `GPU_RESERVE_GIB` (120), `VM_SWAPPINESS` (10), `AMDGPU_EXTRA_ARGS`, `STRIX_INSTALL_PACKAGES` (1).

Steps (each guarded): pre-flight (Ubuntu, root via sudo, Strix Halo gate) → `apt` packages (`rocm-smi`, `mesa-vulkan-drivers`, `linux-firmware`; skip list = `STRIX_INSTALL_PACKAGES=0`) → render the GRUB drop-in to `/etc/default/grub.d/99-kwisatz-strix-halo.cfg` (mode 644, one-shot `.bak` of a pre-existing foreign file, then `update-grub` unless `--skip-update-grub`) → render the sysctl drop-in → disable ZRAM (detect `swapon --show | grep zram`, `swapoff /dev/zramN` + mask the unit that created it; **never** removes packages, prints what it found) → `loginctl enable-linger` → probes → status.

Converge/idempotency: re-running re-renders both files from templates and re-runs `update-grub`; nothing else changes. **The reboot case is the documented non-convergeable case:** if `/proc/cmdline` ≠ the rendered values, print "written, not active — `sudo reboot`" and exit 0. `--check` prints every probe with the *derived* expectation and the *detected* value side by side. Never reboots, never prompts (no `--interactive` in v1: everything is a re-render or a printed command).

### 5.3 `templates/gufo-strix-halo-qwen38-flash/` (mirror layout for `-27b`)

```
models-entry.yml   # catalog fragment (rendered, merged additively into models.yml)
serve.env          # → /srv/gufo-qwen38-flash/.env  (mode 600, converged)
gufo-serve.sh      # → /srv/…/gufo-serve.sh   (blocking `docker run --rm`)
gufo-prepare.sh    # → /srv/…/gufo-prepare.sh (file list + hf download + marker)
```

**`models-entry.yml`** — same skeleton as the TensorFold entries (`providers[local].baseUrl = http://localhost:${LLAMA_SWAP_PORT}/v1`), which means **zero changes to `sync_models/`** — everything extra goes through the existing `llamaSwap:` pass-through:

```yaml
- name: qwen3.8-flash-next-gufo          # qwen3.8-flash-next = the TensorFold entry
  type: local
  env:
    - {name: HF_CACHE,     value: ${HF_CACHE_DIR}}
    - {name: STATE_DIR,    value: ${STATE_DIR}}
    - {name: GUFO_MODEL,   value: ${GUFO_MODEL}}      # absolute shard path, resolved at render time
  download:
    - >-
      [[ -f ${STATE_DIR}/prepared ]] || bash ${PROJECT_DIR}/gufo-prepare.sh
  serve:
    cmd: "bash ${PROJECT_DIR}/gufo-serve.sh"
  llamaSwap:
    cmdStop: "docker stop -t 30 qwen38-flash-gufo"
    unloadTimeout: 60
    proxy: "http://127.0.0.1:${GUFO_FLASH_PORT}"      # 8901 (27B: 8902)
    checkEndpoint: "/v1/models"                        # NOT /health: Gufo binds before the load
    ttl: 0
    aliases: ["Qwen3.8-Flash-Next-GGUF", "qwen3.8-flash-gufo"]
  agent:
    contextWindow: 262144
    maxTokens: 32768
    reasoning: true
    input: [text, image]
```

**`serve.env`** — layout keys only (`PORT`, `CONTAINER_NAME`, `STATE_DIR`, `HF_CACHE`, `HSA_OVERRIDE_GFX_VERSION=11.5.1`, `HSA_ENABLE_SDMA=0`, `GUFO_CACHE_DISK_STAGING_BYTES`, `GUFO_SESSIONS`, `GUFO_EXTRA_ARGS`, `CONTAINER_EXTRA_ARGS`). A re-run re-renders these and keeps every other line the operator added; a comment says where Gufo's own flags live (`gufo serve --help`) and that `GUFO_EXTRA_ARGS` is the escape hatch without editing files. No secret is ever substituted into a file (conventions §Secrets): `HF_TOKEN` stays a literal `${HF_TOKEN}` referenced from `.env`, and `.env` is mode 600.

**`gufo-serve.sh`** — the runtime contract: `set -eu`, source `.env`, resolve the newest usable snapshot dir under `$HF_CACHE/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots/`, then
`exec docker run --rm --name "$CONTAINER_NAME" --network host --device /dev/kfd --device /dev/dri --ulimit memlock=-1 --shm-size "${GUFO_SHM_SIZE:-16g}" -v "$SNAPSHOT:/models:ro" "$GUFO_IMAGE" gufo serve llm --host 127.0.0.1 --port "$PORT" --model /models/<shard> --served-model-name <catalog name> … $GUFO_EXTRA_ARGS`.
It blocks for the container's lifetime (llama-swap tracks it), stops cleanly on `docker stop`, and prints a one-line memory-budget note. Absolute paths, `set -eu`, no `|| true`.

**`gufo-prepare.sh`** — the one source of truth for "which files are required": `REPO_FILES=(…)` + `--list-files` (consumed by the download gate) + `hf download` for each missing file + `docker pull` + write `$STATE_DIR/prepared` with the resolved revisions recorded. Guarded so a re-run is three `test`s.

### 5.4 `tasks/setup-gufo-strix-halo-qwen38-flash.sh` (~380 lines; 27B is the same shape)

Header comment mirrors the TensorFold scripts (what it installs, the pinned upstream, the workflow, the trust boundary, "shared logic lives in `lib/strix-halo-helper.sh`", usage).

Flags: `--port`, `--health-timeout`, `--dir`, `--hf-cache`, `--state-dir`, `--quant <label>`, `--force`, `--skip-smoke`, `--check`, `--help`.
Validation of the **final** values happens after parsing (`strix_validate_serving_settings`), and defaults that depend on `--dir` resolve after parsing — both are known TensorFold review lessons, so the plan carries them forward instead of re-learning them.

Order of operations (the whole converge story, identical for both scripts):

1. `--check` early-exit path (shared status vocabulary).
2. Pre-flight: docker → tooling → llama-swap → Strix Halo gate (GPU, kernel, RAM) → **tuning state** → memlock/devices/swap.
3. "What still needs downloading?" (weights via `path_has_gguf_snapshot` + the wrapper's file list; engine image via `docker image inspect`) → free disk **only for the missing pieces** (`STRIX_FLASH_MIN_FREE_GB=110`, `GUFO_IMAGE_GB=25`; 27B: 45/25).
4. llama-swap `config.yaml` writability probe (read-only, silent when there is no config yet) — same reason as TensorFold: a cold install must not burn 94 GB against a `root:root 644` file.
5. `--force` → stop the running container.
6. Engine pull (only if missing) → dirs (`/srv/<svc>`, `.state`, mode 755, owned by the invoking user; never chown `/srv` itself).
7. Render `.env`, `gufo-serve.sh`, `gufo-prepare.sh` (converge; mode 600 / 0755).
8. `gufo-prepare.sh` (weights; records revisions; writes the marker).
9. Merge the catalog entry (`merge-model-entry.py`, replace-only-if-changed; `--force` re-writes) → raise the global `healthCheckTimeout` (`GUFO_FLASH_HEALTH_TIMEOUT=1800`, 27B `600`) → `sync-models.py` (restart llama-swap only on change / only-on-raise, poll `/health`).
10. Smoke test through llama-swap, or `strix_require_llama_swap_up` + a loud warning with `--skip-smoke`.
11. Summary box: paths, ports, model ids, load/unload commands, `--check`, memory budget, the coexistence note, and the stale-container hint (`docker rm -f qwen38-…-gufo`) that llama-swap restarts while a container is running always produce.

**Env vars (defaults), both scripts:** `GUFO_{FLASH,27B}_PORT` (8901/8902), `GUFO_{FLASH,27B}_HEALTH_TIMEOUT` (1800/600), `PROJECT_DIR` (`/srv/gufo-qwen38-{flash,27b}`), `HF_CACHE_DIR` (`~/.cache/huggingface`), `STATE_DIR` (`$PROJECT_DIR/.state`), `LLAMA_SWAP_PORT` (9292), `LLAMA_SWAP_DIR` (/srv/llama-swap), `GUFO_IMAGE` / `GUFO_IMAGE_DIGEST`, `GUFO_MODEL_REPO` / `GUFO_MODEL_REVISION` (empty = latest, D6), `CONTAINER_RUNTIME` (`docker`), `CONTAINER_EXTRA_ARGS`, `GUFO_EXTRA_ARGS`, `GPU_RESERVE_GIB` (read-only here), `STRIX_ALLOW_UNTUNED`, `STRIX_HW_CHECK`, `*_MIN_FREE_GB`, `GUFO_IMAGE_GB`, `SKIP_SMOKE`, `FORCE`.

**Docs:** `--help` sections `Requirements` (Strix Halo, kernel ≥ 6.18.9, GPU reserve active, llama-swap + docker, ~110 GB free for a cold install, `hf` CLI), `Free disk`, `Runtime model`, `Coexistence`, `Re-run policy`, `Trust boundary` — kept exact with the implementation, per AGENTS.md.

### 5.5 Documentation and config files

**`AUTOMATIONS.md`** — three new `####` entries under *AI & LLM Services*, next to the two TensorFold ones (same voice: what it deploys → *Features:* bullets). The Flash/27B entries must each carry: pinned engine image (digest) + how version drift is reported, the checkpoint repos/quantisations and "revisions recorded, not pinned — residual risk" line, the port and `checkEndpoint: /v1/models` rationale, the health-timeout raise, the "weights presence first, disk only for what is missing" gate, the llama-swap `config.yaml` writability probe, the smoke-test shape and `--skip-smoke` semantics, the **trust boundary** (`llama-swap` (root) execs `gufo-serve.sh` out of `/srv/…`), the memory budget with the coexistence rule, and "shared logic lives in `lib/strix-halo-helper.sh`". The tuning entry carries the `GPU_RESERVE_GIB` single-knob rule, the mismatched-knobs pitfall, ZRAM/swappiness/linger, the "written but not active ⇒ reboot" state and that the script never reboots.

**`machine-config.yml.example`** — three `enabled: false` entries after the TensorFold pair, each with a `description`, the env vars an operator actually changes, and the dependency comment (needs `setup-docker`, `setup-llama-swap`, and for the model scripts `setup-strix-halo-tuning`; ~110 GB free disk). Extend the existing header comment that already warns "these GPU recipes request the GPU …" to say plainly: **TensorFold/Spark recipes and the Strix Halo recipes are mutually exclusive per machine** (they detect different hardware and would both fail their gate).

**`CONTEXT.md`** — add `strix halo` (AMD Ryzen AI MAX+ unified-memory platform, `gfx1151`) and `gufo` (Strix-Halo-specific local inference engine, HIP/`gfx1151`, OpenAI-compatible, llama-swap-managed here), plus `GTT reserve` under Infrastructure if the terminology review wants it (open decision D).

**`docs/research/2026-10-17-strix-halo-llm-setup-context.md`** — add a one-line *Implemented by* pointer to this plan (the existing research docs do the same). `README.md` needs no change beyond (optionally) the "which scripts exist" list, since `run-setup.sh status` is the discovery surface.

---

## 6. Cross-cutting behaviour

### 6.1 One order, both scripts
`status → pre-flight sanity → hardware gate → tuning gate → memlock/devices → download gate → config.yaml writability → force-stop → engine pull → dirs → render wrappers/.env → prepare (weights) → version/revision record → catalog merge → healthCheckTimeout raise → sync → smoke (or up-check) → summary`.
The gate order **is** the design: an untuned box and an unwritable `config.yaml` are both discovered in seconds, *not* after 94 GB of downloads. `--check` walks the same list in the same order.

### 6.2 Converge-by-default matrix

| Existing state | Re-run does |
|---|---|
| weights cached, image present, entry merged, llama-swap running | re-render wrappers + `.env` (operator keys preserved), `prepare.sh` short-circuits, `merge-model-entry.py` no-ops, `sync-models.py` writes nothing, no restart, smoke test passes in seconds |
| `/proc/cmdline` ≠ rendered GRUB values | print written-vs-active, the exact `update-grub && sudo reboot` command, **exit 0** |
| engine image missing | `docker pull` the pinned digest (needs the free-disk check) |
| operator changed `.env` levers | keys we own are re-rendered, every other `KEY=` line carried over verbatim, mode 600 |
| weights on disk but newer upstream revision | advisory warning + the recorded-vs-current comparison, then converge (no re-download) |
| only the `healthCheckTimeout` raise changed `config.yaml` | restart llama-swap ourselves (the add-only sync would not), poll `/health`, print the stale-container hint |
| weights missing **and** disk short | hard error naming the missing pieces, the free-space number and `hf cache rm`/`HF_CACHE_DIR=` remediation (never a silent partial download) |
| port collision with the sibling install | `strix_sibling_port_warning`-style advisory from the sibling `.env`'s `PORT` |
| anything not convergable (e.g. `PROJECT_DIR` exists but is not ours, dirty wrapper dir) | name what diverges + the exact command to fix it; never `exit 0` silently |

Conventions are explicit that changing `--port`/`--dir`/`--hf-cache` on an existing install does **not** rewrite the llama-swap entry (add-only `sync_models/`), even though `models.yml` is updated — `--help` repeats the documented fix (delete the model's section from `config.yaml`, re-run).

### 6.3 Single source of truth for the weight file list
`gufo-prepare.sh --list-files` is what the download gate probes *and* what the prepare step downloads. A second copy of the list in the task script would drift on the first upstream file rename (and silently turn "cached" into "not cached"); the cost of routing through the wrapper is one `bash … --list-files` call.

### 6.4 Health verification (conventions §Stack health verification)
No `docker compose up -d` here — llama-swap owns the lifecycle — so the gate is `strix_require_llama_swap_up` (bounded `/health` poll + `/v1/models` contains the id) plus the smoke test's bounded `/running` poll. `docker run --rm` inside `serve.cmd` means the container is verified **by** the smoke test rather than by `wait_for_healthy`; that is stated in the script comment so the reviewer does not look for a `wait_for_healthy` call that does not belong. `GUFO_*_HEALTH_TIMEOUT` is the documented, long-by-default timeout and appears in `--help`. Never `|| true` on anything upstream of the gate; no success banner before it.

### 6.5 Secrets & templating
Templates keep `${VAR}` for anything secret (future `HF_TOKEN` is referenced, never substituted); layout values (ports, paths, snapshot dir, network name) are `envsubst`ed. Every render writes a `mktemp` file as the invoking user and installs with `sudo install -m 600` (`.env`) / `-m 0755` (wrappers); `sudo envsubst` is never used. `.env` is read back before writing (`env_file_get`/`env_file_write`).

### 6.6 Lint & style
`shellcheck` clean on all four `.sh` files (the templates' wrappers too — they are shell code, so they get `shellcheck` in the review gate); `yamllint` with `templates/.yamllint` on `models-entry.yml` + `machine-config.yml.example`; `jq`-validity is n/a (no JSON); `./run-setup.sh -c machine-config.yml.example status` parses. `tests/lint.sh` guard 2 (no floating image refs) must stay green — the Gufo image arrives as a placeholder.

---

## 7. Acceptance criteria

**T1 lib** — sourced by three tasks; no duplicate-definition warnings; shellcheck clean; every probe from §3.3 implemented and used by both a task run and `--check`; compiles no behaviour that only exists for one model.

**T2 tuning** — cold run writes exactly two files (`/etc/default/grub.d/99-kwisatz-strix-halo.cfg`, `/etc/sysctl.d/99-strix-halo-llm.conf`) and one `.bak` if a foreign file was there; second run changes nothing and prints `reboot required` only when `/proc/cmdline` says so; `GPU_RESERVE_GIB=116` yields `gttsize=118784`/`pages_limit=30408704` (the single-knob rule, tested with `--skip-update-grub`); a non-Strix box aborts before writing anything; no package removal; no reboot; `--help` complete.

**T3/T4 model tasks** — on a tuned Strix Halo box: install → `--check` green → re-run converges in seconds without a restart or a download → smoke test answers through `http://localhost:9292/v1/chat/completions`. Untuned box: aborts in <5 s with the remediation command and downloads nothing. Full disk + everything cached: converges. `--skip-smoke`: still proves `/health` + `/v1/models`, prints the "model not exercised" warning. `--check` twice: byte-identical output. Both entries appear in `models.yml` and in `config.yaml` without disturbing the existing `qwen3.8-*` entries (additive merge verified with a temp `models.yml`). Catalog `name`/`alias` audit: no duplicate/overlapping alias with the TensorFold + llama.cpp entries.

**T5/T6 docs** — `AUTOMATIONS.md` entries and `machine-config.yml.example` match the scripts' flags/env vars 1:1; `./run-setup.sh status` parses the example; the mutual-exclusion note is in the config file, not only in the plan.

**T7** — §8 checklist executed with the findings applied; `git log` shows one commit per T-row.

---

## 8. Verification plan

**Automated (VM suite, `tests/README.md`):** these scripts are **not** added to `machine-config.test.yml`'s default set — they need AMD `gfx1151` hardware, ≥110 GB of weights, and one of them edits GRUB. Run them ad hoc with `--scripts` and a big VM only for the *negative* paths, which are the interesting ones in a VM:

| Run | Expect |
|---|---|
| `setup-strix-halo-tuning.sh --check` on a plain VM | clean "not a Strix Halo" verdict, no writes |
| `setup-gufo-strix-halo-qwen38-27b.sh` on a plain VM | error at the hardware gate in seconds, no download, no `config.yaml` write |
| `… --help` / `--check` | exit 0, complete text |
| `merge-model-entry.py` against a temp `models.yml` | entry added once; replaced only on template change; `--force` re-writes |

**Manual (one Strix Halo box — the real gate):**

1. BIOS: UMA min, IOMMU off. `setup-docker.sh` → `setup-strix-halo-tuning.sh` → `update-grub` → reboot → `--check` green (GTT `active`, 120 GiB derived == detected).
2. `setup-llama-swap.sh`, then the 27B task (`--skip-smoke` for the first pass) → smoke → `bash -c 'time …'` decode sanity check against the reported ~70 tok/s.
3. Flash-Next task; watch the first load against `GUFO_FLASH_HEALTH_TIMEOUT`; then a 200 K-prompt agentic session to confirm the prompt cache (≥ v0.5.0, D6) actually engages.
4. Convergence drills: re-run both tasks with the weights cached on a nearly-full FS; re-run after adding a fake lever to `.env`; kill the container while llama-swap thinks it is loaded and confirm the recovery hint; stop llama-swap, re-run, confirm the entry and `healthCheckTimeout` survive.
5. Coexistence drill (§3.5): load both deliberately at defaults and confirm the failure is *loud* and documented, not an OOM-killer surprise; then with the IQ3_XS variant, confirm both stay resident.
6. `shellcheck` + `yamllint` + `bash -n` all new files.

---

## 9. Open design decisions (resolve in review, defaults chosen)

**A. Runtime: docker now, podman later.** The `keep-groups`/crun trap only exists rootless. Default = rootful docker (§1 D3). If `CONTAINER_RUNTIME=podman` is wanted, the delta is one template line + `--userns=keep-id --group-add keep-groups` + `crun`, plus `--user` mapping into the model dir — a follow-up ticket, not a v1 flag, because nobody can test it without a podman-only box. *Recommendation: keep the `CONTAINER_EXTRA_ARGS` lever, ship docker.*

**B. Eviction/coexistence.** `ttl: 0` on both (Spark precedent) means "load the second → the first is still resident → the second may not fit". Alternatives: `ttl: 900` on the 27B so llama-swap eventually frees 18 GB, or accept it and document. *Recommendation: `ttl: 0` + a `--check` memory-budget line + the documented co-load recipe; revisit `ttl` only if someone actually gets bitten.*

**C. Should the 27B ship a second (llama.cpp) entry?** No: the llama.cpp route is the existing `qwen3.8-27b` entry plus gfx1151 flags, which is a `setup-llama-cpp.sh`/catalog concern, not a Gufo task. The *flag gap* is real and concrete — `models.yml.default`'s `qwen3.8-27b` entry has no `--no-mmap`/`-ngl 999`/`-fa 1` (all required on `gfx1151` per the research) **and** enables `--spec-type draft-mtp`, the configuration the guide reports as hitting the RADV device-lost failure on Strix Halo. On this machine that entry is therefore expected to be unreliable, which is the strongest argument for the Gufo entry — but fixing the shared default is a separate, hardware-independent change. *Recommendation: document it in the AUTOMATIONS entry and open a separate ticket for the llama.cpp-on-Strix-Halo script (or a `--strix-flags` variant of `setup-llama-cpp.sh`); do not touch the shared default in this change.*

**D. Feature spec folder?** `specification/features/strix-halo-gufo-qwen38/behaviors.md` would match the `vllm-omni-setup` precedent but duplicates §2/§6 of this plan. *Recommendation: skip for v1 (T8 optional); add `CONTEXT.md` terms only.*

**E. `:latest` vs tag vs digest for `ghcr.io/gufo-org/toolboxes/gufo-runtime`.** `tests/lint.sh` forbids a floating tag in a template, so the script needs a concrete pin. *Recommendation: a `GUFO_IMAGE` tag **and** a `GUFO_IMAGE_DIGEST` the script composes, refreshed by a documented "bump the pin" checklist; verify during T3/T4 that the registry publishes the digest for the tag (if not, pin the tag and record the digest the run resolved in `.engine-version`, same bookkeeping as the weights).*

**F. `GPU_RESERVE_GIB` default 120 vs 116.** 120 GiB (≈8 GiB OS headroom) is what the headless-inference guides use and what the IQ4_XS + KV budget needs; 116 GiB is the "dev box that also runs a desktop" number. *Recommendation: 120 default, one env var away from 116, with the `--check` line printing the headroom arithmetic.*

**G. Engine-level cache/disk staging.** `--cache-disk-staging-bytes 8589934592` is a documented 262 K-context lever but costs 8 GiB resident. *Recommendation: default **off**, exposed as `GUFO_CACHE_DISK_STAGING_BYTES`, with the trade-off in `--help`.*

---

## 10. Risks, mitigations, and what stays out of scope

| Risk | Mitigation |
|---|---|
| Gufo is young (v0.8.0, 2026-10-05); API/CLI flags may move | pin the image digest, `gufo diagnose` in the prepare step, `GUFO_EXTRA_ARGS` lever, version-drift warning in `--check`; the serve command lives in **one** template file, so a bump is a one-line change |
| 94 GB weights × 110 GB of disk × 120 GiB of RAM = the failure mode is always "almost fits" | presence-first download gate, per-piece disk numbers, `--check` memory budget, IQ3_XS documented as the safe quant, `--quant` flag to switch shards |
| MTP/speculation instability (Vulkan #27306 for llama.cpp, adaptive MTP in Gufo) | Gufo path only; speculation flags default to what the validated runs used and sit in `GUFO_EXTRA_ARGS`; the smoke test is deliberately a 32-token request so it cannot trip a long-context bug |
| Silent kernel-command-line mismatch after an apt kernel upgrade | tuning `--check` compares derived-vs-detected; the model tasks re-check on every run, so an unnoticed upgrade fails loudly instead of OOMing at load |
| `docker stop`/`docker run --rm` and llama-swap's own restarts leaving a stale container | the summary + `--check` + AUTOMATIONS all print `docker rm -f <container>`; `unloadTimeout` sized ≥ `docker stop -t 30` |
| Trust boundary: root llama-swap execs our rendered wrappers | directories are user-owned under `/srv` (mode 755, created by `sudo install -d`), files mode 600/0755, no `sudo envsubst`, trust boundary stated in the script header and the AUTOMATIONS entry |
| Weight revisions are recorded, not pinned | same residual-risk statement as the Spark 27B, plus the `hf download --revision` lever for a hard pin |
| Two engines for one model on one machine confuses clients | strict alias discipline (§1 D5), `--served-model-name` == catalog id, and the response-`model`-field caveat documented |

**Out of scope / follow-ups:** llama.cpp-on-`gfx1151` task (ticket per decision C), vLLM/TheRock nightly, native Gufo build (Nix/cmake), rootless podman runtime, Open WebUI/agent wiring (covered by `sync-models.py`), traefik/ufw exposure (loopback-only by design), a `.tickets/` breakdown (this plan's T-rows are the tickets), and any change to the DGX Spark recipes.

**Branch mechanics:** feature branch via `git worktree` off `develop`; merge to `develop` after review; `main` is cut by the user.

---

## 11. Corrections from review (verified against the things themselves)

Written after the implementation, because five numbers in this plan were wrong
in ways that made the shipped scripts resolve nothing, and a plan nobody can
trust is a plan nobody re-runs. Everything below was checked against ghcr.io,
the Hugging Face hub API, or the engine source — not against a memory.

| Plan said | Reality | Where it bit |
|---|---|---|
| Engine tag `v0.8.0` | ghcr publishes tags **without** the `v`. `v0.8.0` → HTTP 404; `0.8.0`/`0.8.1` → 200. Default is now `0.8.1` at digest `sha256:56f0a052…010afd`, verified against the registry manifest list | every pull would have failed at the registry |
| Flash-Next `UD-IQ4_XL` | no such directory exists. `UD-IQ4_XS` is the 93.7 GB / 3-shard label; `UD-Q4_K_XL` is the 111.3 GB / 4-shard target upstream documents and benchmarks. Default is now `UD-Q4_K_XL` | prepare `--check` and serve both reported the checkpoint as missing |
| Flash-Next shards named `Qwen3.8-Flash-Next-<quant>*` | they live inside a per-quant directory: `UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-0000N-of-00004.gguf` | same, plus `hf download` needs `--include`, not a positional name (the CLI URL-encodes the `*`) |
| MTP sidecar `mtp-Qwen3.8-Flash-Next-Q8_0.gguf` | the file the validated recipe names is `MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf` — a subdirectory of the same repo, and a different file than the root-level one that shares its prefix | `--mtp-model` would have pointed at the wrong sidecar |
| "both stacks, ~108.5 GB, under 10 GiB left" | both at `UD-Q4_K_XL` is 119.9 GiB of weights against a 120 GiB aperture — not tight, it does not fit. The both-resident recipe is Flash-Next at `UD-IQ4_XS` + 27B (`--check` now prints the arithmetic in GiB) | the coexistence advice was advice to fail |
| `--context-length` | the flag is `--context` / `-c`; Gufo exits 2 on unknown options | the container would have exited before loading |
| Speculation flags assembled by guessing the model | the path flag belongs to the backend: `--speculative mtp` → `--mtp-model`, `dflash2` → `--dflash-model`, `dspark` → `--dspark-model`. `GUFO_DRAFT_MODEL` is not read by anything | a wrong flag is an instant exit, not a slow start |

Two facts that were not in the plan and are load-bearing: a snapshot that is
part-fetched passes any glob (`1-of-4` matches `*`), so completeness must be
decided from the `-N-of-M` the filename already declares; and Gufo binds its
port **before** the weights are resident, so `/health` is not readiness —
`/v1/models` listing this exact id is.
