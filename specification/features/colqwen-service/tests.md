# Tests — colqwen-service

## Test Approach

Automated testing is limited to static analysis (ShellCheck plus the project's mandatory linters), consistent with the project's current test strategy. All behaviors are verified manually on a live Ubuntu machine with an NVIDIA GPU and locally available ColQwen2.5 model weights.

---

## Automated Tests

### T-01: ShellCheck — `tasks/setup-colqwen.sh`

- Run `shellcheck tasks/setup-colqwen.sh`
- **Pass:** No errors or warnings.

### T-02: hadolint — `templates/colqwen/Dockerfile`

- Run `docker run --rm -i hadolint/hadolint < templates/colqwen/Dockerfile`
- **Pass:** No errors or warnings.

### T-03: yamllint — `templates/colqwen/docker-compose.yml`

- Run `yamllint templates/colqwen/docker-compose.yml`
- **Pass:** No errors or warnings.

### T-04: ShellCheck — `templates/colqwen/test.sh`

- Run `shellcheck templates/colqwen/test.sh`
- **Pass:** No errors or warnings.

---

## Manual Test Scenarios

### Prerequisites
- Ubuntu machine with Docker and Docker Compose v2 installed
- NVIDIA GPU with working container toolkit (`docker run --gpus all` works)
- ColQwen2.5 model weights available locally (e.g. `colqwen2.5-base/` and `colqwen2.5-v0.2/`)

---

## Behavior 1: Pre-Flight Checks & Argument Parsing

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T1.1 | Run with `--help` | Usage text with all flags and env vars; exit 0 |
| T1.2 | Run with an unknown flag | Exit non-zero with usage hint |
| T1.3 | Run with `--port 99999` | Exit non-zero, message names `COLQWEN_PORT` |
| T1.4 | Run with `--colpali-version '0.3.17; rm -rf /'` | Exit non-zero, unsafe characters rejected |
| T1.5 | Run with relative `--dir ./colqwen` | Exit non-zero, absolute path required |
| T1.6 | Run while Docker daemon is stopped | Exit non-zero suggesting `sudo systemctl start docker` |
| T1.7 | Run without any flags or env vars | Defaults applied (`/srv/colqwen`, port 8100, `0.3.13`, `25.10-py3`); no interactive prompt at any point |

---

## Behavior 2: Idempotent Project Generation

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T2.1 | Fresh run on clean machine | `Dockerfile`, `docker-compose.yml`, `requirements.txt`, `.env` (mode 600), `app/main.py`, `test.sh` (executable), `test.png` created under `/srv/colqwen` |
| T2.2 | Run a second time without flags | Status printed, nothing modified (verify file mtimes unchanged), exit 0 |
| T2.3 | Run with `--check` (fresh and existing state) | Status only, no files created or changed, exit 0 |
| T2.4 | Edit `.env`, run with `--force` | `.env` backed up to `.env.bak`, all files re-rendered |
| T2.5 | Delete `docker-compose.yml` only, re-run | Treated as fresh install, all files re-rendered |

---

## Behavior 3: Central Configuration via .env

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T3.1 | Inspect generated `.env` | Contains `NGC_PYTORCH_TAG`, `COLPALI_VERSION`, `COLQWEN_MODEL_DIR`, `COLQWEN_MODEL`, `COLQWEN_PORT`, `COLQWEN_BIND` with comments |
| T3.2 | `docker compose config` in project dir | Values from `.env` resolved into build args, volume, environment, and port mapping |
| T3.3 | Change `COLPALI_VERSION` in `.env`, rebuild | Image contains new colpali-engine version (`pip show colpali-engine` inside container) without re-running the setup script |
| T3.4 | Re-run script with different `--port` but without `--force` | Existing `.env` untouched; status output points this out |

---

## Behavior 4: Model Volume Integration

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T4.1 | Fresh run with default model dir absent | `$HOME/.cache/huggingface` created empty, warning printed |
| T4.2 | Run with `--model-dir /nonexistent/path` | Warning printed, directory NOT created, generation continues |
| T4.3 | ID-form `COLQWEN_MODEL` without matching `hub/models--<org>--<name>` dir; path-form with missing directory | Warning printed in both cases, generation continues |
| T4.4 | Start service with models present | Model dir is mounted read-only at the identical container path; write attempt inside container fails |
| T4.5 | Inspect image (`docker image ls`, `docker history`) | Model weights not part of the image (image size independent of model size) |
| T4.6 | Start service with the adapter model `vidore/colqwen2.5-v0.2` whose `adapter_config.json` references the base model via an absolute host path | Base model resolves through the identical-path mount without modifying `adapter_config.json` |

---

## Behavior 5: ColQwen Embedding Service (app)

> T5.2, T5.3, T5.6, T5.7 and T5.9 (ready state) can be executed in one go via the generated smoke test: `cd /srv/colqwen && ./test.sh`

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T5.1 | `docker compose build && docker compose up -d` with defaults and models present | Build succeeds, container starts, log shows exactly one model load |
| T5.2 | `curl -X POST :8100/embed/queries` with `{"queries": ["test query"]}` | 200, one multi-vector embedding (list of vectors) returned |
| T5.3 | `curl -X POST :8100/embed/images` with two image files | 200, two multi-vector embeddings in input order |
| T5.4 | Send several requests in a row | No re-load in logs; response times stable (model stays in memory) |
| T5.5 | Start with `COLQWEN_MODEL` pointing to a missing model (ID or path form) | Container exits non-zero; log names the configured model reference; no download attempt |
| T5.6 | POST empty query list / no files | HTTP 400 with descriptive message |
| T5.7 | Upload a non-image file to `/embed/images` | HTTP 400 naming the offending file |
| T5.8 | Disconnect host from the internet, restart the container | Service starts and serves requests (fully offline; `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`) |
| T5.9 | `curl :8100/health` after the container finished starting; same call while the model is still loading | 200 `{"status": "ok"}` once ready; during model load the connection is refused / not yet answered (no 200 before the model is loaded) |
| T5.10 | Build with a `COLPALI_VERSION` / `NGC_PYTORCH_TAG` combination that drops the LoRA adapter weights (e.g. `0.3.17` / transformers 5.x with `vidore/colqwen2.5-v0.2`) | Container exits non-zero; log states that all `lora_B` weights are zero and points at the `.env` version combination; no 200 on `/health` |

---

## Behavior 6: Summary Output & Next Steps

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T6.1 | Fresh run, inspect final output | Colour-coded summary: project dir, model dir/name, NGC tag, colpali version, port, `.env` path, `docker compose` next steps, `curl` examples |
| T6.2 | Fresh run with empty model dir | Summary repeats the model-directory warning |
| T6.3 | Run with `--check` | Same summary style, clearly states nothing was changed |
