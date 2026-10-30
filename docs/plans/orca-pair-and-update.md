# Feature Plan: `orca-pair` and working updates in `setup-orca.sh`

Research: [`docs/research/orca-device-pairing.md`](../research/orca-device-pairing.md).

## Goal

1. Add or revoke an Orca client on the headless server without restarting it.
2. Re-running `tasks/setup-orca.sh` actually updates Orca, and the running service ends up on the
   new version.

Keep it minimal: one small bash helper, no new dependencies, no new config options.

## Decisions (agreed)

- Links advertise the machine's LAN IP through the existing `ORCA_PAIRING_ADDRESS`. NetBird already
  routes remote devices into the LAN, so no NetBird address and no per-device address override.
- No `qrencode`, no QR codes. Links are pasted into the client.
- `--no-pairing` is not added, so the journal keeps the startup link.

## Update bugs in `tasks/setup-orca.sh` today

| Bug | Where | Effect |
| --- | --- | --- |
| `latest` skips the download whenever a binary exists | `:286` | `latest` never updates anything |
| The service restarts only if the unit changed or it is down | `:374` | A new binary stays unused while the old process keeps running |
| The tag is read from a redirect that only `/latest/download/` URLs carry | `:270`, `:314` | Confirmed with curl: a pinned URL yields an empty tag, so `VERSION` says `unknown`, and every later run downloads and installs again |

## Changes

### `tasks/setup-orca.sh`

**Step 3, version resolution.** Work out one `TARGET_TAG` before deciding anything:

- Pinned: `TARGET_TAG="${ORCA_VERSION}"`.
- `latest`: `TARGET_TAG="$(resolve_tag_from_url ".../releases/latest/download/${ORCA_ASSET}")"`.
- `latest` with no resolvable tag (for example, GitHub unreachable):
  - binary installed: `warn` and keep the installed version, exit path stays successful;
  - no binary: `error`.

**Step 3, download decision.** Skip when not `--force`, the binary exists, and
`INSTALLED_VERSION == TARGET_TAG`. Otherwise download from
`.../releases/download/${TARGET_TAG}/${ORCA_ASSET}` and write `TARGET_TAG` to `VERSION`. This removes
the `DEPLOYED_TAG` lookup and the second `/latest/download/` URL. Log `installed -> target` when
upgrading. `--force` with an unresolvable `latest` is an `error`, since there is nothing to download.

**Step 5, restart decision.** Also restart when the binary is newer than the running service:

```bash
SERVICE_STARTED="$(date -d "$(sudo systemctl show -p ActiveEnterTimestamp --value "${SERVICE_NAME}.service")" +%s 2>/dev/null || echo 0)"
if [[ "${UNIT_CHANGED}" == "true" || "${SERVICE_STATE}" != "active" ]] \
  || (( $(stat -c %Y "${ORCA_APPIMAGE}") > SERVICE_STARTED )); then
```

Compare timestamps instead of tracking a "downloaded" flag. That also repairs an earlier run that
replaced the binary and never restarted, such as `--force` with the old script. Keep the existing
"left untouched" branch.

**Step 6, failure hint.** When readiness fails, add one `warn` line naming the way back:
`ORCA_VERSION=<previous tag> ./setup-orca.sh`. Include the previous tag when one is known.

**New step, install the helper.** Render `templates/orca/orca-pair` with `envsubst` limited to
`${ORCA_PORT} ${ORCA_PAIRING_ADDRESS} ${ORCA_VERSION_FILE}` and install it to
`/usr/local/bin/orca-pair`, mode 755, owner root, the same way as the unit (mktemp as the invoking
user, then `sudo install`). It holds no secrets. Do this on every run so the address and port stay
current. Export `ORCA_VERSION_FILE` and `ORCA_PAIRING_ADDRESS`.

**Summary.** Print `orca-pair` usage next to the pairing URL. When `ORCA_SERVICE_USER` differs from
the invoking user, show the `sudo -Hu <user>` form, as the existing `account add` lines do.

**Docs in the script.** Update the header comment and `show_help`:

- `ORCA_VERSION=latest` now updates to the newest release on every run, and restarts the service
  when it does. Pin a tag to stay put.
- `--force` re-downloads and reinstalls the target version.
- The helper's existence and usage.

Keep edits to the config block and `show_help` small. The branch
`feature/central-version-management` changes those lines too, and it should merge cleanly.

### `templates/orca/orca-pair` (new)

Start from `/tmp/claude-1000/-home-samba-shared-dev-kwisatz/f9770bc9-da36-465d-8093-f1ef495306ca/scratchpad/min/orca-pair`,
which was already exercised against a fake registry. Add only:

- A clear error when `$reg` does not exist, because it usually means the wrong user. Name the fix:
  run it as the service user.
- A refusal in `add` when `ORCA_PAIRING_ADDRESS` is empty or contains `://`, since `ws://<addr>:<port>`
  would be wrong. Say to set a plain LAN IP or hostname. Check at runtime, in `add` only, so `list`
  and `rm` keep working.

Behaviour to keep: version gate at v1.4.245; one grant per name; atomic write; `rm` also removes rows
whose `forkedFrom` or `parentDeviceId` points at the removed device; `list` never prints tokens.

### Docs

- `AUTOMATIONS.md`: update the `setup-orca.sh` entry. "Re-runs skip the download" is no longer true.
  Add `orca-pair` and how updates behave.
- `machine-config.yml.example`: one comment line saying `latest` updates and restarts on each apply,
  and that a tag pins it.

Do not change `src/kwisatz`, the systemd unit template, or `docs/plans/setup-orca.md`.

## Behaviour change to flag

With `ORCA_VERSION: latest`, `kwisatz apply` now upgrades Orca and restarts the service whenever a new
release exists. Upstream releases often, and connected clients drop during the restart. That is what
"latest" should mean, and a pinned tag is the way to avoid it.

## Verification

Nothing may touch the live `orca-serve.service`, `/opt/orca` or `~/.config/orca` on this machine, and
`tasks/setup-orca.sh` must not be run on this host.

1. Lint: `shellcheck tasks/setup-orca.sh templates/orca/orca-pair`, `yamllint machine-config.yml.example`,
   `tests/lint.sh`, `uv run pytest`.
2. Helper against a fake registry in a temp dir: add (runtime and `--mobile`), offer decodes to the
   right endpoint and scope, duplicate name refused, `rm` removes forked and child rows, `rm` of an
   unknown name fails, old version refused, missing registry and bad address give the clear errors,
   file mode stays 600.
3. In a disposable Docker container (`ubuntu:24.04`, no published ports, no mounts of the live profile),
   run the real helper and a real `orca` CLI client against a real v1.4.245 server: pair with no restart,
   then `rm` and confirm the next call is refused. `environment add` succeeds even with a bad token, so
   judge by a follow-up `repo list --environment <name> --json`.
4. Update logic: exercise the three bugs without systemd if needed, using stubs for `curl`, `sudo` and
   `systemctl`, or via `tests/run-vm-tests.sh --scripts setup-orca` if a VM is available. Cases: pinned
   version records the real tag and a second run does not download; `latest` with an older install
   downloads and restarts; `latest` with the current version does nothing; `latest` with GitHub
   unreachable keeps the install; binary newer than service start restarts.

## Acceptance check for the user (not automatable here)

On this server, after merge: run `./tasks/setup-orca.sh`, then confirm:

- `/opt/orca/VERSION` shows the new tag and `orca-serve` is active.
- The 3 existing clients still connect.
- `orca-pair add laptop` pairs the desktop app and `orca-pair add phone --mobile` pairs a real phone,
  both with no restart.
- `orca-pair rm` on one disconnects it and leaves the other working.
