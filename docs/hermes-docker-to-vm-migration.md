# One-off migration: Hermes Agent from Docker to the VM

This is a manual, one-time procedure for the server that still runs the former Docker-based
Hermes setup (`/srv/hermes/docker-compose.yml`, data in `/srv/hermes/.hermes`, uid 10000).
It is intentionally **not** part of `tasks/setup-hermes.sh`. Background:
`docs/plans/hermes-vm-refactor.md`, `docs/research/hermes-agent-vm-install.md`.

There is no official Docker → native migration path. The data layout is identical
(`/opt/data` in the container == `~/.hermes` natively), and `hermes backup` / `hermes import` are
the supported tools, so this procedure uses them and keeps a cold copy as a fallback.

**Rules**

- Never run the Docker gateway and the VM gateway at the same time (same bot tokens).
- The old stack is only stopped, never deleted, until the soak period is over.
- The archives created here contain secrets (`.env`). Keep them mode 600 and delete the
  migration zip at the end.

Run everything on the server as your normal user (uid 1000) unless a step says "in the guest".
Run `tasks/setup-hermes.sh` from the kwisatz checkout that contains the VM-based script.

## 0. Before you start

```bash
cd /srv/hermes
sudo ls -la /srv/hermes /srv/hermes/.hermes | head -40      # what exists
docker compose ps                                            # hermes-gateway should be listed
docker inspect hermes-gateway --format '{{.Config.Image}}'   # note the old image tag
sudo du -sh /srv/hermes/.hermes /srv/hermes/workspace         # size → time/disk needed
df -h /srv                                                   # enough room for 2 copies?
test -f /srv/hermes/.env && echo "compose-level .env present"   # see step 6
```

Note the old image tag: _______________________

If `/srv/hermes/.env` exists: the old `docker-compose.yml` read provider keys such as
`GITHUB_TOKEN` / `OPENROUTER_API_KEY` from it (compose variable substitution). It is **not** part
of `hermes backup` and **not** part of the cold tar (that only covers `.hermes`), so it must be
merged manually in step 6.

## 1. Stop the old gateway

```bash
cd /srv/hermes
docker compose stop hermes-gateway
docker ps --format '{{.Names}}' | grep -x hermes-gateway && echo "STILL RUNNING" || echo "stopped"
```

Expected: `stopped`.

## 2. Cold safety copy of the data directory

```bash
sudo mkdir -p /srv/hermes/backups
sudo chown "$(id -u):$(id -g)" /srv/hermes/backups
chmod 700 /srv/hermes/backups

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -C /srv/hermes -czf "/srv/hermes/backups/hermes-docker-data-${STAMP}.tar.gz" .hermes
sudo chown "$(id -u):$(id -g)" "/srv/hermes/backups/hermes-docker-data-${STAMP}.tar.gz"
chmod 600 "/srv/hermes/backups/hermes-docker-data-${STAMP}.tar.gz"
tar -tzf "/srv/hermes/backups/hermes-docker-data-${STAMP}.tar.gz" | head
```

Expected: the listing shows `.hermes/config.yaml`, `.hermes/.env`, … This archive is the
fallback for step 6 and the rollback; keep it until the migration is confirmed.

## 3. Portable archive with the old image's own tooling

```bash
cd /srv/hermes
docker compose run --rm hermes-gateway backup -o /workspace/hermes-migration.zip
ls -la /srv/hermes/workspace/hermes-migration.zip
```

Expected: exit code 0 and a zip file. Exit code 1 means some files were skipped (the zip is
kept; read the output). If the old image has no `backup` command or it fails, skip this step
and use the fallback in step 6b.

## 4. Hand the shared directories to your user

The Docker image wrote as uid 10000; the VM guest user is uid 1000 and virtiofs passes UIDs
straight through.

```bash
sudo chown -R "$(id -u):$(id -g)" /srv/hermes/workspace /srv/hermes/backups
chmod 600 /srv/hermes/workspace/hermes-migration.zip
```

`/srv/hermes/.hermes` stays untouched (still uid 10000) so the old stack can be restarted.

## 5. Create the VM and install Hermes

Use the same environment you intend to keep (allowlist, serve). Example:

```bash
cd ~/dev/kwisatz        # your kwisatz checkout
HERMES_ALLOWED_ENDPOINTS="host:3000 host:8080" ./tasks/setup-hermes.sh
```

Expected: no warning about a running `hermes-gateway` Docker container; the script creates the
VM, installs Hermes and starts an idle, unconfigured gateway service. Stop it before the
import (`virt-runner ssh hermes`, then `hermes gateway stop`).

## 6. Import the data in the guest

```bash
virt-runner ssh hermes
```

### 6a. Preferred: `hermes import`

In the guest:

```bash
ls -la /workspace/hermes-migration.zip
hermes import /workspace/hermes-migration.zip --force

# Only if /srv/hermes/.env exists on the host. It is NOT shared with the guest
# (only /workspace and /mnt/backups are), so bring it in first — on the host:
#   scp /srv/hermes/.env ubuntu@<vm-ip>:~/.hermes-compose.env
# then back in the guest, inspect it and append the keys that are not already in
# ~/.hermes/.env (it may duplicate provider keys the import already restored):
#   cat ~/.hermes-compose.env
#   rm ~/.hermes-compose.env   # after merging
hermes config migrate
hermes config set terminal.backend local
hermes config set terminal.cwd /workspace
chmod 600 ~/.hermes/.env
grep -rn '/opt/data' ~/.hermes/config.yaml ~/.hermes/cron 2>/dev/null   # Docker-era paths
hermes doctor
```

Expected: `hermes import` exits 0; `hermes doctor` reports no blocking problem. If the `grep`
prints lines, replace `/opt/data` with `/home/ubuntu/.hermes` in those files. The old compose
file set `TERMINAL_ENV=local` / `TERMINAL_CWD=/workspace` through the container environment;
the two `hermes config set` lines carry that over.

Known risk: the import crosses the v0.21.0 session-store rewrite (`state.db`; fixed in
v0.21.2, the VM installs v0.21.5). If the import fails, or sessions are missing/corrupt
afterwards, use 6b.

### 6b. Fallback: copy from the cold archive

In the guest (the archive from step 2 is visible under `/mnt/backups`):

```bash
systemctl --user stop hermes-gateway 2>/dev/null || true
mkdir -p ~/hermes-old
tar -xzf /mnt/backups/hermes-docker-data-*.tar.gz -C ~/hermes-old
ls -la ~/hermes-old/.hermes

# Identity, memory, skills, config, secrets, schedules
cd ~/hermes-old/.hermes
cp -a SOUL.md config.yaml .env ~/.hermes/ 2>/dev/null
for d in memories skills cron hooks skins; do
  [ -d "$d" ] && cp -a "$d" ~/.hermes/
done
chmod 600 ~/.hermes/.env

# Optional: conversation history. Skip these three lines if state.db was the problem.
cp -a state.db* ~/.hermes/ 2>/dev/null
[ -d sessions ] && cp -a sessions ~/.hermes/

cd ~
hermes config migrate
hermes config set terminal.backend local
hermes config set terminal.cwd /workspace
hermes doctor
```

If `hermes doctor` or the gateway then fails on `state.db`, remove `~/.hermes/state.db*` and
`~/.hermes/sessions` and accept losing the session history; memories, skills and `SOUL.md`
are independent of it. Delete `~/hermes-old` when done (it contains secrets).

## 7. Start the gateway

Leave the guest (`exit`) and re-run the script with the same environment as in step 5:

```bash
HERMES_ALLOWED_ENDPOINTS="host:3000 host:8080" ./tasks/setup-hermes.sh
```

Expected: "hermes-gateway.service is active" and the summary shows `Gateway   running`.

If the old stack used a local LLM endpoint, wire the VM to it in the same re-run — Hermes reads
the endpoint's OpenAI-compatible API instead of the imported cloud-provider keys:

```bash
HERMES_ALLOWED_ENDPOINTS="host:3000 host:8080" \
HERMES_LLM_BASE_URL="http://192.168.122.1:9292/v1" HERMES_LLM_MODEL="<id from /v1/models>" \
HERMES_LLM_API_KEY="<key>" ./tasks/setup-hermes.sh
```

(The LLM endpoint is added to the allowlist automatically, so `host:9292` need not be listed.
The key goes into the guest's `~/.hermes/.env` only if absent; re-runs never rotate it.)

## 8. Verify

```bash
virt-runner ssh hermes
```

In the guest:

```bash
systemctl --user is-active hermes-gateway        # active
journalctl --user -u hermes-gateway -n 50 --no-pager
ls ~/.hermes/memories ~/.hermes/skills | head
hermes status
```

Then, from your messaging client: send a test message, ask about something only the old
memory knows, and run one command that touches `/workspace`. Platform logins stored in
browser profiles or credential stores are **not** in `hermes backup`; re-pair those platforms
(`hermes gateway setup`) if they fail.

## 9. Clean up

Immediately:

```bash
shred -u /srv/hermes/workspace/hermes-migration.zip 2>/dev/null \
  || rm -f /srv/hermes/workspace/hermes-migration.zip
```

After a soak period (e.g. two weeks) with the VM working:

```bash
cd /srv/hermes
docker compose down                       # removes the stopped containers only
sudo rm -f /srv/hermes/docker-compose.yml /srv/hermes/restart_hermes.sh
shred -u /srv/hermes/.env 2>/dev/null || rm -f /srv/hermes/.env   # if it existed (step 0)
docker image rm "<old image tag from step 0>"
# Finally, when you are sure:
sudo rm -rf /srv/hermes/.hermes
rm -f /srv/hermes/backups/hermes-docker-data-*.tar.gz
```

## 10. After cleanup: host-side backups take over

Once `/srv/hermes/.hermes` is gone, the **only** copies of the live config/secrets are what
the VM writes out: the nightly `hermes backup` zips and the plain-text mirror in
`/srv/hermes/backups/current/` (see `AUTOMATIONS.md` — both inside the host backup /
borg scope). Before step 9's `rm -rf`, confirm the timer has run at least once
(`systemctl --user status hermes-backup.timer` in the guest, newest file in `/srv/hermes/backups`)
— and remember that browser profiles / platform credentials are in neither.

## Rollback (any time before step 9's second block)

```bash
# 1. Stop the VM gateway so both never run together
virt-runner ssh hermes
#    in the guest:
systemctl --user disable --now hermes-gateway
exit

# 2. Give the workspace back to the container user and start the old stack
sudo chown -R 10000:10000 /srv/hermes/workspace
cd /srv/hermes
docker compose up -d hermes-gateway
docker logs --tail 50 hermes-gateway
```

`/srv/hermes/.hermes` was never modified, so the old gateway resumes with the state it had in
step 1. The VM can stay (shut it down with `virsh -c qemu:///system shutdown hermes`) or be
removed with `virt-runner destroy hermes`.
