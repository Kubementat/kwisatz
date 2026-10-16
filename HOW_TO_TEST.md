# HOW TO TEST — Hermes Agent in a virt-runner VM

Manual test plan for `tasks/setup-hermes.sh` (VM-based Hermes setup) on the real server.

## Already verified (2026-10-01, nested VM test)

The script was run through the repo's VM test harness on a fresh Ubuntu 26.04 test VM, with the
Hermes VM created nested inside it (ufw active, Docker installed):

```bash
tests/run-vm-tests.sh --ram 10 --vcpu 4 --disk 60 --timeout 60 \
  --scripts setup-basics,configure-firewall,setup-docker,setup-hermes
```

Passed there, so on the server these are confirmations rather than open risks: T0–T5, T7, T9,
T10a–T10c, T11a (HTTP answer through the host proxy and ufw, from another machine) and T13
(cold start of the host: VM autostart, address, shares, filter, services, proxy).

**Not verified anywhere yet — these are the tests that matter on the server:**

- T6 (changing the pin), T8 (a real `hermes setup` with a bot and a provider key),
  T10d (guest root trying to bypass the filter), T11b/T11c (Hermes Desktop and a phone),
  T12 (Traefik), T14 (restore), and the Docker → VM migration.
- Allowlisting a **Docker-published** host port and a service on **another LAN machine**
  (the test VM only had its own sshd to allowlist).
- The local LLM endpoint wiring (`HERMES_LLM_*`): the `hermes config set` calls against a
  never-configured install, the API-key keep-on-rerun behavior, the automatic allowlist entry
  for the endpoint, and the gateway restart picking the model up — test against the real
  llama-swap on this server (see `machine-config.yml.example` and the migration doc step 7).
- A host whose libvirt network has IPv6.

Design: `docs/plans/hermes-vm-refactor.md` · Research: `docs/research/hermes-agent-vm-install.md`
· Migration (separate, one-off): `docs/hermes-docker-to-vm-migration.md`

## Before you start

- Run on the server, as your normal user (ideally uid 1000 — `id -u`), from the kwisatz checkout
  on branch `feat/hermes-aget-refactor`.
- If the old Docker Hermes is running on this server, the tests below do not touch it, but
  **do not configure the same bot tokens in the VM** while it runs. Either test with a separate
  test bot, or do the migration (`docs/hermes-docker-to-vm-migration.md`) after T1–T7 pass.
  Note: T4 creates `/srv/hermes/backups`, and warns if `/srv/hermes/workspace` is still owned
  by uid 10000 (expected before the migration; the guest then cannot write to `/workspace`).
  To test without touching `/srv/hermes` at all, prefix every `setup-hermes.sh` call with
  `HERMES_HOST_DIRECTORY=/srv/hermes-test HERMES_VM_NAME=hermes-test HERMES_VM_IP=192.168.122.51`
  (the default address is `.50` on the libvirt `default` network, normally `192.168.122.50`)
  and substitute those names in the commands below.
- Shorthand used below:
  - **host$** = command on the server
  - **guest$** = command inside the VM (`virt-runner ssh hermes`)
  - `V="virsh -c qemu:///system"` — define it once in your host shell.
- Fill in the values you will use:

  | Placeholder | Meaning | Your value |
  |---|---|---|
  | `<LAN_CIDR>` | your LAN, e.g. `192.168.1.0/24` | |
  | `<SERVER_LAN_IP>` | the server's LAN address | |
  | `<HOST_DOCKER_PORT>` | a Docker-published service on the server (e.g. Forgejo 3000) | |
  | `<HOST_NATIVE_PORT>` | a natively running service on the server (e.g. llama-swap) | |
  | `<LAN_IP>:<LAN_PORT>` | a service on another LAN machine | |
  | `<BLOCKED_IP>:<BLOCKED_PORT>` | another reachable LAN service that must stay blocked | |

- Port probe used in the guest (no extra packages needed):

  ```bash
  probe() { timeout 5 bash -c "</dev/tcp/$1/$2" 2>/dev/null && echo "open  $1:$2" || echo "BLOCKED $1:$2"; }
  ```

## Results table

| ID | Test | Result (pass/fail) | Notes |
|---|---|---|---|
| T0 | Lint | | |
| T1 | `--help` | | |
| T2 | Input validation | | |
| T3 | Prerequisite bootstrap | | |
| T4 | Fresh VM create | | |
| T5 | Re-run convergence (no VM re-creation) | | |
| T6 | Pinned commit + pin change | | |
| T7 | `hermes doctor` | | |
| T8 | Configure + gateway service | | |
| T9 | Backup timer | | |
| T10a | Egress: default (internet only) | | |
| T10b | Egress: allowlist works | | |
| T10c | Egress: changing the list converges | | |
| T10d | Egress: guest root cannot bypass | | |
| T11a | `HERMES_SERVE`: host proxy + credentials | | |
| T11b | Hermes Desktop from the LAN | | |
| T11c | Phone browser from the LAN | | |
| T12 | Traefik route (optional) | | |
| T13 | Host reboot | | |
| T14 | Backup restore into a fresh VM (optional) | | |
| T15 | Teardown | | |

---

## T0 — Lint

```bash
shellcheck tasks/setup-hermes.sh templates/hermes/provision-guest.sh
yamllint templates/hermes/traefik-hermes.yml templates/hermes/config.yaml.example
tests/lint.sh
```

Expected: no output from shellcheck and yamllint; `tests/lint.sh` ends without `FAIL`.

## T1 — Help

```bash
./tasks/setup-hermes.sh --help
```

Expected: usage text listing every `HERMES_*` variable, defaults 4 GiB / 2 vCPU / 50 GiB,
exit code 0, nothing created.

## T2 — Input validation (nothing is created)

```bash
HERMES_ALLOWED_ENDPOINTS="forgejo:3000" ./tasks/setup-hermes.sh; echo "rc=$?"
HERMES_SERVE=true ./tasks/setup-hermes.sh; echo "rc=$?"
HERMES_SERVE=false HERMES_TRAEFIK=true HERMES_DOMAIN=h.example.com ./tasks/setup-hermes.sh; echo "rc=$?"
HERMES_COMMIT=v0.21.5 ./tasks/setup-hermes.sh; echo "rc=$?"
```

Expected: each prints one `[ERROR]` line naming the offending variable and `rc=1`.

## T3 — Prerequisite bootstrap

Only meaningful on a machine where libvirt or virt-runner is **not** installed yet. If both are
installed (`command -v virsh virt-runner`), mark as "n/a" — T4 covers the normal path.

```bash
# VIRT_RUNNER_BRANCH is needed until virt-runner's 'create --mount' is on its default branch.
VIRT_RUNNER_BRANCH=develop ./tasks/setup-hermes.sh
```

Expected: `[INFO] libvirt is not installed — running setup-virtualization.sh` and/or
`[INFO] virt-runner is not installed — running setup-virt-runner.sh`, then
`Re-executing … to pick up the new group membership`, and the script continues with T4 in the
same run (no log out/in needed).

If virt-runner **is** already installed but too old, the script stops with
"The installed virt-runner has no 'create --mount'". Update it:
`VIRT_RUNNER_BRANCH=develop ./tasks/setup-virt-runner.sh && uv tool install --force ~/dev/os_projects/virt-runner`.

## T4 — Fresh VM create

```bash
time ./tasks/setup-hermes.sh
```

Expected output, in order: `libvirt and virt-runner are usable` → `VM created` →
`DHCP reservation … set` → `Network filter 'hermes-egress' defined (allowlist: none)` →
`Network filter attached to the VM` → `Restarting the VM once …` →
`VM is running at 192.168.122.50 with network filter 'hermes-egress'` → installer output →
`hermes-backup.timer is active` → `hermes-gateway.service is active` →
`Hermes Agent VM is ready`, followed by the "Configure Hermes" next steps. Exit code 0.
The gateway service runs from the first install on and idles until Hermes is configured.

Checks:

```bash
# host$
V="virsh -c qemu:///system"
virt-runner list                                  # hermes, running, IP 192.168.122.50
$V dominfo hermes | grep -E 'CPU\(s\)|Max memory|Autostart'   # 2, 4194304 KiB, enable
$V net-dumpxml default | grep "name='hermes'"     # <host mac=… name='hermes' ip='192.168.122.50'/>
$V dumpxml hermes | grep filterref                # <filterref filter='hermes-egress'/>
ls -ld /srv/hermes/workspace /srv/hermes/backups  # owned by you; backups is drwx------
```

```bash
# guest$   (virt-runner ssh hermes)
nproc; free -g | head -2; df -h / | tail -1       # 2 CPUs, ~4 GiB, ~50 GiB disk
findmnt -t virtiofs                               # /workspace and /mnt/backups
touch /workspace/vm-write-test && ls -la /workspace/vm-write-test
sudo -n true && echo "passwordless sudo ok"
systemctl --user list-timers hermes-backup.timer --no-pager
loginctl show-user "$USER" -p Linger              # Linger=yes
```

```bash
# host$
ls -la /srv/hermes/workspace/vm-write-test        # exists, owned by you
rm /srv/hermes/workspace/vm-write-test
```

Risk check (plan: "mounts are fixed at create"): both mounts must be present now; they cannot
be added to an existing VM.

Risk check (libvirt + Docker firewall interplay): `guest$ curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://github.com`
must print `200`. If the guest has **no** internet at all although the script succeeded up to
the installer, Docker's FORWARD policy is blocking libvirt NAT traffic — record it; that needs
a host-level fix before anything else here can pass.

## T5 — Re-run convergence (no VM re-creation)

```bash
# host$ — record before
$V domuuid hermes
virt-runner ssh hermes      # guest$ uptime -s ; exit
time ./tasks/setup-hermes.sh
$V domuuid hermes
virt-runner ssh hermes      # guest$ uptime -s ; exit
```

Expected: `VM already exists — keeping it`, `DHCP reservation … already present`,
`Network filter already attached to the VM`, **no** "Restarting the VM" line,
`Hermes Agent already at pinned commit … — skipping the installer`. Same domain UUID and the
same `uptime -s` (no reboot). Runtime well under a minute.

Also test the stopped-VM path:

```bash
$V shutdown hermes; sleep 20; $V domstate hermes   # shut off
./tasks/setup-hermes.sh                            # "VM is shut off — starting it", then success
```

## T6 — Pinned commit and pin change

```bash
# guest$
git -C ~/.hermes/hermes-agent rev-parse HEAD      # f97608f178d1ffeca59860195ab7da295f7c8e5f
hermes --version                                  # v0.21.5 / 2026.9.24
```

Risk check (plan: "`--commit` pinning is undocumented; confirm it survives re-runs"). Do this
**before** configuring Hermes (T8), so a downgrade cannot hurt real data. The SHA below is the
previous release (git tag v2026.9.21):

```bash
# host$
HERMES_COMMIT=d337b736aa1e8ebecfab043842d13e4a2d2f48a3 ./tasks/setup-hermes.sh
virt-runner ssh hermes      # guest$ git -C ~/.hermes/hermes-agent rev-parse HEAD  → d337b736… ; exit
./tasks/setup-hermes.sh     # back to the default pin
virt-runner ssh hermes      # guest$ git -C ~/.hermes/hermes-agent rev-parse HEAD  → f97608f1… ; exit
```

Expected: both runs print `Installing Hermes Agent at commit …`, end successfully, and `HEAD`
matches the requested commit each time. If the installer fails with "commit … is not on branch
main" or leaves a different `HEAD`, the pin mechanism does not work as assumed — record the
installer output (`guest$ tail -50 ~/.hermes/logs/install.log`).

## T7 — `hermes doctor`

```bash
# guest$
hermes doctor; echo "rc=$?"
```

Expected on an unconfigured install: missing provider/API key findings only; no missing
binaries, no Python/Node errors, no storage errors. Record `rc` and any other finding. (The
setup script treats doctor as informational and prints its output; it does not fail on it.)

## T8 — Configure Hermes and start the gateway

Use a **test bot token** if the old Docker gateway is still running.

```bash
# guest$
hermes setup               # provider key, model, one messaging platform + allowlisted user
ls -la ~/.hermes/.env      # -rw------- (600)
hermes gateway restart     # pick up the new settings
```

Expected: the restart succeeds and the journal no longer shows `No messaging platforms enabled`.

```bash
# guest$
systemctl --user is-active hermes-gateway         # active
systemctl --user is-enabled hermes-gateway        # enabled
journalctl --user -u hermes-gateway -n 30 --no-pager
grep -E '^(terminal|  backend|  cwd)' ~/.hermes/config.yaml
```

Then send the bot a message and ask it to run `uname -a && pwd && sudo -n id`.
Expected: it answers; the command runs inside the VM (hostname `hermes`), `sudo` works.
Messages from a non-allowlisted account are ignored/declined.

Risk checks (assumptions made during implementation):

- `hermes gateway install` ran without prompting (the script feeds it no stdin). If the script
  hung or failed there, record the output.

Re-run `./tasks/setup-hermes.sh` on the host: expected no `Installing the gateway user service`
line, gateway stays active, settings untouched.

## T9 — Backup timer

```bash
# guest$
systemctl --user list-timers hermes-backup.timer --no-pager   # next run 03:00
systemctl --user start hermes-backup.service; echo "rc=$?"
systemctl --user status hermes-backup.service --no-pager | tail -15
ls -la /mnt/backups
```

```bash
# host$
ls -la /srv/hermes/backups        # hermes-backup-<timestamp>.zip, owned by you
unzip -l /srv/hermes/backups/hermes-backup-*.zip | head -20
```

Expected: `rc=0`, one new zip visible on the host, containing `config.yaml`, `state.db`, … .
Retention: start the service 8 more times (`for i in $(seq 8); do systemctl --user start hermes-backup.service; sleep 2; done`)
— at most 7 `hermes-backup-*.zip` files remain. Note if `hermes backup` itself already prunes
to fewer (its own `--keep` default is 3).

## T10 — Egress allowlist

Define `probe` (see top) in the guest shell first.

### T10a — Default: internet only

After a run without `HERMES_ALLOWED_ENDPOINTS` (T4/T5 state):

```bash
# guest$
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://api.github.com   # 200 (internet + DNS)
probe 192.168.122.1 <HOST_DOCKER_PORT>     # BLOCKED
probe 192.168.122.1 <HOST_NATIVE_PORT>     # BLOCKED
probe <SERVER_LAN_IP> <HOST_DOCKER_PORT>   # BLOCKED
probe <LAN_IP> <LAN_PORT>                  # BLOCKED
probe 169.254.169.254 80                   # BLOCKED
```

```bash
# host$
ssh -i ~/.ssh/virt_runner_key ubuntu@192.168.122.50 true && echo "inbound ssh ok"
$V nwfilter-dumpxml hermes-egress          # accept in, DNS/DHCP, 5 drop rules, accept out
```

### T10b — Allowlist works

```bash
# host$
HERMES_ALLOWED_ENDPOINTS="host:<HOST_DOCKER_PORT> host:<HOST_NATIVE_PORT> <LAN_IP>:<LAN_PORT>" \
  ./tasks/setup-hermes.sh
sudo ufw status | grep hermes-vm           # one 'hermes-vm egress' rule per host: port
```

Expected: `Network filter 'hermes-egress' defined (allowlist: …)`, `ufw: allow in on virbr0 …`
lines, and **no** "Restarting the VM" line (the filter is updated live).

```bash
# guest$
probe 192.168.122.1 <HOST_DOCKER_PORT>     # open
probe 192.168.122.1 <HOST_NATIVE_PORT>     # open
probe <LAN_IP> <LAN_PORT>                  # open
probe <BLOCKED_IP> <BLOCKED_PORT>          # BLOCKED
probe 192.168.122.1 22                     # BLOCKED (any host port not listed)
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://api.github.com   # still 200
uptime -s                                  # unchanged → no reboot
```

Risk checks (plan: "nwfilter + ufw + Docker-published ports need a real test"):

- Docker-published host port (`host:<HOST_DOCKER_PORT>`) is `open`.
- Natively running host service (`host:<HOST_NATIVE_PORT>`) is `open`. If it is `BLOCKED`,
  check `ss -ltnp | grep <HOST_NATIVE_PORT>`: a service bound to `127.0.0.1` cannot be reached
  from the VM by design — it must listen on `0.0.0.0` or `192.168.122.1`.
- Use the real thing: `guest$ curl -sS -m 10 http://192.168.122.1:<HOST_NATIVE_PORT>/v1/models`
  (llama-swap / llama.cpp) returns JSON.
- Note that `<SERVER_LAN_IP>:<port>` stays blocked unless listed explicitly: inside the VM the
  host is addressed as `192.168.122.1` (`host:`).

### T10c — Changing the list converges

```bash
# host$ — drop the LAN endpoint
HERMES_ALLOWED_ENDPOINTS="host:<HOST_DOCKER_PORT>" ./tasks/setup-hermes.sh
```

```bash
# guest$
probe 192.168.122.1 <HOST_DOCKER_PORT>     # open
probe 192.168.122.1 <HOST_NATIVE_PORT>     # BLOCKED again
probe <LAN_IP> <LAN_PORT>                  # BLOCKED again
uptime -s                                  # unchanged
```

Known, documented limitation: the ufw rule for the removed `host:<HOST_NATIVE_PORT>` is still
listed in `sudo ufw status` (the network filter is what blocks). Remove it by hand with
`sudo ufw status numbered` / `sudo ufw delete <n>` if you want it gone.

### T10d — Guest root cannot bypass

```bash
# guest$
sudo iptables -F 2>/dev/null; sudo nft flush ruleset 2>/dev/null
probe <BLOCKED_IP> <BLOCKED_PORT>          # still BLOCKED
```

Set the allowlist you actually want before continuing (re-run with your final
`HERMES_ALLOWED_ENDPOINTS`).

## T11 — `HERMES_SERVE` (Hermes Desktop / dashboard on the LAN)

Keep your final `HERMES_ALLOWED_ENDPOINTS` in every call from here on.

### T11a — Host proxy and credentials

```bash
# host$
HERMES_SERVE=true HERMES_SERVE_ALLOW_FROM=<LAN_CIDR> HERMES_ALLOWED_ENDPOINTS="…" \
  ./tasks/setup-hermes.sh
```

Expected: `Generating dashboard basic-auth credentials`, `hermes-serve.service is active`,
`hermes serve answers on port 9119`, `ufw: allow from <LAN_CIDR> to any port 9119 proto tcp`,
`hermes serve is reachable on this host, port 9119`. The password is **not** printed.

```bash
# host$
systemctl is-active hermes-vm-proxy.socket                       # active
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9119/  # 200, 302 or 401 — not 000
sudo ufw status | grep 9119
ss -ltn | grep -E ':(9119|8642)\b'                               # 9119 only; nothing on 8642
```

```bash
# guest$
systemctl --user is-active hermes-serve                          # active
grep HERMES_DASHBOARD_BASIC_AUTH ~/.hermes/.env                  # username admin + password + secret
grep HERMES_DASHBOARD_BASIC_AUTH ~/.hermes/.env | sha256sum      # note the hash
```

Re-run the same command on the host, then repeat the `sha256sum` line in the guest.
Expected: identical hash (credentials are not rotated), no "Generating …" line.

### T11b — Hermes Desktop from another LAN machine

1. On a laptop in `<LAN_CIDR>`: `curl -s -o /dev/null -w '%{http_code}\n' http://<SERVER_LAN_IP>:9119/`
   → `200`, `302` or `401`.
2. Hermes Desktop → Settings → Gateways → Remote gateway → `http://<SERVER_LAN_IP>:9119`,
   sign in with the credentials from T11a.
3. Send a chat message and let it run a tool (e.g. "list /workspace").

Expected: sign-in succeeds, the chat streams a reply, existing sessions are listed.

Risk check (plan: issue #38412, Desktop rejected on `/api/ws` with code 4403): if sign-in
works but the chat never connects, check `guest$ journalctl --user -u hermes-serve -n 50 --no-pager`
for `4403` / origin errors and record them, plus the Desktop version.

Negative check: from a machine **outside** `<LAN_CIDR>` (or temporarily use a too-narrow
`HERMES_SERVE_ALLOW_FROM`), port 9119 times out.

### T11c — Phone browser

On a phone in the same Wi-Fi open `http://<SERVER_LAN_IP>:9119/`, sign in, send a message.

Expected: the dashboard loads and chat works. There is **no official Hermes mobile app**;
community apps that expect the API server on port 8642 will not connect (8642 is deliberately
not exposed). Record which client you tried.

## T12 — Traefik route (optional; needs a running Traefik from `setup-traefik.sh`)

```bash
# host$
HERMES_SERVE=true HERMES_SERVE_ALLOW_FROM=<LAN_CIDR> HERMES_TRAEFIK=true \
  HERMES_DOMAIN=hermes.<your-domain> HERMES_ALLOWED_ENDPOINTS="…" ./tasks/setup-hermes.sh
sudo cat /opt/traefik/dynamic/hermes.yml
sudo ufw status | grep 'hermes-vm serve (traefik)'
curl -sk -o /dev/null -w '%{http_code}\n' https://hermes.<your-domain>/
```

Expected: `Traefik route written`, a ufw rule for the Docker `proxy` network subnet, and the
`curl` returns `200`/`302`/`401` with a valid certificate (drop `-k` to check). Then repeat
T11b with `https://hermes.<your-domain>` as the remote URL — the WebSocket must also work
through Traefik.

Assumptions to confirm: the cert resolver is named `letsencrypt`, the `security-headers@file`
middleware exists, and the Traefik container resolves `host.docker.internal`. If the route
shows an error in the Traefik dashboard/logs, record it.

## T13 — Host reboot

```bash
# host$
sudo reboot
# after the server is back:
V="virsh -c qemu:///system"
$V list --all                                      # hermes  running
$V dumpxml hermes | grep filterref                 # filter still attached
ssh -i ~/.ssh/virt_runner_key ubuntu@192.168.122.50 \
  'uptime -s; systemctl --user is-active hermes-gateway hermes-serve hermes-backup.timer; findmnt -t virtiofs -n | wc -l'
systemctl is-active hermes-vm-proxy.socket         # active (if HERMES_SERVE was used)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9119/
```

Expected: the VM came back by itself on the same IP, all three units `active` without anyone
logging in (linger), `2` virtiofs mounts, the proxy answers. Send the bot a message — it
replies. Repeat one `probe` from T10b (open) and one blocked one.

## T14 — Backup restore into a fresh VM (optional, proves the backup is usable)

Uses a second VM so the main one is untouched.

```bash
# host$
HERMES_VM_NAME=hermes-restore HERMES_VM_IP=192.168.122.52 ./tasks/setup-hermes.sh
virt-runner ssh hermes-restore
# guest$  — stop here if the main VM's gateway is running with real bot tokens:
#          import only, do NOT re-run setup-hermes.sh for this VM afterwards.
ls /mnt/backups
hermes import "$(ls -1t /mnt/backups/hermes-backup-*.zip | head -1)" --force
hermes doctor
ls ~/.hermes/memories ~/.hermes/skills
exit
# host$
virt-runner destroy hermes-restore
virsh -c qemu:///system nwfilter-undefine hermes-restore-egress
virsh -c qemu:///system net-dumpxml default | grep "name='hermes-restore'"   # copy the line, then:
virsh -c qemu:///system net-update default delete ip-dhcp-host "<paste the host line>" --live --config
```

Expected: import exits 0, memories and skills are present.

## T15 — Teardown (only if you want to remove the test install)

`virt-runner destroy` deletes the VM disk, i.e. all Hermes state. The zips in
`/srv/hermes/backups` and the workspace survive.

```bash
# host$
V="virsh -c qemu:///system"
virt-runner destroy hermes
$V nwfilter-undefine hermes-egress
$V net-dumpxml default | grep "name='hermes'"       # copy the <host …/> line, then:
$V net-update default delete ip-dhcp-host "<paste the host line>" --live --config
sudo systemctl disable --now hermes-vm-proxy.socket hermes-vm-proxy.service
sudo rm -f /etc/systemd/system/hermes-vm-proxy.socket /etc/systemd/system/hermes-vm-proxy.service
sudo systemctl daemon-reload
sudo rm -f /opt/traefik/dynamic/hermes.yml
sudo ufw status numbered | grep hermes-vm            # delete each: sudo ufw delete <n> (highest first)
```

Expected: `virt-runner list` no longer shows `hermes`; `$V nwfilter-list | grep hermes` and
`$V net-dumpxml default | grep hermes` print nothing. Running `./tasks/setup-hermes.sh` again
afterwards creates a fresh VM (T4).

---

## Not covered by this test plan

- **Docker → VM data migration**: follow `docs/hermes-docker-to-vm-migration.md`. Its open
  risks are the `hermes import` across the v0.21.0 session-store rewrite and platform logins
  that are not part of `hermes backup`.
- **Automated VM test suite** (`tests/run-vm-tests.sh`): `setup-hermes` is an ad-hoc entry in
  `tests/machine-config.test.yml` (disabled by default; needs nested KVM and a bigger test VM,
  see the comment there). It covers install and convergence, not a configured Hermes.
- **IPv6**: the libvirt `default` network on the development machine has no IPv6 range, and
  the network filter only contains IPv4 rules. If your server's `default` network has an
  `<ip family='ipv6'>` block (`$V net-dumpxml default`), guest IPv6 traffic is not filtered —
  record that.

## What to send back

The filled-in results table, plus for every failed step: the command, the full output, and
(for guest-side failures) `guest$ tail -80 ~/.hermes/logs/install.log` or the relevant
`journalctl --user -u <unit> -n 80 --no-pager`.
