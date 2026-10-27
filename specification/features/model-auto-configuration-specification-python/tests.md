# Tests: Model Auto-Configuration (Python Implementation)

> Python rewrite of `specification/features/model-auto-configuration-specification/tests.md`.
> Scenarios and expected results are unchanged unless noted; only the implementation-facing
> details (entrypoint name, linter, validation commands) differ.
>
> **Updated (2026-09-04), post-review:** T2.15 (disk-space warning), T3.13/T3.14
> (post-restart health poll, Decision 32) added; T3.1 extended; T4.14 retargeted and
> T6.2 adjusted for the local-only default catalog (Decision 31).

## Test Strategy Note (v1)
Automated test coverage for this feature is **deferred to a future release** (project test
strategy: VM-based integration + unit testing planned). The Python implementation makes the
pure logic — catalog validation, placeholder expansion, JSON/YAML merge, dry-run output
parsing — directly unit-testable (e.g. `pytest`) in that future phase without a target
machine. This file documents manual test scenarios to execute on a target machine before
considering the feature done.

**Static gates (run before all scenarios):**
- `ruff check tasks/sync-models.py sync_models/` — no errors (minimum fallback:
  `python3 -m py_compile` on every new/changed `.py` file)
- `yamllint models.yml.default` — clean

The entrypoint is invoked throughout as `./tasks/sync-models.py` (executable, shebang).

---

## Behavior 1: Pre-flight Checks

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T1.1 | Run with a **remote-only** catalog (`MODELS_YML` pointing at a remote-only `models.yml`) on a machine without llama-swap | Exit 0; agent sync proceeds; llama-swap step skipped |
| T1.2 | Run with local models while `/srv/llama-swap/config/config.yaml` is missing | Exit 1, message references `./tasks/setup-llama-swap.sh`; **no** agent files modified |
| T1.3 | Run with `download:` commands while `hf` is not on PATH (e.g. `PATH` without `~/.local/bin`) | Exit 1, message references `./tasks/setup-basics.sh` |
| T1.4 | Run with a syntactically invalid YAML catalog | Exit 1, parse error shown; no mutations |
| T1.5 | Catalog with schema violations: missing `serve.cmd` on local model; `type: remote` with `download:`; duplicate local model names | Exit 1, **all** violations listed (not just the first) |
| T1.6 | Top-level `env` entry named `PORT` (llama-swap reserved macro) | Exit 1, reserved-name error |
| T1.7 | `MODELS_YML=/nonexistent/file.yml` | Exit 1, clear "file not found" with the path |
| T1.8 | No `models.yml`, only `models.yml.default` present | `.default` is used and announced in the log |
| T1.9 | `models.yml` present | `models.yml` is used (not `.default`) |
| T1.10 | Both present + `MODELS_YML` pointing at a third file | `MODELS_YML` file wins |
| T1.11 | Opencode not installed (`~/.config/opencode/opencode.json` missing) | Opencode skipped with a note; pi still synced; exit 0 |
| T1.12 | `--agents pi` while opencode is installed | Only pi touched; opencode config file byte-identical before/after |
| T1.13 | PyYAML not importable (e.g. run in a venv/interpreter without PyYAML) | Exit 1, message references `python3-yaml` installation; no mutations |
| T1.14 | Existing `config.yaml` with local models in catalog but corrupt (invalid YAML) | Exit 1 before any mutation; `config.yaml` byte-identical |
| T1.15 | Existing `config.yaml` parses as YAML but is not a mapping (e.g. top-level list) | Exit 1 before any mutation; `config.yaml` byte-identical |
| T1.16 | Local models in catalog; `config.yaml` or its directory not writable by the invoking user | Exit 1 with actionable message (fix ownership/permissions or run as a user with write access); no download, no mutation (Decision 28) |
| T1.17 | Catalog `env` with a circular reference (`A=${B}`, `B=${A}`) | Exit 1 in pre-flight naming the involved variables; no mutation |
| T1.18 | No `models.yml` and no `models.yml.default` | Exit 1; message lists the paths tried |
| T1.19 | Catalog with two providers of the same name | Exit 1; duplicate provider name listed among the violations |
| T1.20 | `--agents opencode` while `opencode.json` is missing | `WARNING:` + opencode skipped (`skipped (not detected)` in summary); pi still synced; exit 0 |
| T1.21 | `~/.config/opencode/opencode.jsonc` exists, no `opencode.json` | opencode skipped with a `WARNING:` (JSONC not managed); **no** `opencode.json` created; pi still synced; exit 0 (Decision 29) |
| T1.22 | `OPENCODE_CONFIG=/custom/opencode.json` with that file existing | The custom file is synced instead of the default path (opencode's own env-var semantics honored) |
| T1.23 | Top-level `env` entry with a non-string scalar (`value: 0` unquoted) | Coerced to string `"0"`; run proceeds |

## Behavior 2: Downloads

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T2.1 | First run with a small local model (e.g. a single small GGUF or `config.json`-sized test file) | Dry-run reports N files > 0 → real download runs; file lands under `--local-dir` path |
| T2.2 | Second run, same catalog | Dry-run reports 0 files → `already present, skipping` logged; no network transfer of the file |
| T2.3 | Delete one downloaded file, re-run | Only that file re-downloaded |
| T2.4 | Multi-file model (two `hf download` commands in `download:` list) | Both commands processed independently; per-command present/missing reporting |
| T2.5 | `download:` command with a bad repo id | Command fails, error logged; other models still attempted; exit 2; summary shows failure |
| T2.6 | Interrupted download (kill mid-transfer), re-run | `hf` resumes/completes; no double full download |
| T2.7 | `--local-dir` metadata folder (`.cache/huggingface/` inside the local dir) | Present after download; **not** deleted by the tool on any run |
| T2.8 | `${MODEL_DIR}` placeholder in `download:` and in `serve.cmd` | Expanded to the top-level `env` value; `${HOME}` in an env value itself expands to the real home |
| T2.9 | `serve.cmd` contains `${PORT}` and `${llama-server-bin}` | These are **not** expanded by the tool; they survive verbatim into `config.yaml` |
| T2.10 | Per-model `env` overrides a top-level env name | Per-model value wins in that model's expansion; other models use the top-level value |
| T2.11 | Dry-run output is malformed/unparseable | The tool runs the real download (conservative; never skips on ambiguity) |
| T2.12 | `download:` command using shell features (e.g. `hf download ... && echo done`) and an env var from the process environment | Executed via `bash -c`; shell features and inherited process env (e.g. `HF_TOKEN`) work without catalog declaration |
| T2.13 | `HF_TOKEN` declared in top-level catalog `env` (absent from the process env); gated `hf download` | Token visible to the `hf` subprocess via the exported effective env (Decision 27); gated download succeeds; token not spelled inline in the command |
| T2.14 | Compound `download:` entry (`hf download ... && echo done`) with the file already present | Real command runs (no `already present, skipping` — the probe cannot target the `hf` part of a compound entry); `hf` itself performs no network transfer (ledger); exit 0 |
| T2.15 | Free space on the `--local-dir` file system is below the dry-run total size (e.g. point a catalog's `MODEL_DIR` at a 1 MiB tmpfs) | `WARNING: not enough free space for <model> (need ~<SIZE>, have <FREE>)` logged before the download attempt; run continues (the download may legitimately fail afterwards → exit 2 with the failure in the summary) |

## Behavior 3: llama-swap Sync

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T3.1 | Add 1 new local model | `models:` gains the key with the expanded `cmd` and `env:` containing **only** the model's per-model env (e.g. `CUDA_VISIBLE_DEVICES=0`) — top-level env (`MODEL_DIR`) is not written (Decision 26); service restarted once **and passes the post-restart `/health` poll** (Decision 32); llama-swap `/v1/models` lists it after load |
| T3.2 | Re-run immediately | Config file **byte-identical** (no reformatting); service **not** restarted |
| T3.3 | Pre-existing hand-tuned model entry (different `cmd` than catalog) with the same key | Entry untouched; `already present, unchanged` logged |
| T3.4 | `macros`, `matrix`, `hooks`, `apiKeys` sections | Present and **parse-equal** (structurally preserved) after adding models; comments/reformatting may differ (PyYAML round-trips the whole document) |
| T3.5 | `--no-restart` with a new model added | Config written; no restart; manual `sudo systemctl restart llama-swap` command printed |
| T3.6 | llama-swap service stopped, run with a new model | Config written; restart **starts** the service; service active after run |
| T3.7 | Corrupted-partial-write simulation (forced serializer/validator failure; a read-only target is instead caught in pre-flight — see T1.16) | Original `config.yaml` intact; exit 2; no temp files left behind in the config directory |
| T3.8 | Catalog with only remote models | `config.yaml` byte-identical; no restart |
| T3.9 | Pre-existing entry with same key and a different/absent `env` | Entry untouched, including its `env`; `already present, unchanged` logged |
| T3.10 | After adding a model, validate YAML + non-model sections preserved | `config.yaml` parses as valid YAML; `macros`, `matrix`, `hooks`, `apiKeys` present and parse-equal; only the new model entry was added; first-modification comment-loss warning logged |
| T3.11 | Restart failure after a successful config write (e.g. `sudo` denied) | `ERROR:` with manual `sudo systemctl restart llama-swap` printed; config written; exit 2 |
| T3.12 | One local model's download fails, another succeeds | **Both** models get config entries (declarative); exit 2; summary marks the failed download; llama-swap serves the successful one |
| T3.13 | Config change triggers a restart; `/health` returns 200 within `LLAMA_SWAP_HEALTH_TIMEOUT` | Health poll logged as healthy (`llama-swap healthy`); exit 0 |
| T3.14 | Config change triggers a restart but `/health` never answers (e.g. `LLAMA_SWAP_HEALTH_TIMEOUT=5` with the config's `port` key pointed at a closed port) | `ERROR:` with `sudo systemctl status llama-swap` hint; config was written; exit 2; no hang beyond the timeout |

## Behavior 4: Agent Sync (pi)

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T4.1 | Fresh `models.json` (only `{"providers":{}}`), catalog with 2 providers / 3 models | Both providers created with `baseUrl`, `api: "openai-completions"`, `apiKey`; new model entries have **no** `cost` field; all 3 models present with defaults applied (`contextWindow: 200000`, `maxTokens: 16000`, `reasoning: true`, `input: ["text"]`) |
| T4.2 | Existing provider `evo` with extra manual model `my-manual-model` | Manual model **preserved**; catalog models added |
| T4.3 | Existing catalog-managed model with a manually changed `contextWindow` | Field corrected to catalog value; `updated contextWindow` logged; other manual fields (e.g. `cost`) preserved |
| T4.4 | Provider exists under same name with a **different** `baseUrl` | `baseUrl` updated to catalog value with a warning |
| T4.5 | `thinkingLevelMap` in catalog | Written into the pi model entry as-is (nulls preserved) |
| T4.6 | Model id present under two different providers in catalog | Both provider entries get the model; no cross-contamination |
| T4.7 | Re-run after a change | `models.json` stable: second no-op run leaves the file byte-identical; written output is 2-space-indented JSON, parse-equal (e.g. assert via `python3 -c "import json,sys; json.load(open(sys.argv[1]))"` or `jq -S .` if available) |
| T4.8 | Invalid JSON produced (simulated, e.g. forced validator failure) | Original file intact; exit 2; no temp files left behind |
| T4.15 | Existing `models.json` is corrupt (invalid JSON) | Pi agent skipped with an error; original file byte-identical; other detected agents still synced; exit 2; summary marks pi `failed` |
| T4.16 | Catalog provider without `apiKey` | Provider created **without** an `apiKey` field; re-run after a user adds `apiKey` manually: value preserved (catalog still omits it); no placeholder warning |

## Behavior 4: Agent Sync (opencode)

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T4.9 | Fresh/empty opencode config, catalog with providers | Provider(s) + models written in opencode's structure; output parses as valid JSON (`json.loads`) |
| T4.10 | Existing opencode config with unrelated manual entries | Untouched; only catalog providers/models added or fixed |
| T4.11 | Re-run | Config stable (parse-equal), exit 0; file byte-identical on the no-op run |
| T4.12 | Fresh/empty opencode config, catalog with providers | Provider block has `name`, `npm: "@ai-sdk/openai-compatible"`, `options.baseURL`, `options.apiKey`; model entry has `limit.context`, `limit.output`, `reasoning`, `modalities.input`, derived `attachment` (true when `input` contains `image`), creation-time `tool_call: true`, `modalities.output: ["text"]`; output parses as valid JSON |
| T4.13 | Manually set `tool_call: false` on an opencode model entry, re-run | `tool_call` stays `false` (unmanaged); managed fields still synced to catalog values |
| T4.14 | Run with `MODELS_YML` pointing at a catalog containing a provider with `apiKey: sk-PLACEHOLDER` | `WARNING:` logged for the placeholder before writing; agent configs still contain the placeholder (user responsibility to replace in `models.yml`); exit 0 (the committed `models.yml.default` itself contains no placeholder keys — Decision 31) |

## Behavior 5: Verification & Summary

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T5.1 | Successful first run (local + remote models, pi + opencode) | Summary table per component: correct added/already-present counts; exit 0 |
| T5.2 | No-op re-run | All entries "already present"; exit 0 |
| T5.3 | Run with one failing download + successful config sync | Summary shows the download failure (verification checks config state only, not weight files); the failed model's llama-swap entry is still present; exit 2 |
| T5.4 | `--help` | Usage text with flags and `MODELS_YML`; exit 0; no side effects |
| T5.5 | `--agents pi,foo` (foo not supported) | Exit 1; message lists supported agents and names `foo` (custom message, not argparse's default exit 2) |
| T5.6 | Any failing run (e.g. T1.16) | Error text on **stderr**; summary/warnings on **stdout** (Decision 30) |

## Repo Hygiene

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| T6.1 | `git status` after creating a local `models.yml` with a real API key | `models.yml` untracked/ignored; not commit-able; `models.yml.default` tracked |
| T6.2 | `models.yml.default` scanned for real secrets | No real secrets: local models only, no remote providers, the only `apiKey` is the literal `not-required` (Decision 31) |
| T6.3 | `machine-config.yml.example` contains `sync-models` with `enabled: false` **and a comment** that orchestrator dispatch of the `.py` entrypoint is a separate follow-up | Orchestrator can list the task; enabling it before the follow-up lands would break `kwisatz apply` (it maps task names to `tasks/<name>.sh`) — the comment keeps that visible |
| T6.4 | Fresh clone on a new machine: `./tasks/setup-basics.sh`, `./tasks/setup-llama-swap.sh`, `./tasks/setup-pi.sh`, `./tasks/setup-opencode.sh`, then `./tasks/sync-models.py` | End-to-end: weights downloaded, llama-swap serves a new model, pi + opencode list the models |
| T6.5 | Static gates on the committed code | `ruff check tasks/sync-models.py sync_models/` clean; `yamllint models.yml.default` clean; `python3 -m py_compile` passes on all new/changed files |
