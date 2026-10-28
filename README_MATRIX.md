# Matrix team chat (`setup-matrix.sh`)

A private, self-hosted [Matrix](https://matrix.org) chat server for a team of 5–50 people:
Synapse (homeserver) + PostgreSQL + Matrix Authentication Service (MAS) + Element Web, behind
the shared Traefik proxy. Calls (voice/video), an admin UI, federation and metrics are opt-in.

Background and the reasoning behind every default: [docs/research/2026-10-28-matrix-self-hosting.md](docs/research/2026-10-28-matrix-self-hosting.md).
Implementation plan: [docs/plans/matrix-setup-plan.md](docs/plans/matrix-setup-plan.md).

## 1. Before the first run

**Pick the server name — it can never change.** `MATRIX_SERVER_NAME` is the part after the colon
in every user ID (`@alice:example.com`) and room ID, and it is baked into the signing key. A
re-run with a different value stops with an error. Changing it means a new, empty server.
Usually it is your apex domain (`example.com`); the homeserver itself then runs on
`matrix.example.com`, and a small `.well-known` document on `example.com` points there.

**Prerequisites:** `kwisatz apply docker` and `kwisatz apply traefik` (Traefik is mandatory:
Element X only talks to servers with a trusted certificate).

**DNS** — A/AAAA records pointing at this host (or NetBird DNS records for a VPN-only server):

| Host | Default | Needed for |
|---|---|---|
| `MATRIX_DOMAIN` | `matrix.<server_name>` | always (Synapse) |
| `MATRIX_AUTH_DOMAIN` | `auth.<server_name>` | always (login, accounts) |
| `MATRIX_CHAT_DOMAIN` | `chat.<server_name>` | always (Element Web) |
| `MATRIX_SERVER_NAME` | — | `MATRIX_WELLKNOWN=traefik` (the default): serves `/.well-known/matrix/*` |
| `MATRIX_RTC_DOMAIN` | `rtc.<server_name>` | `MATRIX_RTC=true` |
| `MATRIX_ADMIN_DOMAIN` | `admin.<server_name>` | `MATRIX_ADMIN_UI=true` |

If the apex (`example.com`) is your company website hosted elsewhere, run with
`MATRIX_WELLKNOWN=external`: the script prints the two JSON documents and headers to publish there.

**VPN-only (NetBird):** use names that resolve only in NetBird DNS, and run Traefik with
`DNS_PROVIDER` (DNS-01): Let's Encrypt cannot reach the host over HTTP-01. Set
`LIVEKIT_NODE_IP` to the host's NetBird IP if you enable calls. Mobile push still needs outbound
HTTPS to `matrix.org` (see §8).

## 2. Install

```bash
# machine-config.yml
setup-matrix:
  enabled: true
  env:
    MATRIX_SERVER_NAME: example.com
    MATRIX_RTC: 'true'          # optional: calls
kwisatz apply matrix

# or directly
MATRIX_SERVER_NAME=example.com MATRIX_RTC=true ./tasks/setup-matrix.sh
./tasks/setup-matrix.sh --help   # every option
```

The first run takes a few minutes (image pulls). It ends with a summary: URLs, the admin user, and
where the admin password is (`sudo grep MATRIX_ADMIN_PASSWORD /srv/matrix/.env`).

Until DNS points at the host and Let's Encrypt has issued certificates, the script warns that it
could not verify the routes through Traefik (Traefik refuses TLS for names it has no certificate
for). Re-run it once DNS is in place; a clean run prints `… (via Traefik) ready.`

## 3. Accounts

Registration is closed: the server is invite-only. All account management goes through MAS:

```bash
# create a user (prompts for the password)
sudo docker exec -it matrix-mas mas-cli manage register-user alice
# admin rights, password reset, locking
sudo docker exec matrix-mas mas-cli manage promote-admin alice
sudo docker exec -it matrix-mas mas-cli manage set-password alice '<new password>'
sudo docker exec matrix-mas mas-cli manage lock-user alice
sudo docker exec matrix-mas mas-cli manage kill-sessions alice
```

Self-registration with invite tokens (`mas-cli manage issue-user-registration-token`) needs MAS's
`account.password_registration_enabled` and `registration_token_required`. This setup leaves both
off, so `register-user` is the way to add people.

There is no email in v1, so "forgot password" does not exist: an admin resets passwords with
`set-password`. The first admin (`MATRIX_ADMIN_USER`, default `admin`) is created on the first run
only. Changing `MATRIX_ADMIN_PASSWORD` later is not applied: the script warns and prints the
`set-password` command.

## 4. Team onboarding (send this to your team)

1. Install **Element X** (iOS / Android) or open `https://chat.<server_name>` in a browser.
2. Sign in with the server name `<server_name>` and the username/password you were given.
   Element X finds the server by itself through `<server_name>`.
3. **Set up secure backup and save your recovery key** when Element asks. Messages are end-to-end
   encrypted: on a new phone, or after a password reset, old messages can only be read with
   that recovery key (or another logged-in device). Nobody, including the admin, can recover
   them for you.
4. Verify new devices when Element asks (scan the QR code with a device that is already logged in).

## 5. Calls (`MATRIX_RTC=true`)

Voice/video calls use MatrixRTC (Element Call, built into Element Web and Element X): a LiveKit
media server (SFU) plus lk-jwt-service, which hands LiveKit tokens to logged-in users of this
server only. With calls on:

- `rtc.<server_name>` must resolve here, and two ports must reach the host directly:
  **7881/tcp** (ICE/TCP) and **7882/udp** (all media, one UDP port). The script adds UFW rules;
  open them on any upstream firewall/router too. Docker-published ports bypass UFW's INPUT rules,
  so they are reachable whenever the host is.
- `/.well-known/matrix/server` is published even on a private server: lk-jwt-service finds this
  homeserver through it to validate user tokens. It does not enable federation.
- Element's legacy 1:1/Jitsi calls are switched off (`element_call.use_exclusively`).
- No TURN server: users behind very strict firewalls (UDP blocked and only 443 allowed) may fail
  to connect. LiveKit's embedded TURN would be the next step (not set up here).

## 6. Admin UI and Admin API

`MATRIX_ADMIN_UI=true` adds Ketesa at `admin.<server_name>`. It and Synapse's `/_synapse/admin` API
are reachable only from `MATRIX_ADMIN_ALLOW_CIDRS` (default: loopback, RFC1918, NetBird
`100.64.0.0/10`). Log in with an admin account. Users are still *created* with `mas-cli` (§3).

## 7. Federation (`MATRIX_FEDERATION=true`)

Default is a private server: it neither talks to nor accepts other Matrix servers. To join the
wider Matrix network:

1. Make sure `https://<server_name>/.well-known/matrix/server` is reachable (default layout: DNS
   for the apex points here; `external`: publish the printed JSON).
2. Re-run with `MATRIX_FEDERATION=true`. Nothing listens on 8448; federation is delegated to 443.
3. Check with `https://federationtester.matrix.org/#<server_name>`.
4. Joining big public rooms costs RAM and disk; remote media is purged after 14 days.

## 8. Privacy notes

Push notifications go through Element's gateway at matrix.org and on to Apple/Google. Pushes carry
only event and room IDs, never message content (`push.include_content: false`). The metadata
(that someone received a message, and when) does leave the server. Synapse also needs outbound
HTTPS to `matrix.org` for this.

## 9. Backup and restore

```bash
sudo ./tasks/setup-backup-client.sh --services matrix ...     # or add matrix to BACKUP_SERVICES
```

Each backup run writes three files into the staging dir before `borg create`:

| File | Contents |
|---|---|
| `matrix-<ts>.dump` | `pg_dump -Fc` of the `synapse` database |
| `matrix-<ts>.mas.dump` | `pg_dump -Fc` of the `mas` database |
| `matrix-<ts>.identity.tar` | `.env`, the Synapse signing key, `synapse/secrets/`, `synapse/appservices/`, `secrets/` (MAS keys) |

The identity tar is essential: without the signing key and secrets, a restored server is not the
same server. Borg runs as a non-root user and cannot read those mode-600 files directly.
`/srv/matrix/synapse/media_store/local_content` (uploads) is covered by the normal `/srv` file
backup. Recommended excludes (the raw postgres datadir is replaced by the dumps; the rest are
caches):

```bash
BACKUP_EXCLUDE_REGEXES="re:^srv/matrix/db/ re:^srv/matrix/synapse/media_store/(remote_content|remote_thumbnail|url_cache)"
```

**Restore the databases** (same host):

```bash
sudo -u <backup-user> /usr/local/bin/borg-backup-<client> restore-db <snapshot> matrix --yes
```

This stops `matrix-synapse` and `matrix-mas`, then recreates both databases with C collation and
restores them. It empties `e2e_one_time_keys_json` (reused one-time keys break decryption) and
starts both services again.

**New host:** restore `/srv/matrix` files from the snapshot, extract
`var/backup-staging/dumps/matrix-<ts>.identity.tar` and unpack it with
`sudo tar -xpf matrix-<ts>.identity.tar -C /srv/matrix`, run `setup-matrix.sh` with the same
`MATRIX_SERVER_NAME`, then `restore-db` as above.

## 10. Upgrades

Images are pinned (`SYNAPSE_IMAGE`, `MAS_IMAGE`, `ELEMENT_IMAGE`, …). To upgrade:

1. Read Synapse's [upgrade notes](https://element-hq.github.io/synapse/latest/upgrade.html) for every
   version in between, and the MAS / Element release notes.
2. Back up (`borg-backup-<client> create`).
3. Re-run with the new tag, e.g. `SYNAPSE_IMAGE=matrixdotorg/synapse:v1.165.0 kwisatz apply matrix`
   (or bump the default in the script). Synapse migrates its database on start.
4. Check `GET /_synapse/admin/v1/background_updates/status` (from an allowed network) before the
   next jump.

PostgreSQL stays on the major in `db/PG_VERSION`. A major upgrade (17 → 18) is a manual
dump/restore, never automatic.

## 11. Files and secrets

```
/srv/matrix/
├── .env                 # 600 root — every generated secret, COMPOSE_PROFILES, MATRIX_SERVER_NAME
├── docker-compose.yml   # rendered, no secrets
├── db/                  # postgres data (backed up as dumps)
├── synapse/             # homeserver.yaml (no secrets), signing key (600), secrets/ (700), media_store/
├── mas/config.yaml      # no secrets
├── secrets/mas/         # 700 — MAS shared secret, encryption secret, signing keys
├── element/ wellknown/ livekit/ admin/
```

Secrets are generated once and never rotated. Synapse and MAS read them from mode-600 files that
the script writes from `.env` on every run; database passwords come from `PGPASSWORD` in the
container environment. One documented exception: `synapse/appservices/lk-jwt.yaml` (mode 600)
carries the lk-jwt appservice tokens inline. Synapse has no file indirection for them.

## 12. Troubleshooting

| Symptom | Check |
|---|---|
| Script warns "no certificate … route not verified" | DNS for the host points here? `sudo docker logs traefik \| grep -i acme` |
| Element X: "server not found" / no login | `curl -si https://<server_name>/.well-known/matrix/client` → 200, `access-control-allow-origin: *` |
| Login fails | `sudo docker logs matrix-mas`; `curl https://<matrix-domain>/_matrix/client/v1/auth_metadata` |
| Calls connect but no audio/video | 7881/tcp and 7882/udp reachable from outside? `LIVEKIT_NODE_IP` for VPN-only setups |
| Calls: "could not authorise" | `sudo docker logs matrix-lk-jwt` — it must reach `https://<server_name>/.well-known/matrix/server` |
| Logs | `sudo docker compose -f /srv/matrix/docker-compose.yml logs -f synapse mas` |
