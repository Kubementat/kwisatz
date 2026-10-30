# Adding devices to a headless Orca server

Research date: 2026-10-30. Installed here: Orca v1.4.220. Latest upstream: v1.4.245, released the same day.

## The problem

`orca serve` creates a pairing link only at startup. It has no command to create another link,
list clients, or revoke one.

| Problem | Where | Effect |
| --- | --- | --- |
| A process offers one link scope | `ORCA_MOBILE_PAIRING`, upstream #18783 | This server runs `--mobile-pairing`, so its link is mobile-scoped. Adding a laptop needs a restart without the flag |
| No way to create a link while running | upstream #16987, #11084 | The only supported route to a new link is a restart |
| No headless revocation | upstream #21744 | The only supported UI is the desktop app's Settings page |
| The link is only in the journal | `tasks/setup-orca.sh:389`, `:437` | It has to be dug out, and it is gone once the journal rotates |
| The journal stores a credential | `--json` ready line | The link is a long-lived bearer token, readable by anyone in `adm` or `systemd-journal` |

Related script bug: `ORCA_VERSION=latest` skips the download when a binary exists
(`tasks/setup-orca.sh:286`). `--force` replaces the binary, but the service restarts only if the
unit changed or the service is down (`:374`), so the old version keeps running.

## How pairing works

- A link is `orca://pair?code=<base64url JSON>` holding `v`, `endpoint`, `deviceToken`,
  `publicKeyB64`, `pairedDeviceId`, `scope` and, for runtime scope only, an optional `hostDescriptor`.
- Grants are rows in `~/.config/orca/orca-devices.json`. The public key is in `orca-e2ee-keypair.json`.
- Tokens are 24 random bytes in hex. Authentication is a lookup of that token in the registry.
- From v1.4.245, `DeviceRegistry.validateToken` re-reads the file when it changes on disk. Upstream
  has a test for this: `accepts a device another writer added, with no save in between`
  (`src/main/runtime/device-registry-external-edit-auth.test.ts`). Tags up to v1.4.240 do not have it.
- Real clients may later create a device-key row that points back through `forkedFrom`, and relayed
  phones hang off `parentDeviceId`. Revoking a device has to remove those rows too.

## Test results

Test setup: a disposable Ubuntu 24.04 container with its own profiles and a real `orca` CLI as the
client (`environment add`, then `repo list --environment`). The live server was not touched.

| Scenario | v1.4.220 | v1.4.245 |
| --- | --- | --- |
| Write a runtime row while the server is in `--mobile-pairing` mode, no restart, client call | refused | **works** |
| Same link with a wrong token | refused | refused |
| Write a mobile row, no restart | refused | **works** |
| Remove the row, no restart, paired client calls again | refused (it never authenticated) | **refused, revocation works** |
| Written row after a restart | works | works |
| Second client using the same link | not meaningful (the grant never authenticated) | works, but shares the row. Revoking one revokes both |

Not tested: a real phone, the desktop GUI app, a browser client, a link with no `hostDescriptor` in
the GUI app, upgrading a populated v1.4.220 profile, or two real clients each creating a `forkedFrom`
row. `environment add` succeeds even with a bad token, so it proves nothing by itself. Only the
follow-up call does.

## Options

| Option | No restart | Supported by upstream | Notes |
| --- | --- | --- | --- |
| **A. `orca-pair` helper that writes the registry** (recommended) | yes | no, but upstream tests external writers | Needs v1.4.245 or newer. Gives both scopes, named devices, list and revoke |
| B. Helper that restarts with different flags | no | yes | This is what the Railway template does. Drops connected clients for about 20 s. #18783 reports about 106 agent sessions needing manual recovery after a restart |
| C. Password-protected web pairing page | depends on A or B | no | Convenient, but it is a network-facing page that creates full-access credentials |
| D. Wait for `orca pairing create` | yes | yes, once merged | PRs #11180, #26245 and #27558 are all open, with no committed date |

## Recommendation: option A

Install `/usr/local/bin/orca-pair` from `templates/orca/orca-pair` (bash, jq), running as
`ORCA_SERVICE_USER`:

```text
orca-pair add laptop            # desktop link
orca-pair add phone --mobile    # phone link to paste into Orca Mobile
orca-pair list                  # names, scopes, paired or unused; never tokens
orca-pair rm laptop             # also removes forkedFrom and parentDeviceId rows
```

Design rules:

- Refuse to run below v1.4.245.
- Write atomically (temp file, then rename) with mode 600.
- Refuse a device name that already exists, so that each device has its own grant.
- Default the address to `ORCA_PAIRING_ADDRESS`, which stays the machine's LAN IP
  (`192.168.178.57`). Orca is used on the local network only. Remote devices reach that same
  address through the NetBird VPN, so the NetBird peer address is not advertised.

Changes to `tasks/setup-orca.sh`:

- Render and install the helper with `envsubst`, like the systemd unit.
- Restart the service when the binary changes.
- Print `orca-pair` usage in the summary.
- Update `--help` and `AUTOMATIONS.md`.

Left out to keep this minimal: QR codes, per-device address override, a config option, and
`--no-pairing`. The journal therefore keeps holding the startup link.

Risk: the registry format is internal, and #27558 proposes replacing bearer links with single-use
tickets. All of that knowledge stays inside one small helper, and once `orca pairing create` ships the
helper can call that instead with the same commands.

Acceptance check before release: on a VM per `tests/README.md`, pair a real phone and the desktop app
without restarting, then revoke one and confirm the other still works.

## Sources

- [Remote Orca Servers docs](https://www.onorca.dev/docs/remote-servers)
- [Orca CLI reference](https://www.onorca.dev/docs/cli/reference)
- [Railway Orca template](https://railway.com/deploy/orca-server) and [its source](https://github.com/two-workspaces/orca)
- Upstream issues: [#16987](https://github.com/stablyai/orca/issues/16987), [#11084](https://github.com/stablyai/orca/issues/11084), [#18783](https://github.com/stablyai/orca/issues/18783), [#21744](https://github.com/stablyai/orca/issues/21744), [#23438](https://github.com/stablyai/orca/issues/23438), [#17398](https://github.com/stablyai/orca/issues/17398), [#20768](https://github.com/stablyai/orca/issues/20768)
- Upstream PRs: [#11180](https://github.com/stablyai/orca/pull/11180), [#26245](https://github.com/stablyai/orca/pull/26245), [#27558](https://github.com/stablyai/orca/pull/27558), [#35527](https://github.com/stablyai/orca/pull/35527)
