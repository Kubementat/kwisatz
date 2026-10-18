# Backup Feature — Live Test Report & Lessons Learned

**Date:** 2026-09-17
**Machine:** `evobox` (Ubuntu 24.04.3 LTS, amd64, systemd)
**Feature under test:** `tasks/setup-backup-client.sh` (local mode), `lib/docker-backup.sh`,
generated wrapper + systemd units — spec: `specification/features/setup-backup-server.md`
**Verdict:** PASS — general file backup and all four tested service backups
(forgejo, planka, openwebui, omnigent) verified end-to-end, including restore.

---

## 1. Purpose

Verify the backup feature works as specified on a live dev/server machine:

1. Set up a local-mode borg client ("a local copy of this machine") into a new backup
   directory.
2. Confirm the general file backup (`/etc`, `/srv`) is correct and byte-exact on restore.
3. Confirm the service-consistent backup layer (`lib/docker-backup.sh`) produces valid
   engine dumps for forgejo, planka, openwebui, and omnigent — and that `restore-db`
   round-trips.
4. Capture lessons learned for real fleet rollouts.

## 2. Test environment

| Item | Value |
|---|---|
| Host | `evobox`, Ubuntu 24.04.3 LTS, root FS `/dev/nvme0n1p5` (981 GB, 336 GB free at test time) |
| borg | 1.4.5 at `/usr/local/bin/borg` (manual install) — **shadows** apt `borgbackup` (`/usr/bin/borg`) via PATH/`secure_path` in all tested contexts |
| Backup user | `verfeinerer` (non-root; sudo-gated) |
| Live Docker services | forgejo (14), planka + planka-postgres, omnigent + omnigent-postgres, openwebui, hermes-gateway, grafana, prometheus, cadvisor, node_exporter, excalidraw, traefik |
| Backed-up paths | `/etc` (14 MB), `/srv` (2.3 GB) — home dir deliberately excluded (too large; 370 GB, mostly `.cache` 194 GB + `.lmstudio` 142 GB) |
| Services dumped | `forgejo,planka,openwebui,omnigent` |
| Staging dir | `/var/backup-staging-test` (must be outside `BACKUP_PATHS` — see Lesson 4) |
| Repo | `/home/verfeinerer/backups/machine_setup_automation_backup_test/evobox` |

### Command executed

```bash
sudo ./tasks/setup-backup-client.sh \
  --repo-path /home/verfeinerer/backups/machine_setup_automation_backup_test \
  --paths "/etc /srv" \
  --services "forgejo,planka,openwebui,omnigent" \
  --staging-dir /var/backup-staging-test \
  --initial
```

(No `--host` → local mode. Client name defaulted to the hostname `evobox`.)

## 3. Setup-phase results (setup script)

| Step | Result |
|---|---|
| borg present | detected (`borg 1.4.5`), no install needed |
| Repo init | `repokey` repo created at `…/machine_setup_automation_backup_test/evobox` |
| Passphrase | `~/.config/borg/evobox.pass` generated, mode 600, 32 chars; `~/.config/borg` mode 700 |
| Library install | `/usr/local/lib/borg-backup/docker-backup.sh` (644) |
| Staging dir | `/var/backup-staging-test` created 700, owner `verfeinerer` |
| Wrapper | `/usr/local/bin/borg-backup-evobox` (755) |
| systemd | `borg-backup-evobox.service` + `.timer` installed, `daemon-reload`, enabled and started; `Persistent=true`, `RandomizedDelaySec=15m` honored (next elapse observed: 00:14:54) |
| Initial backup | completed in foreground (see §4) |

All artifacts created (directories):

```
/home/verfeinerer/backups/{,machine_setup_automation_backup_test/,machine_setup_automation_backup_test/evobox/,…/evobox/data{,/0}}
/home/verfeinerer/.config/borg{,/security}
/var/backup-staging-test{,/dumps}
```

## 4. Backup-phase results

### 4.1 First full run (`evobox-2026-09-17T17:49:14`)

| Metric | Value |
|---|---|
| Engine dumps staged | forgejo zip **119,075,301 B**; planka `pg_dump` **70,964 B**; openwebui sqlite **692,224 B**; omnigent `pg_dump` **298,825 B** |
| Archive | 2.52 GB original → 1.71 GB compressed → **1.63 GB deduplicated**; 9,559 files; 6.78 s |
| Warnings | ~120 `Permission denied` (unreadable files — see Lesson 2); wrapper correctly treated borg exit 1 as "archive usable" and continued to `prune` |
| Staging after success | `dumps/` cleaned (dumps live only inside the archive) |

### 4.2 Second run — incremental/dedup (`evobox-2026-09-17T17:58:08`)

| Metric | Value |
|---|---|
| Duration | **0.56 s** (vs 6.78 s) |
| Deduplicated size | **9.29 MB** (vs 1.63 GB) — only 12 new unique chunks |
| Re-dumped services | all four, fresh timestamps, re-archived |
| prune | ran, no archives removed (retention 7/4/12 not yet reached) |

Dedup/incremental behavior confirmed (spec T3.1).

### 4.3 Dump validity (extracted from the archive, then validated)

| Service | Dump | Validation method | Result |
|---|---|---|---|
| forgejo | `forgejo-2026-09-17T174915.zip` | `unzip -t` | no errors; contains `app.ini` + all git repos (DB+repos+LFS+config as designed) |
| planka | `planka-2026-09-17T174915.dump` | `pg_restore --list` in `postgres:16-alpine` container | valid CUSTOM format, `dbname: planka`, 196 TOC entries |
| omnigent | `omnigent-2026-09-17T174918.dump` | `pg_restore --list` in `postgres:16-alpine` container | valid CUSTOM format, `dbname: omnigent`, 91 TOC entries |
| openwebui | `openwebui-2026-09-17T174915.sqlite` | `PRAGMA integrity_check` via python in `openwebui` container | `ok`, 43 tables |

Note: the host has **no** `pg_restore`/`sqlite3` CLI — validating inside the services' own
Docker images (both already local) is the clean pattern (Lesson 12).

### 4.4 File restore — byte-exact (spec T4.1)

`restore <snap> --dest /tmp/bk-verify-files etc/os-release srv/forgejo`:

- `/srv/forgejo`: **3,931/3,931** readable source files restored; full `diff -rq` shows
  zero content differences. Spot-checks sha256-identical (git objects, refs).
- Only gap: `data/ssh` (root-owned, unreadable by backup user) — expected, see Lesson 2.
- Symlinks preserved as symlinks (e.g. `/etc/os-release -> ../usr/lib/os-release`;
  link target outside the backed-up paths is not in the archive — correct behavior).

### 4.5 `restore-db` round-trip (openwebui, destructive path)

`restore-db evobox-2026-09-17T17:49:14 openwebui --yes`:

1. Wrapper extracted the dumps dir from the archive (picked the `openwebui-<ts>.sqlite`).
2. Container stopped (no sqlite3 CLI in image → stop/copy/start fallback, ~3 s downtime).
3. Dump copied to `/app/backend/data/webui.db`, container started, wait-for-running passed.
4. **Post-check:** live container `webui.db` sha256 `a3c883c4…` == archived dump ==
   pre-restore live DB. Container back up and healthy.

### 4.6 `--check` mode (spec T4.2)

All green, exit 0:

```
[OK] borg: borg 1.4.5
[OK] Passphrase file: …/evobox.pass (mode 600)
[OK] Repo reachable: …/evobox
[OK] Timer active (next: Fri 2026-09-18 00:14:54)
[OK] Last service run: success
[OK] Latest snapshot: evobox-2026-09-17T17:58:08
```

### 4.7 Spec test-ID coverage

| ID | Description | Result |
|---|---|---|
| T2.2 | Client setup, fresh repo (passphrase 0600, timer active, exit 0) | PASS (local-mode variant) |
| T2.5 | `--initial` foreground full backup | PASS |
| T2.6 | Local mode: repo on a local path | PASS |
| T3.1 | Second run: transferred bytes ≪ snapshot size | PASS (9.29 MB / 0.56 s) |
| T4.1 | Restore matches source byte-for-byte | PASS (3,931/3,931 files) |
| T4.2 | `--check` all green | PASS |
| — | Service dump validity + `restore-db` round-trip | PASS (beyond the v1 table) |
| T1.1–T1.4, T2.1, T2.3, T2.4, T3.2, T3.3, T4.3 | server script, SSH preflight failure, re-run idempotency, passphrase loss, lock contention, prune retention, check-with-disabled-timer | **not exercised** this test |

Repo footprint at test end: **1.6 GB** on a 336 GB-free filesystem.

## 5. Lessons learned

1. **Client name charset blocks underscores.** `BACKUP_CLIENT_NAME` must match
   `^[a-z0-9-]+$` (`tasks/setup-backup-client.sh:240`), and the repo layout is
   `<repo-path>/<client>/`. A desired directory like `machine_setup_automation_backup_test`
   can therefore only be a `--repo-path` parent, not the repo dir itself. Options:
   hyphenated client name, or keep the desired dir as `--repo-path` and let the client
   default to the hostname (what this test did).

2. **Backup coverage is bounded by the backup user's read access.** Files unreadable by
   `BACKUP_USER` are skipped with `Permission denied` warnings; borg exit 1 means the
   run still "succeeds" (by design, spec Behavior 3). On evobox ~120 files were skipped:
   root-only `/etc` files (`shadow`, `sudoers`, ufw rules, ssh host keys, libvirt XML)
   and other-user-owned data (`/srv/hermes/workspace/**`, `grafana.db`,
   `/srv/planka/postgres`, `/srv/forgejo/data/ssh`). The warnings are easy to miss in a
   long log. For a complete `/etc` backup, run the timer as root (`--local-user root`)
   or grant read access. (Service DBs were unaffected: dumps run inside containers as the
   container's own credentials.)

3. **Backing up docker volumes needs a chmod.** `/var/lib/docker` is `0710 root:root`;
   a non-root backup user cannot traverse it, so `/var/lib/docker/volumes` would be
   silently empty. Fix: `chmod 755 /var/lib/docker` (traverse bit only, contents
   untouched). Volumes were dropped from this test's scope for that reason.

4. **Staging dir must be outside `BACKUP_PATHS`.** The default `/srv/backup-staging`
   fails validation whenever `/srv` is backed up (`setup-backup-client.sh:282`).
   Used `/var/backup-staging-test`. Rollout docs should call this out for
   `/etc /srv` scopes.

5. **openwebui has no sqlite3 CLI → stop/copy/start fallback**
   (`lib/docker-backup.sh:207-221`): ~3 s of downtime per backup run, container verified
   running afterwards. Acceptable for a dev machine; for a busy production instance,
   prefer an image/entrypoint with `sqlite3` or add openwebui to `BACKUP_STOP_SERVICES`.

6. **Two borg installs coexist.** Manual `/usr/local/bin/borg` (1.4.5) shadows apt
   `/usr/bin/borg` in sudo (`secure_path`) and systemd PATH. Harmless while both are
   1.x, but any future version skew would desync the remote-mode version-pairing
   preflight. Keep both on the same apt release or remove the manual one.

7. **Passphrase file vs. backup paths.** `~/.config/borg/<client>.pass` must stay outside
   every backed-up path (spec §5). It does here (home not backed up); if you back up
   `/home/<user>`, the pass file lands in the archive — same disk, so no new exposure,
   but it violates the spec's own guidance. Worth an automated warning in `validate()`
   (see Recommendations).

8. **`restore-db` extracts the whole dumps dir** to fetch one service's dump — all four
   dumps (incl. the 119 MB forgejo zip) were extracted to restore a 692 KB sqlite file.
   Correct, but O(all dumps) per restore (Lesson → Recommendation 3).

9. **Local mode is same-disk by definition.** This repo protects against software
   corruption and accidental deletion, not disk failure (spec Future Work 3: offsite
   copy / `borg replicate`). The mount guard (`REPO_MOUNT_SOURCE`) only prevents writing
   chunks into the root FS if the dedicated drive disappears.

10. **Excludes matter more than they look.** evobox home is 370 GB: `.cache` 194 GB is
    excluded by default, but `.lmstudio` (142 GB of re-downloadable model binaries) is
    **not** — add `(^|/)\.lmstudio/` (or similar) to `BACKUP_EXCLUDE_REGEXES` for dev
    machines before the first run.

11. **Incremental economics are excellent.** After the 1.63 GB first run, the next full
    scan (9,559 files + 4 fresh engine dumps) cost 9.29 MB / 0.56 s. Daily timer runs on
    this machine type are negligible; the initial run is the only expensive one.

12. **Validation pattern for dump artifacts without host CLIs.** The host lacks
    `pg_restore`/`sqlite3`; the services' own images do (or can). `docker run --rm -v
    <dump>:/d:ro postgres:16-alpine pg_restore --list …` and
    `docker run --rm -v <db>:/db:ro <openwebui-image> python3 -c "sqlite3…integrity_check"`
    validated artifacts definitively. Same trick works for any `bk_*` dump type.

13. **Cosmetic:** the final "Check:" hint prints `--host <empty>` in local mode
    (`setup-backup-client.sh:935`).

## 6. Recommendations (candidate follow-ups)

1. `validate()`: warn (or fail) when the passphrase file path (`~/.config/borg/<client>.pass`)
   falls inside any `BACKUP_PATHS` entry (spec §5 currently only relies on the printed warning).
2. `--check` or a `coverage` subcommand: report how many files were unreadable in the last
   run (borg stores these stats per archive: `borg info <snap>` shows "Unreadable files" /
   "Changed files") so Lesson 2 cannot be silently overlooked.
3. `restore-db`: extract only `…/dumps/<svc>-*` from the archive (borg accepts path
   patterns) instead of the entire dumps dir (Lesson 8).
4. Fix the empty `--host` in the local-mode hint line (Lesson 13).
5. Document in the spec Rollout: the `/var/lib/docker` chmod requirement for volume
   backups (Lesson 3) and the staging-dir-inside-`/srv` collision for `/etc /srv` scopes
   (Lesson 4).
6. Consider accepting `_` in `BACKUP_CLIENT_NAME` (borg repo paths accept it) or
   documenting the constraint (Lesson 1).

## 7. Cleanup (tested commands)

Everything this test created, removed in dependency order:

```bash
sudo systemctl disable --now borg-backup-evobox.timer
sudo rm /etc/systemd/system/borg-backup-evobox.service \
        /etc/systemd/system/borg-backup-evobox.timer
sudo systemctl daemon-reload
sudo rm /usr/local/bin/borg-backup-evobox
sudo rm -r /usr/local/lib/borg-backup
rm -r /var/backup-staging-test
rm -r /home/verfeinerer/backups/machine_setup_automation_backup_test
rmdir /home/verfeinerer/backups
rm -r /home/verfeinerer/.config/borg          # passphrase + borg security db
# optional:
sudo apt-get remove -y borgbackup && sudo apt-get autoremove -y
rm -r /tmp/bk-verify-dumps /tmp/bk-verify-files /tmp/openwebui-before.db /tmp/openwebui-after.db
```

Deleting both the repo and `~/.config/borg` makes the backup unrecoverable — intended for
a test teardown.
