# agentsview research (v0.44.0, verified 2026-09-27)

Sources: repo https://github.com/kenn-io/agentsview (cloned, docs/ and Go sources read),
https://agentsview.io/install.sh, GitHub release v0.44.0 asset list.

## 1. Install
- Methods: `curl -fsSL https://agentsview.io/install.sh | bash` (Linux/macOS, amd64/arm64;
  installs to /usr/local/bin if writable else ~/.local/bin); release tarball
  `agentsview_<ver>_linux_<amd64|arm64>.tar.gz`; AppImage/desktop; PyPI wheels; Docker
  `ghcr.io/kenn-io/agentsview` (linux/amd64, arm64); Homebrew cask (macOS); build from source (Go+Node).
- Version pinning: the install script has NO version parameter (always latest). Pin by downloading the
  release tarball directly (what the task does).
- Integrity: `SHA256SUMS` published per release (installer verifies it; `AGENTSVIEW_SKIP_CHECKSUM=1` bypasses).
  Release also has `SHA256SUMS.sig` (base64 ECDSA-looking signature) plus SLSA `.provenance.json`;
  no documented public key or verification procedure was found, so only sha256 is verified.
- Upgrade: re-run with new version; `agentsview update` also exists (task disables update checks and pins).

## 2. Config
- `~/.agentsview/config.toml` (TOML), data dir override `AGENTSVIEW_DATA_DIR`. agentsview itself writes to it
  (e.g. cursor secret), so the task does not blindly overwrite it.
- `[[session_sources]]` tables: `agent` (parser name), `dir` (filesystem root in the agent's native layout),
  optional `machine` = peer's installation ID (contents of the peer's `~/.agentsview/telemetry-install-id`);
  omit for local roots. Transport (rsync/git/NFS) is out of band; never copy sessions.db. Machine attribution is
  fixed at first ingestion (changing `machine` later does not relabel).
- Display label: `local_machine_name = "..."` (default hostname), needs daemon restart (`agentsview daemon restart`).

## 3. Background service / Postgres
- `agentsview pg push --watch` (foreground; `--debounce 30s`, `--interval 15m`); logs `pg-watch.log`.
- `agentsview pg service install` creates a `systemd --user` unit, BUT requires a literal URL in config.toml
  and explicitly rejects `AGENTSVIEW_PG_URL` and `${VAR}` expansion (pg_service_manager.go). That contradicts
  the repo secrets rule, so the task ships its own unit (`templates/agentsview/agentsview-pg-push.service.tpl`)
  with `EnvironmentFile=~/.agentsview/pg.env` (mode 600) holding `AGENTSVIEW_PG_URL`. `pg push` reads
  `AGENTSVIEW_PG_URL` (also `_SCHEMA`, `_MACHINE`); not tested against a live Postgres.
- Headless: `loginctl enable-linger $USER` needed (task warns only).
- Alternatives (not implemented): ClickHouse (`[clickhouse.NAME]`, `clickhouse push`), DuckDB mirror (`[duckdb]`),
  `pg serve` read-only web UI on the mirror.

## 4. Telemetry
- Anonymous PostHog `daemon_active` ping (version, OS/arch, install id) on daemon start and every 24h.
  Env-only: `AGENTSVIEW_TELEMETRY_ENABLED=0` (a generic `TELEMETRY_ENABLED=0` is also honored via the kit
  library). No config-file key. Update check (GitHub API): `disable_update_check = true` / `AGENTSVIEW_DISABLE_UPDATE_CHECK=1`.
- Consequence: any process that starts the daemon needs the env var; the task sets it in ~/.profile and the unit.

## 5. Auto-detected Linux dirs (internal/parser/types.go)
Claude `~/.claude/projects` (CLAUDE_CONFIG_DIR), Codex `~/.codex/sessions` + `archived_sessions` (CODEX_HOME),
OpenCode `~/.local/share/opencode`, Pi `~/.pi/agent/sessions` (PI_CODING_AGENT_DIR), Copilot `~/.copilot`,
Gemini `~/.gemini`, Cursor `~/.cursor/projects`, Hermes `~/.hermes/sessions`, Forge `~/.forge`, Kilo
`~/.local/share/kilo`, Qwen, Kimi, Goose, Amp and ~40 more; Aider is opt-in (`AIDER_DIR`).
