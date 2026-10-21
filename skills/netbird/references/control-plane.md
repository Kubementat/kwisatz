# NetBird control plane: keys, networks, policies, API

The control plane is the source of truth for users, peers, groups, setup keys,
networks, routers and policies. It lives in the management service's store (SQLite /
Postgres depending on deployment) — **not** in any file on a peer, so no amount of
client-side configuration can fix a missing object here.

## Auth model

Everything under `https://<management-domain>/api` needs:

```
Authorization: Token nbp_<personal-access-token>      # the normal one
Authorization: Bearer <device-flow JWT>               # short-lived, from an SSO login
```

Unauthenticated calls answer `401 {"message":"no valid authentication provided"}` and
unknown paths answer `404 404 page not found`, which is a cheap way to confirm the API
is routed correctly without a token.

A **Personal Access Token (PAT)** belongs to a user. Create one in
*Settings → Personal access tokens*, or through the API once you have a session:

```bash
ID=$(curl -s -H "Authorization: Token $NB_TOKEN" .../api/users/current | jq -r .id)
curl -s -X POST -H "Authorization: Token $NB_TOKEN" \
     -d '{"name":"automation","expires_in":90}' .../api/users/$ID/tokens \
  | jq -r .plain_token          # expires_in is in DAYS (1-365); the secret is plain_token
```

Store it like a password; it is shown once.

### Bootstrap without a browser

The `/setup` page only answers while no user exists. For headless installs the
management server can mint the first owner **and** a PAT in one call, but only when
`NB_SETUP_PAT_ENABLED=true` is set on the management container (default off, since the
endpoint is unauthenticated while setup is pending):

```bash
curl -sk -X POST https://nb.example.com/api/setup \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","name":"Owner","password":"...","create_pat":true,"pat_expire_in":1}'
```

`personal_access_token` comes back in the body (response carries `Cache-Control:
no-store` — do not log it). Once an account exists `/api/setup` refuses, so use this
only for the very first user, then create a dedicated service user token.

## Setup keys

`GET|POST /api/setup-keys`, `GET|PUT|DELETE /api/setup-keys/{keyId}`.

```bash
curl -s -X POST -H "Authorization: Token $NB_TOKEN" \
  -d '{"name":"homelab-servers","type":"reusable","expires_in":2592000,"auto_groups":["<group-id>"],"usage_limit":10}' \
  https://nb.example.com/api/setup-keys | jq '{id,key,type,state}'
```

| Field | Notes |
|---|---|
| `type` | `reusable` (multiple peers — what servers need) or `one-off` (single peer) |
| `expires_in` | **integer seconds**, 86400 … 31536000 (1 day … 1 year); required |
| `auto_groups` | **Set this** (required). Without it a key-registered peer lands in no group and later policies have nothing to match |
| `usage_limit` | required; `0` = unlimited uses |
| `ephemeral` | separate boolean: peers registered with the key disappear when they disconnect |
| `allow_extra_dns_labels` | lets the peer pass `--extra-dns-labels` |

Returned `key` is the UUID you pass to `netbird up --setup-key`. Read the response —
like a PAT it may only be shown in full on creation; a key's `state` (`valid`,
`overused`, `expired`, `revoked`), `valid`, `used_times` and `last_used` tell you
whether it is still usable. Revoke keys you no longer need:
`PUT /api/setup-keys/{keyId} {"revoked":true}`. Endpoints: `GET|POST /api/setup-keys`,
`GET|PUT|DELETE /api/setup-keys/{keyId}`.

Registration always needs the management URL — for self-hosted, `netbird up
--management-url https://nb.example.com --setup-key …`, or `NB_MANAGEMENT_URL` +
`NB_SETUP_KEY` in the environment.

## Networks, resources, routers

Every `POST`/`PUT` below needs `-H "Authorization: Token $NB_TOKEN" -H "Content-Type:
application/json"` — elided to keep the examples readable.

Two object models do the same job; only one is current:

| | Networks (current) | Routes (deprecated) |
|---|---|---|
| Distribution | assigned routers | `peer`/`peer_groups` on the route |
| Access control | built in; **denied unless a policy allows it** | optional ACL groups; **without them every peer in the distribution group has blanket access** |
| Resources | typed: IP / range / domain | CIDR or domain |
| Still needed for | everything except exit nodes | exit nodes (`0.0.0.0/0`) |

A Network is `{name, description, resources[], routers[], policies[], routing_peers_count}`.
A **resource** is one address/entry; a **router** is the peer that carries it.

```bash
# 1. Network
curl -s -X POST .../api/networks -d '{"name":"homelab-lan","description":"office LAN"}'
# 2. Resource inside it (id from the previous step)
curl -s -X POST .../api/networks/$NET/resources \
  -d '{"name":"lan-subnet","address":"192.0.2.0/24","enabled":true}'
# 3. Router assignment — the step that is always forgotten
curl -s -X POST .../api/networks/$NET/routers \
  -d "{\"peer\":\"$PEER_ID\",\"enabled\":true,\"masquerade\":true,\"metric\":64}"
```

Router request fields: `peer` **or** `peer_groups` (mutually exclusive — a group of
routing peers shares one metric, individual peers get individual metrics),
`metric` (1–9999, **lowest wins**), `enabled`, `masquerade`.
Find the peer id with `curl -s .../api/peers | jq '.[] | {id,name,ip,connected}'`.

How a consuming peer chooses among routers: metric → connection type (direct beats
relayed) → latency (≥10 ms better to avoid flapping). It switches when its router goes
offline, when a lower-metric router returns, or when its router falls back to relayed.
With `masquerade: true` every switch resets established TCP sessions through that
network; with it off, connections survive but the destination network must carry a
return route for the NetBird CIDR (`100.64.0.0/10`) pointing at each live router —
including after a failover, which is the part that breaks silently.

Masquerade is the default: the routing peer SNATs to its own LAN address and the LAN
needs no knowledge of NetBird. Turn it off for source-IP visibility, or when the
destination network's firewall filters by peer address. (Off is only supported on
Linux routing peers.)

Domain resources need the local DNS forwarder (port 22054 on modern peers, 5353 for
pre-0.59) and Routing Peer DNS Resolution; keep domains in their own Network when the
same network also holds an IP range, otherwise the policies leak into each other.

## Policies

`GET|POST /api/policies`, `GET|PUT|DELETE /api/policies/{policyId}`. A policy is
`{name, description, enabled, rules[]}`; a rule carries

```
action: accept | drop
protocol: all | tcp | udp | icmp | netbird-ssh
bidirectional: true | false
sources[]:  group ids          destinations[]: group ids
ports[]: ["443","5353"]        port_ranges[]: [{start:443,end:443}]   # mutually exclusive with ports
sourceResource / destinationResource                                    # for network resources
```

Because the schema drifts between releases, the reliable pattern is to read an existing
object back, edit it with `jq`, and write it back:

```bash
curl -s .../api/policies | jq '.[0]' > policy.json     # template
# edit, then:
curl -s -X PUT -d @policy.json .../api/policies/$(jq -r .id policy.json)
```

The two-chain rule that causes most "policy looks right" bugs:

- traffic **through** a routing peer to a backend resource → evaluated in the **forward**
  chain → you need a policy whose destination is that **network resource**
  (always unidirectional; the bidirectional toggle is disabled for it);
- traffic **to** the routing peer itself (its own SSH, Pi-hole, Grafana…) → **input**
  chain → you need a **peer-to-peer** policy.

Want both? Create both. ICMP also needs its own rule, so a health check by `ping` can
fail while TCP works.

## Other endpoints worth knowing

| Path | Use |
|---|---|
| `/api/instance/version` | server version — run this first to confirm what you are talking to |
| `/api/peers`, `/api/peers/{id}` | peers, their groups, `connected`, version, inactivity flags |
| `/api/groups` | groups (the currency of every policy); a peer is in exactly one |
| `/api/routes` | legacy routes: `network`, `domains`, `peer`/`peer_groups`, `groups`, `access_control_groups`, `metric`, `masquerade`, `keep_route` |
| `/api/networks/routers` | every router assignment across all networks |
| `/api/users`, `/api/users/{id}`, `/api/users/invites` | local/SSO users, invitations, `/api/users/{id}/password` |
| `/api/dns/zones`, `/api/dns/nameservers`, `/api/dns/settings` | split DNS; records under `/api/dns/zones/{id}/records` |
| `/api/events/audit`, `/api/events/network-traffic` | audit trail and traffic events |

## Debugging order for "the control plane looks right but nothing works"

1. `netbird status` on the peer — is `Signal:` connected and are relays available?
2. `netbird networks list` on the **consumer** peer — does the network appear at all?
   If not, no router is assigned or the network is not shared with your group.
3. `curl .../api/networks | jq` — is `routers[]` non-empty? Then
   `curl .../api/networks/$NET/routers | jq` for each router's `enabled`, `masquerade`
   and `metric`.
4. `curl .../api/policies | jq '.[] | {name,enabled,rules:(.rules|length)}'` — is a
   policy enabled, and does its source group contain the consumer peer's group?
5. `netbird forwarding list` on the router, `ip route` + `sysctl net.ipv4.ip_forward`
   on its host, `nft list ruleset` / `iptables -S FORWARD`.
6. `netbird status -d` on the consumer: is the routing peer `Connected`, direct or
   relayed? `... | jq .peers` for the same thing as data.

## Upstream references

- Networks: <https://docs.netbird.io/manage/networks>
- Routing peer model, HA and policy chains: <https://docs.netbird.io/manage/networks/how-routing-peers-work>
- Legacy routes: <https://docs.netbird.io/manage/network-routes>
- Setup keys: <https://docs.netbird.io/manage/peers/register-machines-using-setup-keys>
- API introduction and resources: <https://docs.netbird.io/api>, machine-readable
  schema: `shared/management/http/api/openapi.yml` in the netbird repository.
- Headless bootstrap: <https://docs.netbird.io/selfhosted/automated-setup>
