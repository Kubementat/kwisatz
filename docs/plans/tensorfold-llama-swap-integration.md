# Plan (follow-up): TensorFold Qwen3.8 Flash Next via llama-swap

**Supersedes:** `docs/plans/tensorfold-qwen3.8-flash-next.md` (standalone compose stack — dropped)
**Research:** `docs/research/2026-10-14-qwen38-tensorfold-llama-swap-integration.md`
**Branch:** `feature/setup-tensorfold` (uncommitted work from the first pass gets replaced)

## Decision (operator, 2026-10-14)

- **Option 2:** clone the upstream repo
  (MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold) and use its
  `scripts/prepare.sh` for one-time setup (image + checkpoint).
- **llama-swap is the central proxy/manager.** The model is NOT started
  standalone — it runs through llama-swap (port 9292), which owns the
  container lifecycle via `cmd`/`cmdStop` and proxies to TensorFold on 8888.

## Design

### `tasks/setup-tensorfold.sh` (rewrite of the first-pass script)

Workflow (all steps idempotent / converge on re-run):
1. **Pre-flight:** Docker running, CDI GPU spec (`nvidia.com/gpu=all`),
   DGX Spark detection, ~160 GB free disk, `hf` CLI, and **llama-swap
   installed** (`/srv/llama-swap` + `systemctl status llama-swap`) — point at
   `setup-llama-swap.sh` if missing.
2. **Clone upstream** into `/srv/tensorfold`, pinned to commit
   `db281878ddb836fd0df510d8771ecb7e0fe47d26` (TF_REF from research §9.2).
   Re-run: `git fetch` + `git checkout <pin>` (converge, never a fresh clone
   over an existing checkout).
3. **Prepare:** run `/srv/tensorfold/scripts/prepare.sh` (image pull/build +
   ~122 GB checkpoint + verify — idempotent upstream).
4. **Catalog entry:** additively add the `qwen3.8-flash-next` entry to
   `models.yml` (gitignored, user-local — **not** `models.yml.default`, which
   must stay clean for machines without a Spark). If `models.yml` is missing,
   seed it from `models.yml.default` first. The entry is a template file
   `templates/tensorfold/models-entry.yml` (repo convention: no inline
   templates), merged additively (existing entry untouched on re-run; the
   tensorfold entry is replaced if the template changed).
5. **Sync:** run `tasks/sync-models.py` (merges into llama-swap `config.yaml`,
   restarts only on change, polls `/health`).
6. **Smoke test** through llama-swap: `POST http://localhost:9292/v1/chat/completions`
   with `model: qwen3.8-flash-next` (load on demand), bounded timeout
   (122 GB weight load: default 900 s).
7. Flags: `--check`, `--force`, `--help` (kept complete). No standalone mode.

### Catalog entry (research §5.1, adapted)

- `proxy: http://127.0.0.1:8888`, `checkEndpoint: /health`, `ttl: 0`
- `aliases: [Qwen3.8-Flash-Next, qwen3.8-flash, qwen3.8]`
- `agent:` metadata (contextWindow 262144, maxTokens 32768, reasoning,
  input [text, image])
- **`cmd` / `cmdStop`:** derive from the upstream `start.sh` / `stop.sh`
  (read them — decide between calling the upstream scripts vs. the
  `docker run -d ...` form from research §5.1; whatever it is, `cmd` must
  return or run detached so llama-swap's health polling works, container
  name `qwen38-flash-next-tf`, stale-container cleanup first).
- `download:` — `bash /srv/tensorfold/scripts/prepare.sh` (no-op after step 3)
- Port 8888 fixed (research §4.3 Option A); overridable via `TENSORFOLD_PORT`
  in the task script, rendered into the catalog entry.

### Cleanup

- **Delete** `templates/tensorfold/docker-compose.yml.tmpl` and
  `templates/tensorfold/env.template` (standalone stack dropped)
- Rewrite the `AUTOMATIONS.md` entry (no more "Docker stack", now
  "llama-swap-managed")
- `machine-config.yml.example`: keep the `setup-tensorfold` entry, adjust
  description/env if needed

## Deliverables

1. `tasks/setup-tensorfold.sh` (rewrite, shellcheck-clean, `--help` complete)
2. `templates/tensorfold/models-entry.yml` (catalog entry template)
3. Delete old compose/env templates
4. `AUTOMATIONS.md` + `machine-config.yml.example` updated
5. Lint: shellcheck, yamllint, YAML validity of the catalog snippet

## Verification

- `--help` renders; `shellcheck` clean
- Catalog template is valid YAML and the merge logic is additively idempotent
  (test the merge function with a temp `models.yml`)
- No deployment on this box (no GPU)

## Out of scope

- Bridge script (research §5.3) — llama-swap API suffices
- Standalone (non-llama-swap) operation
- `models.yml.default` entry (machine-specific catalog stays user-local)
