# Plan: update every entry of versions.yml

Date: 2026-11-11 · Branch: `develop` (work via `git worktree` feature branch)

## How this was produced (and how to re-verify)

- `./utilities/check-versions.sh --json` (Renovate `44.193.0` dry-run, gh token) — full lookup, no warnings, all datasources resolved.
- Ambiguous "up to date" entries re-checked by hand against upstream (GitHub API, Docker Hub tag lists) on 2026-11-11.
- `renovate.json` `allowedVersions` cross-checked: HELD entries match their `# HELD` comments.

Re-verify before applying: re-run `./utilities/check-versions.sh --json` and diff.

## A. Safe patches — bump directly, one commit (low risk, no data migration)

| key | current | latest stable | note |
|---|---|---|---|
| renovate | 44.193.0 | 44.227.4 | the lookup tool itself |
| grafana | 13.3.0 | 13.3.1 | |
| traefik | v3.7.16 | v3.7.18 | n8n sidecar shares the entry |
| elasticsearch | 7.17.27 | 7.17.28 | patch, inside HELD <8 |
| kestra | v2.0.8 | v2.0.10 | |
| opencode | 2.2.5 | 2.2.7 | also npm `@opencode/cli` pin |
| dagu | 2.16.2 | 2.26.0 | many minors, no breaking |
| omnigent-server | v0.20.0 | v0.21.0 | |
| orca | v1.4.247 | v1.4.256 | |
| nanobot | v0.4.0 | v0.4.1 | script builds from tag |
| pi-pocket | v0.28.0 | v0.28.1 | bump tag **and** digest |
| nvm | v0.40.4 | v0.41.0 | |
| laya | 0.3.19 | 0.4.31 | PyPI; read changelog |
| llama-swap | v268 | v272 | build tags, months of fixes |

Verify: `shellcheck`/`yamllint`, `tests/unit/test_versions.py`, then the VM tests of the affected tasks (`tests/README.md`); each script's own `wait_for_healthy` proves the stack.

## B. Minor bumps with a release-notes gate

Read each project's release notes for breaking changes **before** merging; bump with a one-line note of what was checked.

| key | current | latest stable | gate |
|---|---|---|---|
| agentsview | v0.46.1 | v0.47.0 | 0.x minor, Renovate flags breaking |
| openwebui | v0.11.1 | v0.13.3 | spans v0.12 + v0.13 notes |
| litellm | v1.106.6 | v1.108.5 | fast-moving; check breaking |
| postiz | v2.24.0 | v2.25.3 | |
| temporal | 1.28.1 | 1.29.7 | **verify ES 7.x still supported for visibility** before moving — the entry is HELD <8 |
| temporal-ui | 2.34.0 | 2.58.1 | check UI↔server compatibility matrix |
| synapse | v1.164.2 | v1.165.0 | |
| mas | 1.28.0 | 1.29.0 | check synapse↔MAS compatibility |
| planka | 2.2.1 | 2.3.1 | |
| vllm | v0.27.1 | v0.33.0 | 6 minors; per versions.yml comment **re-run the F21 registry probe** |
| netbird (server/client/dashboard) | 0.77.1 / v2.91.1 | 0.82.1 / v2.96.1 | all three must move together; check breaking across 5 minors |
| gufo | 0.8.1 | 0.33.0 | per the comment: **read the upstream source of the new tag** — serve flags can change; verify digest pin moves too |

## C. Major decisions — one ticket each, never in the sweep commit

| key | current | candidate | what has to go first |
|---|---|---|---|
| n8n | 2.37.4 | 3.2.0 | read breaking-changes guide; check minimum postgres (its DB is HELD to 15) — if v3 needs 16+, the HELD rule and `n8n-postgres` move together |
| nvidia-smoke | 24.04 | 26.04 | allowed by the HELD regex (`^\d\d\.04$`, LTS-only); re-run the CDI smoke test after the bump |
| postiz-redis | 7.2 | 8.10 | Redis 8 RDB/AOF from 7.x: check Postiz docs; redis data volume survives, but test |
| nextcloud-redis | 7-alpine | 8-alpine | same reasoning; Nextcloud fully supports 8 |
| ngc-pytorch | 25.10-py3 | 26.10-py3 | **only with colqwen**: must match the host CUDA driver *and* colpali-engine's torch pin. Decide together with colpali-engine (see D); do not bump casually |
| nvm→ nothing | | | (done in A) |

## D. HELD entries — deliberate no-ops, revisit when unhold conditions clear

No action in this sweep:

- `nextcloud` 34-apache — Nextcloud upgrades one major at a time; move major + renovate rule deliberately after a backup.
- `forgejo` 15.0.11 — 15.x line already latest; 16 exists (15 LTS security until 2027-07-15, one-way DB migrations).
- `colpali-engine` 0.3.13 — **0.3.18 now exists** but HELD <0.3.14 (transformers 5.x drops the LoRA weights of `vidore/colqwen2.5-v0.2`). Unhold only after proving the weights load under the newer stack — then it becomes a colqwen epic together with `ngc-pytorch`.
- `elasticsearch` 7 — HELD <8 by Temporal; only patches like 7.17.28 apply.
- All `*-postgres` majors (17/16/15/14) — HELD per service; pg_upgrade needed. Note: 17-alpine and 16 are still the latest allowed; postgres 18 exists.
- `nvidia-smoke` 24.04 — covered in C.

## E. Floating digests / custom sources

| key | current digest/version | upstream state | action |
|---|---|---|---|
| omnivoice | `1a468d8` | master `dbfc792d` (2026-11-06) | bump digest, rebuild, run the TTS smoke (omnivoice-tts skill) |
| tensorfold-flash-recipe | `4e1239d` | main `20e15e4` (2026-10-30) | bump digest, rebuild local image; engine pin lives inside the recipe — re-test the setup task |
| tensorfold-27b-recipe | `c11ff13` | unchanged | no-op |
| excalidraw | `sha256:f7ee194…` | `latest` digest identical (2026-05-06) | no-op — upstream has not pushed a newer `latest` |
| hermes | v2026.9.24 / `f97608f` | newest tag | no-op |
| lm-studio | 0.4.6-1 | **0.4.28-2** (vendor site) | custom datasource, Renovate blind; script auto-detects at runtime so it is a marker — bump for accuracy |
| vllm-omni | v0.32.0 | v0.32.0 is the newest release tag (only `nightly-*`/rc above) | no-op |
| vllm-omni-rocm | v0.30.0 | v0.31.0 stable not published (only rc) | no-op |
| ace-step | v0.1.8 | newest tag (`ACE-Step/ACE-Step-1.5` — note Renovate's case-insensitive resolution) | no-op |
| element | v1.12.33 | only 1.12.34-rc above | no-op |

## F. Renovate blind spot to fix in the same branch: llama-cpp

- Pin `b11981` is stale: newest build is **`b12262`** (2026-11-10). Renovate reported "no update" because the `b*` releases are all flagged **prerelease** upstream (and the `regex:^b(?<major>\d+)$` versioning makes every bump a major).
- Action: bump to `b12262`; then make Renovate track it (try `followTag`, or check the `github-releases` + prerelease options in Renovate docs — verify with a dry-run, don't guess).
- If upstream's semver-style `v0.9.0` releases are actually "stable llama.cpp", switching the pin scheme is a script-level decision (`setup-*` reads `kw_version`); keep tracking `b<N>` unless the script's install path says otherwise.

## Execution order

1. Branch `chore/versions-yml-2026-11-11` off `develop` via `git worktree`.
2. Commit 1: all of group A. Run `test_versions.py`, `yamllint`, affected task VM tests.
3. Commits 2…n: group B entries (or small groups) with release-note checks recorded in the commit message.
4. One ticket per group C item — each gets its own branch with backup + rollback steps documented; these do **not** block the sweep.
5. Group E digest bumps (omnivoice, tensorfold-flash, lm-studio marker).
6. llama-cpp bump + Renovate config fix (F), confirm with a `check-versions.sh --json` re-run that nothing shows up as outdated anymore.
7. Keep `# HELD` comments and `renovate.json` rules in sync — the unit test enforces it; if a bump changes a rule, change both.
8. Re-run `./utilities/check-versions.sh --json` on the branch tip as the final "am I done" check.

## Result (2026-11-11, VM end-to-end verdict)

All 53 VM-testable scripts exercised twice (integration + idempotency) via
virt-runner across rounds 1-6 on branch `chore/versions-yml-2026-11-11`.
Every failure found was root-caused, fixed and re-verified:

| Failure | Root cause | Fix |
|---|---|---|
| zed / agent-docker-runner | `~/.local/bin` not in non-login PATH | verify both paths + export PATH (fe9076b, 213286a) |
| lm-studio / whispering | `~/Desktop` missing on headless hosts | `mkdir -p` before .desktop write (fe9076b) |
| kestra idempotency | port check tripped by own running stack | tolerate own `kestra` container (fe9076b) |
| memory-safety | root-only gate, never used in orchestrator | self-elevate via sudo (fe9076b) |
| samba | interactive `smbpasswd` despite INTERACTIVE=false | non-interactive + `.samba.env` (fe9076b) |
| opencode | nvm npm not on PATH → apt prefix → EACCES | load nvm before npm (fe9076b) |
| deepseek-harness | bare npm resolves `*`, never prereleases | pin `@deepseek-ai/dsh` (fe9076b) |
| nanobot | upstream base image lost npm | Node tarball in Dockerfile.extend (fe1f6f9) |
| llama-cpp fresh host | user git clone into root-owned /opt | privileged clone + drop ownership (c539e9e) |
| llama-cpp VM runs | bare `git config` resolves copied worktree pointer | `git -C /` (02d6ae9) |
| postiz stack timeout | temporal-ui 2.58 busybox image has no curl | healthcheck → wget (f96df34) |
| postiz first-run 502 | cold-stack register POST via Next proxy | bounded retry (94c96c0) |
| concourse re-run crash-loop | `ip_tables` module never loaded in guest | modprobe + modules-load.d (213286a) |

Final rounds: R5 14/15, R6 7/7 — everything the VM layer can prove is
green, twice per script where idempotency applies. The 10 GPU/DGX-bound
scripts (vllm, vllm-omni, colqwen, omnivoice, tensorfold ×2, gufo ×2,
strix-halo-tuning, nvidia-container) keep their pins but need the real
hardware to verify.

## Out of scope

- Model weights / `models.yml`, CUDA driver upgrades, the actual host deploys (that is `kwisatz apply`, not this plan).
