# Changelog

All notable changes to kwisatz are documented here. The per-release notes in
[`docs/releases/`](docs/releases/) are the source of truth — this file is the index, so a
one-line summary that drifts cannot contradict a release.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the version
number follows the semver rule in [`AGENTS.md`](AGENTS.md): **MAJOR** = breaking
`machine-config.yml` keys, removed/renamed `tasks/` scripts, or a breaking change to the
`kwisatz` CLI · **MINOR** = a new `tasks/` script or a new config option · **PATCH** = fixes.

## [v1.2.0] — 2026-11-04

[Full notes](docs/releases/v1.2.0.md) · 56 commits since v1.1.0

### Added
- **`setup-matrix`** — self-hosted Matrix team chat behind Traefik (Synapse + PostgreSQL + MAS +
  Element Web), with optional LiveKit calls, federation, admin UI, metrics.
- **`setup-renovate`** — self-hosted Renovate on a systemd timer against Forgejo, opening bump PRs.
- **`setup-llm-gateway`** — private LiteLLM gateway: one OpenAI- and Anthropic-compatible endpoint
  in front of the llama-swap boxes, with session pinning, capacity caps, and a `DOCKER-USER`
  source allow-list.
- **`versions.yml`** — every upstream version kwisatz installs, in one file, read through
  `kw_image` / `kw_version` / `kw_pin`; `utilities/check-versions.sh` reports what is outdated.
- **Concourse Renovate-lookup pipeline** — a scheduled job that flags stale pins on the pipeline.
- **`orca-pair`** — helper that pairs an Orca client without transcribing the pairing code.

### Changed
- ~35 task scripts now read their version pins from `versions.yml` instead of hard-coding them.
- `setup-orca` updates and restarts on each apply when pinned to `latest`, and ignores the
  `ORCA_VERSION` that Orca's own terminals export.
- `setup-opencode` rebuilt for OpenCode 2.x.
- `setup-forgejo` moves to the 15 LTS line (held by Renovate).
- Image tags are no longer written inline in `machine-config.yml.example`; set one only to
  deviate on a single machine.

### Fixed
- fail2ban jail used filters removed upstream; Concourse worker registered under a new name on
  every container recreate; OpenWebUI re-runs failed on the port their own stack held;
  `check-versions --json` emitted invalid JSON on one path; `setup-basics` read its `nvm` pin
  before installing `python3-yaml`; Forgejo re-runs, Concourse `ssh-keygen` prompt, gateway
  config guard.

## [v1.1.0] — 2026-10-27

[Full notes](docs/releases/v1.1.0.md) · 52 commits since v1.0.0

### Added
- **The `kwisatz` CLI is the entry point** — `apply`, `status`, `list`, `info`, `doctor`,
  `config`, `services`, `logs`, `state`, `models`, `run`, `commands --json`, each with a
  documented `--json` envelope and a contractual exit code.
- **`setup-music-gen`** — ACE-Step 1.5 song generation (GPU server mode, CPU preview modes).
- Versioned pre-commit lint gate (`tests/git-hooks/pre-commit`).

### Changed
- The orchestrator is a pyinfra deploy: every apply, single-target or full, runs the same
  `deploy.py`.
- `apply` primes and holds the `sudo` ticket before the first script runs (`4`, not a traceback,
  where a closed stdin used to eat the run).
- A `--timeout` that runs out reports the target `not-run` and exits `5`.
- NetBird routing peer enrolls with a persisted setup key.

### Removed
- `run-setup.sh` — replaced by `./kwisatz apply` / `./kwisatz status` (see the notes for the two
  argument substitutions).

## [v1.0.0] — baseline

[Full notes](docs/releases/v1.0.0.md) · 335 commits, the only record before this tag is
`git log`.

[v1.2.0]: https://github.com/Kubementat/kwisatz/compare/v1.1.0...v1.2.0
[v1.1.0]: https://github.com/Kubementat/kwisatz/compare/v1.0.0...v1.1.0
[v1.0.0]: https://github.com/Kubementat/kwisatz/releases/tag/v1.0.0
