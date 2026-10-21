# NetBird CLI reference

Reference for the `netbird` binary. Verified against client/daemon **0.77.1**
(`netbird version`). Commands, flags and output keys are stable within a major line
but do get added/renamed between releases — check `netbird <cmd> --help` on the box
before quoting anything exact to the user.

## How the binary is structured

One binary, two roles:

```
netbird ┬─ daemon (service)  ── owns the wt0 WireGuard interface, ICE, the peer state
        └─ CLI               ── talks to the daemon over unix:///var/run/netbird.sock
```

Consequences that bite people:

- Almost every command needs a **running daemon** — exceptions are `--help`, `version`
  and `service install|uninstall`. In a different container/namespace you cannot query
  it (`--daemon-addr` only changes the address, not the host).
- The daemon is not the same thing as being *connected*: `netbird service run` starts
  the daemon; `netbird up` logs in and brings the interface up.
- Inside a container with no init system `netbird service status` fails looking for
  `rc-service`/systemctl — start the daemon in the foreground instead.

```
netbird [command] [subcommand] [flags]
```

### Global flags

Available on every command (from `netbird --help`):

| Flag | Effect |
|---|---|
| `-m, --management-url` | Management service URL (default `https://api.netbird.io:443` — set this for self-hosted!) |
| `--admin-url` | Dashboard/admin panel URL (default `https://app.netbird.io:443`) |
| `-k, --setup-key` / `--setup-key-file` | Register this peer with a setup key |
| `-n, --hostname` | Peer hostname reported to management |
| `--preshared-key` | WireGuard PSK; only peers with the same key can talk |
| `-c, --config` | Override the profile file location (default `/var/lib/netbird/default.json`) |
| `--daemon-addr` | Where to reach the daemon (`unix|tcp|npipe://…`) |
| `-s, --service` | System service name (default `netbird`) |
| `-l, --log-level`, `--log-file` | Log level / destinations (`console`, `syslog`, paths) |
| `-A, --anonymize`, `--anonymize-level` | Redact public IPs/MACs/non-netbird domains in logs and status (`strict` also redacts private ranges, peer names and WG keys) |

### Flags ⇄ environment variables

Any flag can be passed as `NB_<FLAG>` (`--wireguard-port` → `NB_WIREGUARD_PORT`,
multi-word flags join with `_`). Precedence is deliberately **environment → flags →
profile file**, kept that way for backwards compatibility. Both `NB_SETUP_KEY` and
`NB_MANAGEMENT_URL` are read by the client; `NB_MGMT_URL` is **not** a variable and
silently leaves the client on the hosted endpoint.

See *Client environment variables* below for the tuning knobs that are not flags.

## Login and connection

### `netbird up`

Log in (if needed) and connect. Without a key on a fresh peer this starts an SSO
device flow. `--foreground-mode` (`-F`) runs the service in the foreground.

| Flag | Default / notes |
|---|---|
| `--setup-key`, `--setup-key-file`, `--management-url` | registration |
| `--no-browser`, `--qr`, `--profile` | SSO flow control |
| `--disable-auto-connect` | do not reconnect on service start |
| `--disable-dns`, `--disable-client-routes`, `--disable-server-routes` | ignore what management sends (the last one makes this peer stop routing) |
| `--block-inbound` | override *all* management policies: accept nothing inbound, including routed networks |
| `--block-lan-access` | refuse LAN access when acting as router/exit node |
| `--disable-firewall` | do not touch host firewall rules |
| `--disable-ipv6` | skip the IPv6 overlay |
| `--wireguard-port`, `--interface-name`, `--mtu` | `51820`, `wt0`, `1280` |
| `--external-ip-map` | `1.2.3.4,5.6.7.8/eth1` — announce correct public IPs behind NAT/multi-homing |
| `--dns-resolver-address`, `--dns-router-interval`, `--extra-dns-labels` | local DNS resolver wiring |
| `--allow-server-ssh`, `--enable-ssh-*`, `--disable-ssh-auth`, `--ssh-jwt-cache-ttl` | SSH server on this peer |
| `--enable-rosenpass`, `--rosenpass-permissive` | post-quantum key exchange (experimental) |
| `--network-monitor`, `--extra-iface-blacklist` | interface watching / ignore list |

```bash
sudo netbird up --management-url https://nb.example.com --setup-key "$KEY" --hostname homelab-gw
sudo netbird up -F --log-file console            # debug a container
sudo netbird up --disable-dns --disable-server-routes   # join as a plain client only
```

### `netbird login`

Authentication only (no interface change). `--setup-key` / `--setup-key-file`,
`--profile`, `--no-browser`, `--qr`, and `--extend` — refresh the SSO session expiry
without tearing the tunnel down, use it before a long session expires.

### `netbird down` / `netbird deregister`

`down` disconnects and leaves the registration intact. `deregister` (alias `logout`)
removes the peer from the management account **and** the local config — irreversible,
the peer needs a key or SSO again.

## `netbird status`

```bash
netbird status                      # human summary
netbird status -d, --detail         # per-peer detail + events
netbird status -j, --json           # full JSON
netbird status -y, --yaml
netbird status -4 | -6              # just the overlay IP
```

Detail filters: `--filter-by-status idle|connecting|connected`, `--filter-by-ips`,
`--filter-by-names`, `--filter-by-connection-type P2P|Relayed`.

Human output lines worth reading (`Management`, `Signal`, `Relays`, `NetBird IP`,
`Peers count`, `Networks`) are explained in `../SKILL.md` §4.

Health probes: `--check live|ready|startup` print nothing and exit `0`/`1`.
`live` = daemon answers; `ready` = `Idle|Connecting|Connected`; `startup` = management +
signal connected and at least one relay available when relays exist.

JSON keys (0.77.1): `cliVersion, daemonVersion, daemonStatus, management{url,connected,error},
signal{…}, relays{total,available,details[{uri,available,error,transport}]}, netbirdIp,
netbirdIpv6, publicKey, usesKernelInterface, wireguardPort, fqdn, quantumResistance,
quantumResistancePermissive, networks[], forwardingRules, dnsServers[], events[],
lazyConnectionEnabled, profileName, sshServer, peers{}`.

```bash
netbird status --json | jq -r '.daemonStatus, .management.connected, .signal.connected'
netbird status -d --filter-by-connection-type Relayed   # who is going through a relay
```

## `netbird networks` (alias `routes`)

Client-side view of the Networks this peer can consume.

```bash
netbird networks list                 # or `netbird routes ls`
netbird networks select all           # accept all current + future networks
netbird networks select net-1 net-2   # replace selection
netbird networks select -a net-3      # append
netbird networks deselect all
```

An empty/`No networks available.` answer is normal on a peer that *is* the router of
those networks, and normal when the control plane has assigned no router yet. The
routed prefixes this peer advertises appear in `netbird status` → `Networks:`.

## `netbird forwarding list`

The forwarding rules currently installed from the control plane
(`No forwarding rules available.` when there are none).

## `netbird profile`

Multiple accounts in one client.

```bash
netbird profile list [--show-id]
netbird profile add staging
netbird profile select staging       # by name, ID, or unique ID prefix
netbird profile rename old new
netbird profile remove staging
```

Profiles live as `/var/lib/netbird/<profile>.json` (`default.json` out of the box);
`-c/--config` points the CLI at a specific file.

## `netbird service`

Daemon lifecycle. Run elevated on a host.

```bash
sudo netbird service install | uninstall | start | stop | restart | status
sudo netbird service run             # foreground daemon (what containers use)
sudo netbird service reconfigure     # apply new settings without reinstalling
sudo netbird service reset-params    # drop the saved service.json, back to defaults
```

Install/reconfigure flags (persist in `service.json`, meant for managed machines):
`--disable-networks`, `--disable-profiles`, `--disable-update-settings`,
`--enable-capture`, `--enable-json-socket`, `--json-socket <addr>`,
`--service-env KEY=VALUE[,…]`. The disable flags also read `NB_DISABLE_PROFILES` /
`NB_DISABLE_UPDATE_SETTINGS`.

## `netbird state`

The daemon's persisted subsystem state (`ssh_config_state`, `dns_state`,
`nftables_state`, …). **The daemon must be stopped** — these commands are recovery
tools, not diagnostics.

```bash
netbird state list
netbird state clean dns_state        # cleanup + remove
netbird state clean --all
netbird state delete --all           # remove without cleanup (stuck state)
```

## `netbird debug`

| Subcommand | Use |
|---|---|
| `bundle` | zip of logs + system info → `/tmp/netbird.debug.<n>.zip`; `--log-file-count N`, `--system-info`, `--upload-bundle[-url]` |
| `for <dur>` | trace-level logging for the duration, then a bundle (`--capture` too) |
| `log level <lvl>` | session-only level: `panic fatal error warn info debug trace` |
| `config` | effective configuration as JSON (defaults + profile file + env + CLI flags + MDM policy) |
| `capture [bpf-filter]` | decrypted packets on `wt0`; text or `--pcap`/`-o file.pcap`; needs `--enable-capture` |
| `trace in\|out <src> <dst>` | walk a packet through the packet filter (`self` = local peer) |
| `persistence on\|off` | keep the last sync response in memory |

`debug trace` answers `firewall manager does not support packet tracing` when the
kernel nftables/iptables backend is active (the normal Linux case) — inspect the
installed rules instead, and reserve `trace` for macOS/Windows/netstack.

```bash
sudo netbird debug bundle
sudo netbird debug for 5m            # reproducible capture around a flaky link
sudo netbird debug capture host 100.64.0.7 and port 443 -d 30
nft list ruleset                     # what the client actually installed
```

## `netbird ssh`, `expose`, `kubernetes`

- `netbird ssh [user@]peer [command]` — SSH over the mesh with SSO/JWT auth. Needs SSH
  enabled on the target peer and in the dashboard, plus a policy allowing TCP **22022**.
  `-L`/`-R` port forwarding works when enabled on the server side. SFTP/SCP work with
  native clients. Flags: `-u/--user`, `-p/--port`, `-i/--identity`, `--known-hosts`,
  `--strict-host-key-checking` (default true), `--no-cache` (force fresh JWT).
- `netbird expose <port>` — publish a local port through the NetBird reverse proxy for
  as long as the command runs. `--protocol http|https|tcp|udp|tls`,
  `--with-pin`, `--with-password`, `--with-user-groups`, `--with-external-port`,
  `--with-name-prefix`, `--with-custom-domain`. Requires the Peer Expose feature to be
  enabled by an administrator; up to 10 sessions per peer, renewed every 30 s.
- `netbird kubernetes list` / `write-kubeconfig` — clusters registered in the account.

## `netbird version`, `completion`, `help`

`netbird version` prints just the version (`netbird --version` errors).
`netbird completion bash|zsh|fish|powershell` emits the completion script.
`netbird help <command>` / `<command> --help` for live flag lists.

## Client environment variables (selected)

Set these on the **daemon** process (`service install --service-env …` to persist, or
in the container/`systemd` unit environment), not on the CLI:

| Variable | Why you reach for it |
|---|---|
| `NB_STATE_DIR` | state/profile dir (default `/var/lib/netbird`) |
| `NB_MANAGEMENT_URL`, `NB_SETUP_KEY` | unattended enrollment |
| `NB_LOG_LEVEL`, `NB_LOG_FORMAT`, `NB_LOG_MAX_SIZE_MB`, `NB_LOG_DISABLE_ROTATION` | logging |
| `NB_FWMARK_BASE` | fwmark range collides with another VPN/CNI |
| `NB_USE_NETSTACK_MODE`, `NB_NETSTACK_SKIP_PROXY`, `NB_SOCKS5_LISTENER_*` | no TUN available (unprivileged containers) |
| `NB_WG_KERNEL_DISABLED` | fall back to wireguard-go userspace |
| `NB_ENABLE_LOCAL_FORWARDING` | reach services bound to this peer's own addresses (userspace routers) |
| `NB_FORCE_RELAY` | never attempt P2P; everything via relay |
| `NB_USE_LEGACY_ROUTING` | pre-0.26 routing when exit nodes break rp_filter setups |
| `NB_DNS_FORWARDER_PORT` | routed-domain resolver port (22054, 5353 on old peers) |
| `NB_ICE_*_SEC`, `NB_LAZY_CONN`, `NB_LAZY_CONN_INACTIVITY_THRESHOLD` | connectivity/laziness tuning |
| `NB_DISABLE_SSH_CONFIG` | stop writing `ssh_config.d/99-netbird.conf` |
| `NB_CONN_RETRY_*` | reconnect backoff against management/signal |
| `NB_PPROF_ADDR`, `NB_METRICS_PUSH_ENABLED` | profiling / telemetry |

Full list: <https://docs.netbird.io/client/environment-variables>.
