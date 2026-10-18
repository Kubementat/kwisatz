# Ollaya (ollaya-dev/ollaya) — Research Report

**Date:** 2026-09-30
**Repo:** https://github.com/ollaya-dev/ollaya (Apache-2.0, Rust)
**Latest release at time of writing:** v0.7.5 (2026-09-28)
**Sources:** repo README, `docs/api.md` (normative API contract), `https://ollaya.dev/install.sh`, GitHub release assets.

---

## 1. What is Ollaya?

"Ollama for decision models." A single Rust binary (`ollaya`) that pulls open *decision models* by name, serves them from a local daemon, and answers typed questions about a *state* (text, email, ticket, any JSON). It never generates text; it returns calibrated probabilities in one forward pass (milliseconds).

Question primitives (same as Laya / TypeSafe "System 1"): `choice`, `score`, `noul` (yes/no probability).

It is the runtime for the model we already deploy natively via `tasks/setup-laya.sh` (Python `laya-serve`, port 7771). Ollaya additionally serves `laya` (router `laya:en` / `laya:multilingual`, ONNX Runtime, CPU or CUDA) plus ~20 other models (`winnow:e4b`, `decider`, `kev`, `nli`, `gliclass`, `qwen3guard`, `jevk5`, ...), with a model store, keep-alive/unloading and an Ollama-style CLI.

Ollaya publishes only ~3 MB ONNX graphs; weights are fetched from the model authors' Hugging Face repos, pinned by commit and sha256-verified. GGUF models (`winnow`, `jevk5`) run on a bundled llama.cpp.

## 2. Requirements

| Item | Value |
|---|---|
| OS/arch | Linux x86_64/arm64 (glibc >= 2.38: Ubuntu 24.04+, Debian 13), macOS arm64, Windows x64 |
| Tools for installer | `curl tar awk mktemp sha256sum zstd` |
| GGUF models | system `libgomp1` (OpenMP) |
| GPU (optional) | NVIDIA, x86-64 only. Driver R580+ -> CUDA 13 pack (~1 GB); R525–R575 or pre-Turing (< sm_75) -> CUDA 12 pack (~1.6 GB). Driver is never installed by the installer |
| musl/Alpine | unsupported (use Docker image) |

## 3. Installation options

1. **Official script:** `curl -fsSL https://ollaya.dev/install.sh | sh`
   - Env: `OLLAYA_VERSION`, `OLLAYA_INSTALL_DIR` (default `/usr/local`, else `~/.local`), `OLLAYA_NO_SERVICE=1`, `OLLAYA_NO_CUDA=1`.
   - Downloads `ollaya-linux-<arch>.tar.zst` (+ CUDA pack) from GitHub releases, verifies against release `sha256sum.txt`, installs `bin/ollaya`, `lib/ollaya/cuda_v13|cuda_v12`, `share/doc/ollaya`, `share/ollaya/skills`.
   - With root/sudo it also creates system user `ollaya` (home `/usr/share/ollaya`), adds it to `render`/`video`, writes `/etc/systemd/system/ollaya.service` (binds `127.0.0.1:11435`, models in `/usr/share/ollaya/.ollaya/models`) and restarts it.
2. **Release tarballs** on GitHub (same files as above), plus `.deb`, `.rpm`, `AppImage` (desktop app).
3. **Docker:** `ghcr.io/ollaya-dev/ollaya[:cuda|:cuda12]`, port 11435.

## 4. Configuration (environment variables, docs/api.md §15)

| Variable | Default | Effect |
|---|---|---|
| `OLLAYA_HOST` | `127.0.0.1:11435` | Bind address (server) and target (CLI) |
| `OLLAYA_API_KEY` | unset | Requires `Authorization: Bearer <key>` on everything except `GET/HEAD /` and CORS preflight; CLI sends it too |
| `OLLAYA_MODELS` | `~/.ollaya/models` | Model store |
| `OLLAYA_KEEP_ALIVE` | `5m` | Idle time before a model is unloaded (`-1` = forever) |
| `OLLAYA_MAX_LOADED_MODELS` | `3` | Loaded-model limit |
| `OLLAYA_DEVICE` | `auto` | `auto`, `cpu`, `cuda`, `cuda:<n>`, `metal` |
| `OLLAYA_MAX_QUEUE` | `512` | Queue bound before `503 QUEUE_FULL` |
| `OLLAYA_LOAD_TIMEOUT` | `5m` | Model load deadline |
| `OLLAYA_ORIGINS` | unset | Extra allowed browser origins (CORS) |
| `OLLAYA_REGISTRY` | `ollaya.dev` | Default registry host |
| `OLLAYA_LOG` / `OLLAYA_LOG_DIR` | `info` / stderr | Log filter / log directory |

## 5. Security (docs/api.md §14)

- **No auth by default**; loopback bind. A non-loopback bind without `OLLAYA_API_KEY` only logs a warning. Anyone reaching the port can run decisions, **pull arbitrary models (disk fill), delete/create models**, pin models in memory.
- With `OLLAYA_API_KEY` set the key is compared in constant time; `401` with `WWW-Authenticate: Bearer` otherwise. `GET /` stays open (liveness: `Ollaya is running`).
- No TLS in the daemon -> use traefik / reverse proxy for remote access.
- Loopback binds additionally enforce a Host-header check (DNS-rebinding protection). Origin allowlist for browsers via `OLLAYA_ORIGINS`.
- State/question text is never logged.

## 6. CLI

`ollaya serve | run <model> [--preset triage] [state] | pull | list | ps | show | rm | cp | stop | create <name> -f Modelfile | mcp`. If no daemon is running the CLI spawns one in the background (with a systemd service present, that is not needed). `ollaya mcp` serves the models to MCP clients (`claude mcp add ollaya -- ollaya mcp`). Agent skill shipped at `<prefix>/share/ollaya/skills`.

## 7. HTTP API (docs/api.md)

| Endpoint | Purpose |
|---|---|
| `GET/HEAD /` | liveness (no auth) |
| `GET /api/version` | `{"version": "..."}` |
| `POST /api/decide` | native decision endpoint, adds routing/timing, load/unload |
| `POST /api/pull` | download a model (NDJSON stream; `"stream": false` -> one response; resumable, idempotent, sha256 verified; router pulls also pull targets) |
| `GET /api/tags`, `POST /api/show`, `GET /api/ps` | list / details / loaded models |
| `DELETE /api/delete`, `POST /api/copy`, `POST /api/create` | manage models |
| `POST /v1/systemone`, `POST /v1/decisions`, `GET /v1/models` | TypeSafe/Jev wire-compatible (`TYPESAFE_BASE_URL=http://host:11435`) |

Body limit 8 MiB; state limit 65,536 tokens; unknown fields ignored; durations in ns.

Example:

```sh
curl http://localhost:11435/v1/systemone \
  -H "Authorization: Bearer $OLLAYA_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"laya","state":"Refund my double charge today.",
       "questions":{"refund":{"type":"noul","instructions":"Does the user want a refund?"}}}'
```

## 8. Recommended models

- `laya` — CPU-friendly router, English 8–10 ms on a 4090; **default for CPU-only hosts** (~0.8 GB fp32 weights for `laya:en` pull).
- `winnow:e4b` — recommended overall (0.722 typed-decisions), 8 GB Q8_0 GGUF, wants an NVIDIA GPU with >= 10 GB.

## 9. Integration decisions for kwisatz

| Topic | Decision |
|---|---|
| Install | Download the official `install.sh` to a temp file (never `curl \| sh`), run with `OLLAYA_NO_SERVICE=1 OLLAYA_VERSION=<pinned>`; it sha256-verifies the release. Version: latest GitHub release by default (resolved via the `/releases/latest` redirect), `OLLAYA_VERSION` pins one. Skipped if that version is already installed (`--force` overrides) |
| Service | Own unit rendered from `templates/ollaya/ollaya.service` (upstream unit hard-codes loopback + `/usr/share/ollaya`); dedicated system user `ollaya` (groups `render`,`video`), data in `/srv/ollaya` (models: `/srv/ollaya/models`) |
| Secrets | `OLLAYA_API_KEY` in `/srv/ollaya/.env` (mode 600) via `EnvironmentFile=`; env > existing file > `openssl rand -hex 24`; never rotated |
| Bind | Default `0.0.0.0:11435` **with** API key (same policy as laya); `OLLAYA_HOST=127.0.0.1:11435` keeps it local (no UFW rule) |
| Health | Poll unauthenticated `GET /` for `Ollaya is running`, then authenticated `GET /api/version` to prove the token works |
| Models | `OLLAYA_PULL_MODELS` (default `laya`) pulled through `POST /api/pull` (idempotent) |
| Firewall | `ufw_firewall_section` for the port unless loopback |
| Coexistence | Ollaya port 11435 does not clash with `setup-laya.sh` (7771); both can run. A pre-existing upstream-generated unit is replaced (its models under `/usr/share/ollaya` are not migrated) |
| Reverse proxy | Not integrated; daemon has no TLS — front with traefik if needed |

## 10. Risks / open points

- glibc >= 2.38 required (fine on Ubuntu 24.04+, not 22.04).
- Model pulls need internet access to `ollaya.dev` and huggingface.co; first pull of large models (winnow ~8 GB) can take long -> `OLLAYA_PULL_TIMEOUT`.
- Project is young (v0.7.x, API moves fast); the script installs the latest release by default, so a breaking upstream release can land on re-run; pin `OLLAYA_VERSION` for reproducible machines.
- `ollaya --version` output format was not verified; the script matches the version string loosely.
- The script itself was not run end-to-end in the VM test harness (see tests/README.md).
