# NetBird — making a local network reachable from the outside

This document is the full flow: from `tasks/setup-netbird.sh` to "my phone reaches
`192.168.178.0/24` while I'm on mobile data". It covers the parts the script
automates, the parts that live in the management database (and therefore in the
dashboard), and the checks that tell you which of the two you got wrong.

Deep background and the audit of the implementation:
[docs/research/netbird-setup-review-2026-10-03.md](docs/research/netbird-setup-review-2026-10-03.md).
For the script's own variables run `./tasks/setup-netbird.sh --help`.

---

## 1. The mental model

```
      phone on mobile data                    your home LAN
  ┌──────────────────────┐              ┌──────────────────────────┐
  │  NetBird mobile app  │              │ 192.168.178.57  :6768 …  │
  │  overlay 100.75.x.x  │              │ 192.168.178.1   router   │
  └───────────┬──────────┘              └────────────▲─────────────┘
              │ WireGuard (dst 192.168.178.0/24)     │ forwarded
              ▼                                      │
      ┌──────────────────────────────────────────────┴───┐
      │ netbird-client container  ← the ROUTING PEER      │
      │ (host network, /dev/net/tun, ip_forward=1)        │
      │ overlay 100.75.x.x                                │
      └───────────────────────▲──────────────────────────┘
                              │ enrolled through this URL
      https://netbird.example.com  ← Traefik (443/tcp) : management, signal,
                                     relay, dashboard, IdP
      udp/3478 (published directly)                       ← STUN for P2P
```

Four things must be true, and each one fails differently:

1. **The mesh must exist** — management, signal, relay and IdP on one public HTTPS
   origin. Handled entirely by `setup-netbird.sh`.
2. **Both peers must be *connected*, not just enrolled.** A peer can be registered,
   have an overlay IP and `Management: Connected` and still route nothing, because
   the **signal** channel never came up. §8 shows the check.
3. **Something must own the route.** The LAN subnet is a *control-plane* object: a
   Network (or Route) plus a peer assigned as its **Router**. The script cannot
   create it; §5 steps 3 and 6 are manual by design.
4. **The policy must allow it.** Onboarding usually creates "Users to … subnet";
   if it is disabled, or your phone's peer is not in the source group, the packets
   are simply dropped.

---

## 2. Prerequisites

| Requirement | Notes |
|---|---|
| Public DNS name | `NETBIRD_DOMAIN` must resolve to your router's public IP. Use dynamic DNS if the IP changes. |
| Router port-forward **443/tcp** | Traefik. Needed for login, signal, relay, API and dashboard. Not automatable from here. |
| Router port-forward **3478/udp** (optional) | STUN. Without it everything still works, but more sessions fall back to the relay. |
| No other inbound ports | Clients need nothing inbound. No UDP range. |
| Let's Encrypt | Via `setup-traefik.sh` (`ACME_EMAIL`, or `DNS_PROVIDER=cloudflare` for the DNS challenge). |
| Carrier-grade NAT | If your ISP gives you no public IPv4, port forwarding cannot make the server reachable — this topology does not work, no matter how it is configured. |
| IPv4 forwarding on the routing-peer host | `net.ipv4.ip_forward=1`, written to `/etc/sysctl.d/99-netbird.conf` by the script so it survives a reboot. |

---

## 3. Automating it with the orchestrator

The script is idempotent and converges, but keep secrets out of `machine-config.yml`:

```yaml
  setup-netbird:
    enabled: true
    description: Self-hosted NetBird server + dashboard (LAN exposed later)
    env:
      NETBIRD_DOMAIN: netbird.example.com
      NETBIRD_HOME: /srv/netbird
    args: []
```

```bash
./kwisatz status        # preview
./kwisatz apply
```

For the routing peer, run the task directly — the setup key is a secret and must not
land in a config file that is plain text on disk (`NETBIRD_SETUP_KEY` is persisted
into `/srv/netbird/.env`, mode 600, by the script itself):

```bash
NETBIRD_DOMAIN=netbird.example.com NETBIRD_CLIENT_ENABLED=true \
  NETBIRD_SETUP_KEY=<KEY> ./tasks/setup-netbird.sh
```

---

## 4. What the script does, and what it cannot do

| Step | Owner |
|---|---|
| Traefik installed when missing, `proxy` network, TLS via Let's Encrypt | script |
| `netbird-server` (management+signal+relay+STUN+IdP) + dashboard containers | script |
| `config.yaml` with `exposedAddress: "https://<domain>:443"` | script |
| STUN published on `udp/3478`, UFW rule for it | script |
| Enrollment of the routing peer, with `ip_forward` persistence | script |
| Failing (not warning) when the peer is not authenticated | script |
| **Owner account** — unless you pass `NETBIRD_ADMIN_EMAIL/PASSWORD` | dashboard |
| **Setup keys** | dashboard (or the API) |
| **Network + LAN resource + access policy** | dashboard (or the API) |
| **Router assignment** for that Network | dashboard (or the API) |
| **Mobile app enrollment** and route acceptance | the phone |

The middle rows are state inside the management SQLite store, not files on disk, so
the script neither writes nor verifies them. Automating them means the management
REST API with a personal access token, which this task does not implement — the
flow below assumes the dashboard.

---

## 5. The flow, end to end

### Step 1 — install the server

```bash
ACME_EMAIL=you@example.com NETBIRD_DOMAIN=netbird.example.com \
  ./tasks/setup-netbird.sh
```

The script ends with a reachability check on
`https://$NETBIRD_DOMAIN/oauth2/.well-known/openid-configuration`. If that fails,
stop: nothing downstream can work until DNS, the 443 forward and the certificate do.

### Step 2 — first owner

Open `https://netbird.example.com/setup` **immediately** and create the owner (the
page is only live until the first account exists). If you pre-seeded
`NETBIRD_ADMIN_EMAIL`/`NETBIRD_ADMIN_PASSWORD` instead, log in with those.

### Step 3 — declare the LAN in the mesh

Two objects, and they are easy to confuse:

- **Network** (**Networks** in this version, **Routes** in older ones): holds the
  resources — here the subnet `192.168.178.0/24` (and optionally a single host,
  e.g. `192.168.178.57/32`).
- **Router**: the peer that will carry that traffic. Added in step 6.

Plus an access policy: source `Users` (or `All`), destination that Network. On the
onboarding path you get "Users to My Subnet" and "Homelab Access" for free — check
they are **enabled**, `bidirectional` is not required when masquerade is on.

### Step 4 — create a reusable setup key

Settings → Setup Keys → create:

- type **reusable** (a one-off key can only enroll a single peer);
- auto-assign group **Routing Peers** (otherwise the new peer lands in no group and
  later policies have nothing to match);
- no expiry, usage limit to taste.

Re-run policy: the key enrolls the peer once. The peer's identity then lives in the
`netbird-client` volume, so re-runs and restarts do not need the key again — only a
brand-new peer or a session expiry does.

### Step 5 — start the routing peer

```bash
NETBIRD_DOMAIN=netbird.example.com NETBIRD_CLIENT_ENABLED=true \
  NETBIRD_SETUP_KEY=<KEY> ./tasks/setup-netbird.sh
```

This enables IPv4 forwarding (and persists it), starts the `client` profile, then
enrolls the peer inside the container:

```bash
netbird service run                      # the daemon
netbird status --check live              # wait until responsive
netbird up --setup-key "$NETBIRD_SETUP_KEY"
```

The last two lines are why the container overrides the image's `entrypoint`: the
upstream entrypoint runs `netbird up` with no arguments at all. The client does read
its own `NB_SETUP_KEY` — verified on 0.77.1, where a non-UUID value fails with
`invalid setup-key ... invalid UUID length`, an unknown key with
`setup key is invalid`, and an *empty or absent* value drops into an interactive
OAuth **device flow** against the IdP that polls for five minutes and then dies with
`context deadline exceeded` — but this stack hands the container
`NETBIRD_SETUP_KEY` (the script's variable, not a client variable), so enrollment has
to pass the flag explicitly, which the command above does.

Then the script gates on `netbird status --check ready` (non-zero on `NeedsLogin`,
`LoginFailed`, `SessionExpired`) and prints the peer's overlay address:

```
Routing peer netbird-peer enrolled as 100.75.106.148/16.
```

If it prints the failure message instead, read §9 — in that state the container is
running and *looks* fine, but routes nothing.

### Step 6 — assign the router (dashboard)

Networks → your network → **Routers** → add `netbird-peer`:

| Field | Value |
|---|---|
| Peer | `netbird-peer` (the container's hostname, `NETBIRD_CLIENT_HOSTNAME`) |
| Enabled | yes |
| Masquerade | **on** (upstream enables it by default — confirm it) — your policies may be one-directional, and masquerade fixes the return path |
| Metric | leave at the default; only lower it if several routing peers compete for the same network |

Until this row exists the LAN resource is unreachable from the overlay, no matter
how correctly steps 1–5 were done.

### Step 7 — enroll the phone

Install the NetBird app, set the **management URL** to `https://netbird.example.com`
(the default points at the hosted service, so this is not optional), then either log
in with the local IdP account or use the setup key. On iOS grant *Local network
access* when prompted. Accept the offered route when the app asks.

### Step 8 — verify

See §8. Do not skip it: "the app shows connected" is not the same claim as "the
route is installed".

---

## 6. Which address should clients dial?

Because the routing peer joins the overlay with **host networking**, this machine
itself gets a `100.75.x.x` address. That gives you two ways to reach a service:

```
phone ──► 192.168.178.57:6768   via the routing peer    (needs the router, step 6)
phone ──► 100.75.x.x:6768       directly, as a peer     (no router needed)
```

If your only target is this machine — an Orca, web or API service — the second form
is strictly simpler: steps 3, 6 and the LAN policy are unnecessary, and starting the
container as a plain peer is enough. Set `ORCA_PAIRING_ADDRESS=<the peer's 100.x
address>` in `tasks/setup-orca.sh` so the pairing link the mobile app scans points at
the overlay address instead of the LAN IP (`--pairing-address` is baked into the QR
and the link, so a LAN IP will not resolve away from home).

Reach anything else behind that router with the LAN address (`http://192.168.178.x:port`)
— that is the case the routing peer exists for.

---

## 7. Files and objects on the routing-peer host

| Path | What |
|---|---|
| `/srv/netbird/.env` | generated secrets + runtime vars, mode 600, created once; the setup key line is updated in place |
| `/srv/netbird/config.yaml` | server config, mode 600, **only written if missing** — manual edits are kept |
| `/srv/netbird/docker-compose.yml` | copied from `templates/netbird/docker-compose.traefik.yml`, only if missing |
| volume `netbird-data` | the management SQLite store (`store.db`, `idp.db`), the relay state, geolite |
| volume `netbird-client` | the routing peer's identity — delete it only to re-enroll from scratch |
| `/etc/sysctl.d/99-netbird.conf` | `net.ipv4.ip_forward=1` |

A template fix never reaches an existing install (the two generated files are
write-once) — copy the template over the live file and `docker compose up -d`:

```bash
cp templates/netbird/docker-compose.traefik.yml /srv/netbird/docker-compose.yml
docker compose -f /srv/netbird/docker-compose.yml pull
docker compose -f /srv/netbird/docker-compose.yml up -d
docker compose -f /srv/netbird/docker-compose.yml --profile client up -d netbird-client
```

---

## 8. Verification checklist

Run these in order; the first failure tells you which layer you are in.

**1. Public reachability (from anywhere, e.g. a laptop on another network)**

```bash
curl -fsSk https://netbird.example.com/oauth2/.well-known/openid-configuration | head -c 200
```
→ JSON. No → DNS, 443 forward, or certificate.

**2. The routing peer's own view** (`Management: Connected` alone is not enough)

```bash
docker exec netbird-client netbird status
docker exec netbird-client netbird status --json | tr ',' '\n' \
  | grep -E '"url"|netbirdIp|daemonStatus|connected'
```

Good output:

```
Management: Connected
Signal: Connected
Relays: 2/2 Available
NetBird IP: 100.75.106.148/16
Peers count: 0/1 Connected
```

`Signal: Disconnected` with `missing port in address` in the logs → `exposedAddress`
is missing `:443` (§9). `daemonStatus: NeedsLogin` → not enrolled (§5 step 5).

**3. The host actually forwards from the overlay**

NetBird installs its own forward rule ahead of the UFW chains, so `-P FORWARD DROP`
is not an obstacle. Confirm it:

```bash
docker exec netbird-client iptables -S FORWARD | head -4
# -P FORWARD DROP
# -A FORWARD -o wt0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# -A FORWARD -i wt0 -j ACCEPT          ← inbound overlay traffic accepted
```

And that forwarding survives a reboot: `sysctl net.ipv4.ip_forward` → `= 1`.

**4. What each side thinks the route situation is**

```bash
docker exec netbird-client netbird networks list        # the peer's view of its Networks
docker exec netbird-client netbird forwarding list      # active forwarding rules
```

Both print `No networks available.` / `No forwarding rules available.` for a peer that
has nothing to consume — and note that `netbird networks list` is the **consumer** view:
it stays empty on the routing peer even after step 6, whose prefixes instead appear in
`netbird status` under `Networks:`. Ask a different peer (the phone), whose
`netbird networks list` offers the LAN network to select — that is the cleanest signal
that the control plane is wired up, and it distinguishes it from a transport problem.

**5. End to end from a peer**

On the phone (or any second peer):

```
ping 192.168.178.57        # the routing-peer host itself
ping 192.168.178.1         # any LAN host → proves forwarding, not just host reach
curl -v 192.168.178.57:6768
```

`ping 192.168.178.57` answering but nothing else on the subnet → the peer is fine and
the route/masquerade is missing (step 6). Nothing at all → check the policy and that
the phone's peer is in the policy's source group.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `docker logs netbird-client` shows `dial tcp: address <host>: missing port in address`, then `create connection: dial context: context deadline exceeded`; `Management: Connected` but `Signal: Disconnected`, `Relays: 0/0` | `exposedAddress` in `config.yaml` has no port; peers derive the signal/relay endpoint from it | set `exposedAddress: "https://<domain>:443"`, restart `netbird-server`, restart `netbird-client`. This bug keeps **every** peer — the phone included — logged in but never connected |
| `Error: daemon up failed: login failed: ... invalid setup-key` | key wrong, expired or used up | create a **reusable** key, re-run with it |
| `netbird-client is not enrolled and NETBIRD_SETUP_KEY is empty`, container in a restart loop | profile started without a key and the peer is new | pass `NETBIRD_SETUP_KEY=<KEY>`; the script then persists it in `.env` |
| IdP logs fill with `/oauth2/device?user_code=…` requests every few minutes | keyless `netbird up` doing a device flow | §5 step 5; make sure the key reaches the container |
| Peer visible in dashboard, `connected=0` forever | same `exposedAddress` bug, or no relay/signal path | row 1 above |
| Route not installed on the phone, everything else green | no Router assigned, or the policy is disabled, or the peer is in no group | steps 3, 4, 6 |
| Works on Wi-Fi at home, fails on mobile data | 443 forward, or STUN/UDP blocked → relay | test from another network; add the 3478/udp forward |
| `ping 192.168.178.x` from phone fails though `192.168.178.57` works | router assigned without masquerade and the policy is one-directional | enable masquerade |
| Everything fine until a reboot, then dead | `ip_forward` reverted | confirm `/etc/sysctl.d/99-netbird.conf`; `sysctl net.ipv4.ip_forward` |
| Session dies after a few months | login expiry (`SessionExpired`) | the key path re-enrolls: re-run step 5 with the persisted key |
| IPv6-only resources unreachable | `net.ipv6.conf.all.forwarding` is `0` | not enabled by this script — set it only if you intend to route IPv6 |

Useful:

```bash
docker compose -f /srv/netbird/docker-compose.yml logs -f netbird-client
docker exec netbird-client netbird status --detail
docker exec netbird-client netbird networks list
docker exec netbird-client netbird forwarding list
```

---

## 10. Upgrades, backup, security

- **Upgrade**: bump `NETBIRD_SERVER_TAG` / `NETBIRD_CLIENT_TAG` / `NETBIRD_DASHBOARD_TAG`,
  then re-run the script. If you want the new tags persisted into the frozen `.env`,
  delete `.env` **and** `config.yaml` **and** `docker-compose.yml` together first —
  that rotates secrets, so back them up. Check both release pages: the optional
  reverse-proxy container must never be newer than the management, and a mobile
  client that is far ahead of a pinned management will not stay in sync.
- **Backup**: back up `netbird-data`, `/srv/netbird/config.yaml`, `/srv/netbird/.env`.
  The store encryption key protects setup keys and API tokens; lose it and they all
  become unreadable. The management DB is the *only* place the Networks, routers and
  policies exist.
- **Security**: the setup key is a bearer credential that can mint peers — treat it
  like a password and keep it out of `machine-config.yml`, shell history and logs.
  Revoke a key as soon as it is not needed. Enable TOTP for the local IdP users.
  Nothing here needs any inbound port on client machines; on the server, keep
  `:9000` (health) and `:9090` (metrics) off public interfaces.

---

## 11. References

- Upstream: [self-hosted quickstart](https://docs.netbird.io/selfhosted/selfhosted-quickstart),
  [external reverse proxy](https://docs.netbird.io/selfhosted/external-reverse-proxy),
  [Docker client](https://docs.netbird.io/get-started/install/docker),
  [network routes](https://docs.netbird.io/manage/network-routes),
  [setup keys](https://docs.netbird.io/manage/peers/register-machines-using-setup-keys)
- This repo: `tasks/setup-netbird.sh`, `templates/netbird/*`,
  `AUTOMATIONS.md` → *NetBird*,
  [docs/research/netbird-setup-review-2026-10-03.md](docs/research/netbird-setup-review-2026-10-03.md)
