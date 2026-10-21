---
name: netbird
description: Set up and use NetBird, the WireGuard mesh VPN — join a network as a peer, self-host the management/signal/relay stack, expose a LAN through a routing peer, and drive the `netbird` CLI (status, networks, profiles, service, debug, deregister) plus the management REST API. Use when the user mentions NetBird or the netbird CLI, mesh/overlay VPN, 100.64/100.75 overlay addresses, the wt0 interface, setup keys, routing peers / "reach my LAN from the mesh", "peer shows Connected but I cannot reach X", or asks to configure, diagnose, upgrade or back up a NetBird deployment.
---

# NetBird

NetBird is a WireGuard-based mesh VPN. Every peer gets an overlay address from the
NetBird route range (default `100.64.0.0/10`; a peer prints e.g. `100.75.4.20/16`),
peers connect directly (ICE/STUN) and fall back to relay servers when NAT blocks them.
A deployment has two planes:

- **Control plane** — Management (gRPC + REST API), Signal (connection coordination),
  Relay, STUN, and an identity provider (embedded Dex in the combined server image).
  This is the only place where users, peers, setup keys, networks and policies live.
- **Data plane** — the `netbird` binary, which is both the daemon (`wt0` interface)
  and the CLI that talks to that daemon over `unix:///var/run/netbird.sock`.

Everything below is version-agnostic except where a version is named explicitly.
Verified against client/daemon **0.77.1**; upstream **v0.81.3** (2026-10-19) is the
latest release — check <https://github.com/netbirdio/netbird/releases> before quoting
flags to the user, since flag names and the API schema do move.

## 1. Find out what you are looking at first

```bash
netbird version                 # client binary (no --version flag exists)
netbird status                  # daemon status: management / signal / relays / IPs
netbird status --detail         # per-peer connection type, latency, handshake
netbird status --json | jq .    # machine-readable
netbird profile list            # which account/profile this daemon is on
```

If `netbird` is missing on the host, the peer may run in a container
(`docker ps | grep netbird`), and the CLI has to run inside it:

```bash
docker exec <client-container> netbird status
```

The CLI only ever talks to a **running daemon in its own namespace** — it has no
"connect to this peer and ask" mode. If the daemon is not installed, none of the
status/network/profile commands work; only `--help` does.

Then pick the branch you need:

| You want to | Go to |
|---|---|
| add a Linux box to an existing network | §2 Install + §3 Join |
| check a peer that "is not working" | §4 Health + §7 Troubleshooting |
| let peers on the mesh reach devices that do not run NetBird | §5 Routing peer |
| stand up a new self-hosted server | §6 Server setup |
| automate keys/networks/policies | `references/control-plane.md` |

## 2. Install the client (Debian/Ubuntu)

```bash
sudo apt-get update
sudo apt-get install ca-certificates curl gnupg -y
curl -sSL https://pkgs.netbird.io/debian/public.key | sudo gpg --dearmor --output /usr/share/keyrings/netbird-archive-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main' | sudo tee /etc/apt/sources.list.d/netbird.list
sudo apt-get update
sudo apt-get install netbird        # CLI + daemon; netbird-ui for the desktop app
```

One-liner equivalent: `curl -fsSL https://pkgs.netbird.io/install.sh | sh`.
Other platforms (RPM/yum/dnf, Alpine, Arch/AUR, NixOS, Homebrew, binary tarball) are
on <https://docs.netbird.io/get-started/install/linux>. The desktop app needs GTK ≥ 4.10
and WebKitGTK 6.0 (Ubuntu 24.04+, Debian 13+, Fedora 43+); on older releases install the
CLI only. `netbird-ui` binaries are x86_64 only.

Container form (headless, no package manager):

```bash
docker run -d --name netbird --hostname my-peer \
  --network host --cap-add NET_ADMIN --cap-add SYS_ADMIN --cap-add SYS_RESOURCE \
  --device /dev/net/tun --restart unless-stopped \
  -e NB_MANAGEMENT_URL=https://netbird.example.com \
  -e NB_SETUP_KEY=YOUR_SETUP_KEY \
  -v netbird-state:/var/lib/netbird \
  netbirdio/netbird:latest
```

The image's entrypoint runs `netbird service run`, waits for the daemon, then runs a
bare `netbird up`; `NB_SETUP_KEY` is read from the environment by the client itself, so
no flags are needed. Set `NB_MANAGEMENT_URL` (not `NB_MGMT_URL`) — with the wrong name
the client silently uses the hosted `https://api.netbird.io:443` instead of your
server. The stock entrypoint ignores arguments you pass as the container command, so to
drive startup yourself replace it: `--entrypoint /bin/bash … -c 'netbird service run &
sleep 5; netbird up'`.

Enable the daemon to start at boot on a package install:

```bash
sudo netbird service install && sudo netbird service start
```

## 3. Join a network

```bash
# self-hosted server, unattended
sudo netbird up --management-url https://netbird.example.com --setup-key <uuid>

# NetBird Cloud, or a server where you log in with SSO
sudo netbird up                        # opens a browser
sudo netbird up --no-browser           # headless: read the URL yourself
sudo netbird login --qr                # QR code for a machine without a browser
```

Every `--flag` also exists as `NB_<FLAG>` (`--setup-key` → `NB_SETUP_KEY`,
`--wireguard-port` → `NB_WIREGUARD_PORT`); environment beats flags beats the profile
file `<profile>.json`. A setup key is a UUID — a malformed value fails with
`invalid setup-key ... invalid UUID length`, an unknown one with `setup key is invalid`.
If the key is empty or absent, `up` starts the interactive SSO **device flow** and
eventually dies with `context deadline exceeded` — that is the single most common
reason a "server" peer never appears in the dashboard.

Day-2 operations:

```bash
sudo netbird down                 # disconnect, keep the registration
sudo netbird up                   # reconnect (auto-connect does this too)
sudo netbird login --extend       # refresh the SSO session without tearing the tunnel down
sudo netbird deregister           # remove this peer from the account + local config
sudo netbird service restart
sudo netbird status -j | jq '.daemonStatus'
```

Overlay IP of this peer (scripting-friendly): `netbird status --ipv4` / `--ipv6`.

## 4. Health: what "connected" actually means

`netbird status` prints one line per channel. They fail differently, so read them in
order — **`Management: Connected` alone is not a working peer**:

| Line | Healthy | If broken |
|---|---|---|
| `Management:` | `Connected` | registration/expiry problem → `NeedsLogin`, `LoginFailed`, `SessionExpired` |
| `Signal:` | `Connected` | `Disconnected` with `missing port in address` = the server's `exposedAddress` has no `:443`; peers stay logged in but connect to nothing |
| `Relays:` | `n/n Available` | `0/0` = no relay/STUN configured or reachable |
| `NetBird IP:` | `100.x.y.z/16` | empty = interface not up |
| `Peers count:` | `m/n Connected` | `0/n` = the other side is offline or a policy denies you |
| `Networks:` | lists routed subnets | empty = no router assigned (see §5) |

Health probes for scripts and orchestrators (exit `0` = ok, no output):

```bash
netbird status --check live      # daemon answers the status request at all
netbird status --check ready     # Idle | Connecting | Connected (auth-required states fail)
netbird status --check startup   # management + signal connected, and ≥1 relay if any exist
```

Peer-level checks: `netbird debug bundle` (writes `/tmp/netbird.debug.<n>.zip`),
`netbird debug log level debug` (session-only verbosity), `netbird debug capture`
(needs `netbird service install --enable-capture`), and `netbird debug trace` — the
last one reports `firewall manager does not support packet tracing` on Linux with the
kernel nftables/iptables backend, where `nft list ruleset` / `iptables -S` are the
real answer. The client's own log is `/var/log/netbird/client.log`
(`NB_STATE_DIR` defaults to `/var/lib/netbird`).

## 5. Reach a LAN through a routing peer

A routing peer is a peer that forwards between the overlay and networks whose hosts do
not run the client. Four independent conditions, each with its own failure mode:

1. **The host forwards.** The Linux client enables `ip_forward` itself; persist it anyway:
   `sysctl -w net.ipv4.ip_forward=1` plus `/etc/sysctl.d/99-netbird.conf`. Container
   peers need `NET_ADMIN` (+ `SYS_RESOURCE`, `SYS_ADMIN` for the tunnel/firewall) and
   `/dev/net/tun`; run them with host networking so the peer itself gets an overlay address.
2. **The peer is enrolled** via a *reusable* setup key, auto-assigned to a group.
3. **A Network exists with a Router assigned** (control-plane object — this is the step
   a setup script cannot do). Networks replace the deprecated Routes everywhere except
   exit nodes; Resources inside a Network are IP / range / domain typed. The Router row
   carries `masquerade` (on by default: traffic is SNAT'ed to the routing peer's LAN
   address, so the LAN needs no return route) and `metric` (lowest wins; peers pick by
   metric → connection type → latency).
4. **A policy allows it.** Policies whose destination is a Network resource are
   always unidirectional; a routed destination needs a *network resource* policy
   (forward chain), while reaching the routing peer's own services needs a
   *peer-to-peer* policy (input chain). One of each, if you need both.

Assigning the router (API or dashboard; see `references/control-plane.md`):

```bash
curl -s -H "Authorization: Token $NB_TOKEN" https://netbird.example.com/api/networks | jq '.[] | {id,name,resources,routers}'
```

Client side, the selection commands run on the *consumer* peer, not the router:

```bash
netbird networks list           # networks this peer can use (+ alias `netbird routes ls`)
netbird networks select all     # accept every current and future network
netbird networks select <id>    # or just one; -a appends
netbird networks deselect all   # accept none
```

`netbird networks list` prints `No networks available.` on a peer that *is* the router —
that is not a failure, its routed networks show up in `netbird status` under
`Networks:`. Confirm what it forwards with `netbird forwarding list`.

Verification order, cheapest first:

```bash
curl -fsSk https://netbird.example.com/oauth2/.well-known/openid-configuration | head -c 200  # public reachability
netbird status                                                   # peer's own view (see §4)
netbird networks list                                            # on the consumer peer
ip route                                                         # on the routing peer host
ping <lan-host> && ping <lan-gateway>                             # from a peer: the 2nd proves forwarding
curl -v <lan-host>:<port>
```

`ping <routing peer host>` working while nothing else on the subnet answers = router /
masquerade missing. Nothing answers at all = policy, or the peer is not in the policy's
source group. Note that ICMP needs its own policy — "the service is up but ping fails"
is a policy gap, not a routing failure.

## 6. Self-hosted server

Requirements: a public domain resolving to the box, TCP 80/443 and UDP 3478
(STUN) reachable, 1 CPU / 2 GB, Docker + Compose v2, and Let's Encrypt. gRPC needs
HTTP/2, so a reverse proxy must proxy h2c/gRPC. Clients need no inbound ports.

Fastest path (combined `netbird-server` image: management + signal + relay + STUN +
embedded Dex IdP, plus the dashboard):

```bash
export NETBIRD_DOMAIN=netbird.example.com \
       NETBIRD_LETSENCRYPT_EMAIL=you@example.com \
       NETBIRD_NON_INTERACTIVE=true
curl -fsSL https://raw.githubusercontent.com/netbirdio/netbird/main/infrastructure_files/getting-started.sh | bash
```

The variables must be set for **bash**, not for `curl` — prefixing them before `curl`
in the same pipeline makes the install stop with `NETBIRD_DOMAIN is required for a
non-interactive install.`

Env-var answers (`NETBIRD_DOMAIN`, `NETBIRD_REVERSE_PROXY_TYPE`, `NETBIRD_ENABLE_PROXY`,
`NETBIRD_TRAEFIK_EXTERNAL_NETWORK`, `NETBIRD_TRAEFIK_ENTRYPOINT`,
`NETBIRD_TRAEFIK_CERTRESOLVER`, `NETBIRD_NON_INTERACTIVE`, …) need NetBird ≥ 0.77.1, and
`NETBIRD_TRUSTED_PEERS` needs ≥ 0.79.0; with your own reverse proxy, set
`NETBIRD_TRUSTED_PEERS` or management trusts `X-Forwarded-For` from anyone. A
re-run refuses to touch an existing install — run it in a fresh directory. Create the
first owner in the browser at `https://<domain>/setup` (only live while no user exists),
or headlessly with the setup API + `NB_SETUP_PAT_ENABLED=true`
(`references/control-plane.md` → *Bootstrap without a browser*).

In this repo the same stack is deployed by `tasks/setup-netbird.sh` (driven from
`machine-config.yml`, or run directly), which reuses an existing Traefik and publishes
STUN on the host; its own walkthrough is `README_NETBIRD.md` and its audit trail is in
`docs/research/netbird-*.md`.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `netbird: command not found` then the daemon is fine | wrong package (`netbird-ui` vs `netbird`) or the CLI was run where no daemon runs |
| `Management: Connected`, `Signal: Disconnected`, `Relays: 0/0`; client log has `missing port in address` | server `config.yaml` `exposedAddress` without `:443` — peers derive the signal/relay endpoint from it, so *every* peer is affected |
| `PermissionDenied ... no peer auth method provided` | no setup key and no SSO on a new peer |
| `invalid setup-key` / `invalid UUID length` | wrong, expired, used-up or malformed key; use a **reusable** key |
| `login failed: ... context deadline exceeded`, IdP log fills with `/oauth2/device?user_code=…` | keyless `netbird up` running the SSO device flow → pass the key (flag or `NB_SETUP_KEY`) |
| `SessionExpired` after months | login expiry; `netbird login --extend` before it dies, or re-run `up` with the key |
| Peer visible in the dashboard with `connected=0` forever | no relay/signal path (row 1), or the peer's UDP is blocked |
| Everything green, resource still unreachable | no Router assigned, policy disabled, or the peer is in no group |
| Works on the LAN, fails from mobile data | 443 forward missing/redirected, or UDP blocked so everything must relay |
| Routing peer answers but its subnet does not | router assigned without masquerade + one-directional policy, or `ip_forward` reverted on reboot |
| Unreachable after a reboot only | `net.ipv4.ip_forward` not persisted, or auto-connect disabled (`--disable-auto-connect`) |
| Traffic silently dropped with other VPNs/CNIs present | fwmark collision; move the range with `NB_FWMARK_BASE` |
| No TUN device (unprivileged container) | run in netstack mode with `NB_USE_NETSTACK_MODE=true` |
| "peer is connected but `ssh peer-name` fails" | SSH must be enabled on the peer and in the dashboard, plus a policy for TCP 22022 |

## 8. Upgrades, backup, security

- **Upgrade** by bumping the image tags (management/server, dashboard, client) and
  recreating the containers. Upgrade management and the peers within one maintenance
  window, and read the release notes for breaking changes — a client far ahead of an
  older management, or a bundled reverse proxy newer than management, is where upgrades
  break. On package-managed peers the distro update does it for you.
- **Backup** the management data directory (`store.db`, IdP store, encryption key) plus
  the server config and `.env`. The store encryption key protects setup keys and tokens;
  without it they cannot be read back. Networks, routers and policies exist **only** in
  that database.
- **Security**: a setup key is a bearer credential that mints peers — treat it like a
  password, keep it out of committed config files and shell history, make it expire, and
  revoke it when unused. Give a routing peer the smallest `Networks` it needs, keep
  management metrics/health ports off public interfaces, and prefer Networks over
  Routes (a Route without ACL groups grants blanket access).

## References

- `references/cli.md` — every `netbird` command and flag, verified against a 0.77.1
  binary, including the daemon/service split, env-var mapping and debugging tools.
- `references/control-plane.md` — setup keys, Networks/resources/routers, policies,
  and the management REST API (auth, endpoints, schema shapes, headless bootstrap).
- `README_NETBIRD.md`, `tasks/setup-netbird.sh`, `docs/research/netbird-research.md`,
  `docs/research/netbird-setup-review-2026-10-03.md` — this repo's deployment, its
  variables, and its audit notes.
- Upstream: <https://docs.netbird.io/> (self-hosted quickstart, external reverse proxy,
  networks & routing peers, CLI, API).
