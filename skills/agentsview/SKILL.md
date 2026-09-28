---
name: agentsview
description: Retrieve and analyze AI agent session history (pi, Claude Code, Codex, opencode, ...) via the local AgentsView HTTP API. List and filter sessions, read transcripts and tool calls, full-text search message content, inspect health/outcome signals, token usage and cost, and pull AI-generated insights. Also covers collecting sessions from multiple machines (remote sync, shared PostgreSQL, file/S3 sources). Use when the user asks about past agent sessions, what an agent did, session statistics, token/cost usage, session search, "which session did X", or aggregating sessions from several machines/hosts.
---

# AgentsView

AgentsView is a local, first-party viewer/analytics server for AI coding-agent
sessions. It discovers session logs from 20+ agents (pi, Claude Code, Codex,
opencode, ...), indexes them into a local SQLite archive, and exposes a JSON
API plus web UI. **All data stays local; no auth, no TLS, plain HTTP on loopback.**

On activation, orient yourself immediately:

```bash
AV="${AGENTSVIEW_URL:-http://127.0.0.1:8081}"
curl -s "$AV/api/v1/stats"     # {"session_count":N,...} => API is up
```

If it is not reachable, ask the user for the real URL or check
`systemctl status agentsview` — do **not** assume the port.

## Core facts

- Base URL: `http://127.0.0.1:8081` by default. Override with env
  `AGENTSVIEW_URL`. In examples below, `$AV` is that base URL.
- **Unknown paths return HTTP 200 with the web-app HTML**, not a 404. Always
  validate the response is JSON (e.g. `head -c 1` is `{`) before parsing.
- Response schemas are **additive-only**: new fields appear, old fields are
  never renamed/removed. Unknown fields are safe to ignore.
- **One-shot and automated sessions are excluded by default** from
  `/api/v1/sessions`. Add `&include_one_shot=true` / `&include_automated=true`
  to see them.
- `limit` caps: 500 on sessions, 500 on search (defaults 50). Paginate with
  `cursor` + `next_cursor`.
- Session IDs are agent-prefixed strings, e.g. `pi:01a0e2b2-...`,
  `codex:<uuid>`. URL-encode them if they contain special chars.
- `git_branch` filter is **not** a branch name — it is the opaque `token`
  returned by `GET /api/v1/branches` (URL-encode it).
- A CLI mirror exists at `agentsview` (installed at
  `~/.local/bin/agentsview`, currently v0.44.0) — see the *CLI reference*
  section below. Any HTTP endpoint has a CLI equivalent, e.g.
  `agentsview session list --server $AV --project kwisatz --json`.
  Prefer the HTTP API for scripting; use the CLI for `insight generate`,
  `stats`, and archive maintenance.
- `agentsview openapi` prints the full **OpenAPI 3.1 schema** of the HTTP API
  — the authoritative reference for exact parameters/response shapes.
- `agentsview mcp` runs a **read-only MCP server** (stdio) exposing session
  retrieval tools (see CLI reference) — an alternative to raw HTTP for agents.

## Endpoints

### Archive overview

| Endpoint | Returns |
| --- | --- |
| `GET /api/v1/stats` | `{session_count, message_count, project_count, machine_count, earliest_session}` |
| `GET /api/v1/projects` | `[{name, session_count}]` |
| `GET /api/v1/agents` | `[{name, session_count}]` |
| `GET /api/v1/machines` | `{machines[], machine_labels{}, machine_aliases{}}` |
| `GET /api/v1/branches` | `[{project, branch, token}]` — token for `git_branch` filter |

### Session list

`GET /api/v1/sessions` → `{sessions[], next_cursor, total, machine_labels{}}`

Query params:

| Param | Notes |
| --- | --- |
| `project`, `exclude_project` | exact project name |
| `agent`, `machine` | exact name / machine key |
| `git_branch` | opaque token from `/api/v1/branches` |
| `date` | `YYYY-MM-DD` (activity overlap) |
| `date_from`, `date_to` | range, `YYYY-MM-DD` |
| `active_since` | RFC3339 timestamp ("recently active") |
| `sort` | e.g. `messages:desc,started:asc` or just `health` |
| `reverse` | flip default sort order |
| `limit`, `cursor` | default 50, max 500 |
| `include_one_shot`, `include_automated` | `true` to include hidden categories |
| `include_source` | add each session's `file_path` (raw source location) |

Each session row already carries the key analysis fields:
`id, project, machine, agent, first_message, started_at, ended_at,
message_count, user_message_count, total_output_tokens, peak_context_tokens,
is_automated, tool_failure_signal_count, tool_retry_count, edit_churn_count,
consecutive_failure_max, outcome, outcome_confidence, ended_with_role,
final_failure_streak, compaction_count, mid_task_compaction_count,
health_score, health_grade (A–F), secret_leak_count, cwd`.

Useful recipes:

```bash
# 5 most recent sessions for a project
curl -s "$AV/api/v1/sessions?project=kwisatz&limit=5"

# sessions active in the last 15 min (resume candidates)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -s -G "$AV/api/v1/sessions" --data-urlencode "active_since=$NOW"

# worst-health sessions
curl -s "$AV/api/v1/sessions?sort=health&limit=10"
```

### Session detail

`GET /api/v1/sessions/{id}` — same fields as the list row **plus**
`quality_signals` (short-prompt count, unstructured-output signals, ...),
`transcript_revision`, `created_at`.

### Messages

`GET /api/v1/sessions/{id}/messages`

- Windowed: `?from=N&limit=M&direction=asc|desc` (`from` omitted = start of
  session for asc, newest page for desc)
- Around a point: `?around=N&before=M&after=M&role=user,assistant`

Message fields include `ordinal, role, content, thinking_text, has_thinking,
has_tool_use, content_length, model, context_tokens, output_tokens,
is_system, is_sidechain, is_compact_boundary, timestamp`.

### Tool calls

`GET /api/v1/sessions/{id}/tool-calls` (hyphen!) → `{tool_calls[], count}`

Fields: `ordinal, timestamp, tool_use_id, tool_name, category, input_json
(string — usually serialized JSON, sometimes plain text), skill_name,
subagent_session_id, result_length`.

### Usage & cost

`GET /api/v1/sessions/{id}/usage` → `{total_output_tokens,
peak_context_tokens, has_token_data, cost:{microdollars}, has_cost,
models[], unpriced_models[], breakdown[]}`. Cost is in microdollars; many
local models are unpriced (`has_cost=false`).

### Transcript export

- `GET /api/v1/sessions/{id}/md` — Markdown transcript (best for handing
  session context to another agent). `?depth=1` inlines direct child
  (subagent) sessions, `?depth=all` the full tree.
- `GET /api/v1/sessions/{id}/export` — standalone HTML.

```bash
curl -s "$AV/api/v1/sessions/$SID/md?depth=all" -o session-context.md
```

### Content search

`GET /api/v1/search/content` — substring (default), RE2 regex, FTS5, semantic,
or hybrid search across message bodies, tool inputs, and tool results.

| Param | Notes |
| --- | --- |
| `pattern` | required |
| `regex`, `fts`, `semantic`, `hybrid` | mode selectors, mutually exclusive; default substring |
| `in` | `messages,tool_input,tool_result` (default all) |
| `exclude_system` | drop system messages |
| `limit`, `cursor` | default 50, max 500 |
| project/agent/machine/date filters | same as session list |

`fts` is fastest but only covers message bodies; substring/regex also walk
tool I/O. Semantic/hybrid need an embedding index configured.

Match fields: `session_id, project, agent, location (message|tool_input|tool_result),
role, ordinal, ordinal_range, timestamp, snippet, tool_name?` — follow up by
fetching `messages?around=<ordinal>` for context.

### Trends

`GET /api/v1/trends/terms` — time-bucketed message counts per term.

- `term=` **required, repeatable** (comma-lists are also accepted),
  e.g. `term=project&term=agent`
- `from`, `to` — `YYYY-MM-DD`; `granularity=day|week|month`
- filters: `project, agent, machine` (comma-separated lists)

Returns `{granularity, from, to, message_count, buckets:[{date,
message_count}], series:[{term, variants, ...}]}`.

### Insights (AI-generated analyses)

Stored AI summaries/analyses of sessions (types like `daily_activity`,
`agent_analysis`):

- `GET /api/v1/insights` → `{insights[]}` — fields `id, type, date_from,
  date_to, project, agent, prompt, content (markdown)`
- `GET /api/v1/insights/{id}`

Generation is driven by the CLI (HTTP `POST /api/v1/insights/generate` is
gated/403 on this install): use `agentsview insight ...` (see
`agentsview insight --help`).

### Upload

`POST /api/v1/sessions/upload?project=<name>` — multipart form field `file`
with a session JSONL from another machine. `409` if the replacement would
lose messages (add `allow_shorter=true` to force).

```bash
curl -F "file=@session.jsonl" "$AV/api/v1/sessions/upload?project=myapp"
```

## Multi-machine collection

AgentsView keeps a local SQLite archive per machine; every session row carries
a **machine key** (the machine's installation ID — see
`~/.agentsview/telemetry-install-id`, stable across network/hostname
changes). There are four supported ways to aggregate sessions from several
machines into one view. **Pick one primary path; don't mix transports for
the same machine, or you will get duplicate sessions.**

| Mechanism | Direction | When to use |
| --- | --- | --- |
| HTTP remote sync (`[[remote_hosts]]`) | collector *pulls* from peer daemons | **Recommended.** Always-on peer daemons on a private network (Tailscale/LAN) |
| PostgreSQL shared mirror (`pg push` / `pg serve`) | each machine *pushes* to one DB | Team dashboard; many machines; no need to reach peers |
| Filesystem / S3 sources (`[[session_sources]]`, `s3://`) | files *copied* to the collector | Peers are offline/ephemeral (build VMs, containers); object storage as drop zone |
| Manual API upload (`POST /api/v1/sessions/upload`) | one-off | A single session file, no setup |

### 1. HTTP remote sync (recommended)

One machine acts as **collector**; each peer runs an AgentsView daemon.

**On each peer** (`~/.agentsview/config.toml`) — expose the daemon persistently:

```toml
host = "0.0.0.0"          # serve binds 127.0.0.1 by default
require_auth = true        # remote sync always sends a bearer token
daemon_idle_timeout = "0s" # detached daemon must not self-exit when idle
local_machine_name = "devbox1"
```

Then `agentsview daemon start` (or `daemon restart` after config changes).
Supervised daemons (systemd/launchd/Docker/foreground) never idle-exit.

**On the collector** (`~/.agentsview/config.toml`):

```toml
[[remote_hosts]]
host = "devbox1"                    # unique, stable — namespaces imported session IDs
transport = "http"                  # default is ssh (deprecated)
url = "http://devbox1.tailnet.ts.net:8080"
token = "<remote-daemon-token>"     # required for http transport
interval = "5m"                     # optional: periodic sync; omit for manual only
```

- Bare `agentsview sync` runs the local sync, then fans out to every
  configured host; a failure on one host is logged and the run continues
  (non-zero exit if any host failed). `agentsview sync --host devbox1`
syncs just that host.
- The SSH transport (`transport = "ssh"`, `user`, `port`) still works but is
  **deprecated** (critical fixes only); it needs passwordless SSH keys.
- Both sides must use the same remote-sync protocol version; after upgrading
  one host, upgrade the other before syncing again.
- Changing a host's `host =` value can duplicate sessions; reusing it for a
different machine can reuse stale state. Keep names stable.

### 2. PostgreSQL shared mirror (team dashboard)

Each machine keeps its local SQLite and **pushes one-way** (SQLite → PG) to a
shared PostgreSQL database; one server serves a read-only unified view.

**Per machine** (`~/.agentsview/config.toml`):

```toml
local_machine_name = "Laptop"   # display label; sessions keep the installation ID

[pg]
url = "postgres://user:pass@host:5432/dbname?sslmode=require"   # 0600 perms!
# projects = ["alpha"]            # optional push filter (or exclude_projects)
```

```bash
agentsview pg push            # one-shot push
agentsview pg push --watch    # continuous (foreground)
agentsview pg service install # background service (systemd --user / launchd)
agentsview pg status          # last push + totals
```

**Dashboard server:**

```bash
agentsview pg serve                                   # local, read-only, :8080
agentsview pg serve --host 0.0.0.0                    # LAN — set require_auth = true first!
agentsview pg serve --host 0.0.0.0 --base-path /agentsview \
  --public-url https://console.example.com --public-origin http://agentsview:8080
```

The read-only UI/API serves the same `/api/v1/*` endpoints from PostgreSQL
(sessions from all machines in one view, filter by machine). Limitations:
sync is one-way; `agentsview prune` deletes do **not** propagate to PG (SQL
DELETE there); no uploads/file watching in `pg serve`.

### 3. Filesystem / S3 sources

For machines whose session files you simply copy over (rsync/scp or object
storage) instead of reaching a daemon:

```toml
# Directory produced on another machine, now present locally:
[[session_sources]]
agent = "claude"   # one of claude, codex, cursor, icodemate (s3) / agent id
dir = "/srv/session-archive/buildbox/claude"
machine = "<peer installation ID from its ~/.agentsview/telemetry-install-id>"

# Object-storage drop zone (claude/codex/cursor/icodemate):
[agents.codex]
dirs = ["~/.codex/sessions", "s3://agent-archive/devbox1/raw/codex"]
```

- `machine` must be the **peer's** installation ID for remote roots; omit it
  for local roots (uses this installation's ID). Labels/aliases do not make
  a source local.
- S3 layout convention: `s3://bucket/<machine>/raw/<agent>/...` — the path
  segment before `raw` becomes the machine label. Non-loopback `http://` S3
  endpoints need `AGENTSVIEW_ALLOW_INSECURE_S3_ENDPOINT=true` (trusted LANs only).
- Machine attribution is captured at first ingest; changing `machine` later
  relabels only newly discovered sessions.

`agentsview sync --target <folder>` additionally exchanges normalized session
artifacts with a trusted folder (see `agentsview sync --help`).

### 4. Machine identity, labels, and verification

- **Installation ID** (`~/.agentsview/telemetry-install-id`) = the machine
  key; a fresh data dir creates a new ID, copying the dir copies the
  identity. Select machines unambiguously by ID, not display label.
- **Display label**: `local_machine_name` in config + `agentsview daemon
  restart`. Equal labels do **not** merge machines.
- Verify aggregation worked:

```bash
curl -s "$AV/api/v1/machines"        # keys, machine_labels{}, machine_aliases{}
curl -s "$AV/api/v1/sessions?machine=<key>&limit=5"   # filter by machine
```

- `GET /api/v1/stats` counts span all machines; `machine_count` > 1 confirms
  multi-machine ingestion.

## CLI reference (`agentsview`, v0.44.0)

Global flags on all read commands: `--json` (alias `--format json`),
`--server <url>` (explicit daemon, e.g. `$AV`), `--server-token-file <path>`
(bearer token for explicit servers), `--pg` (read configured PostgreSQL).
Without `--server`, commands attach to the local daemon (or start it).

### Session commands (mirror the HTTP endpoints)

```
agentsview session list [flags]              # same filters as GET /api/v1/sessions, plus:
  --resume                          # only sessions active in last 15 min, newest first
  --since 12h|14d|2w|3m|1y|YYYY-MM-DD        # relative recency (m = months!)
  --sort recent,started,messages,user-messages,output-tokens,peak-context,\
          failures,retries,edit-churn,compactions,context-pressure,health,secrets,id
  #   each key optional :asc/:desc; -r/--reverse flips default direction
  --health-grade A,B        --outcome success,failure,...
  --min-messages N          --max-messages N
  --min-user-messages N     --min-tool-failures N   # 0 is a valid filter
  --has-secret              # only sessions with detected secret leaks
  --include-children        # include subagent/child sessions

agentsview session get <id>                    # metadata + signals
agentsview session messages <id> [flags]       # --from/--limit/--direction/--around/--before/--after/--role
agentsview session search <pattern> [flags]    # --regex --fts --semantic --hybrid --in --context N
                                               # --exclude-session <id> (repeatable) --reveal
agentsview session tool-calls <id>             # mirror of /api/v1/sessions/{id}/tool-calls
agentsview session usage <id> [--own-only]     # totals include subagent transcripts; --own-only excludes them
agentsview session export <id>                 # raw source JSONL to stdout (local only, no --server)
agentsview session sync <path-or-id>           # parse/insert one session, blocks until indexed
agentsview session watch <id>                  # stream NDJSON events (session_updated, heartbeat)
```

### Analytics & reporting (no HTTP equivalent — CLI only)

```
agentsview stats --json --since 28d [--until YYYY-MM-DD] [--agent X] [--include-project P]
  # window-scoped workspace analytics (schema v2, EXPERIMENTAL — parse defensively):
  # totals, duration/outcome/health distributions, per-project and per-agent breakdowns
  # --include-git-outcomes adds commits/LOC/files; --include-github-outcomes adds PR stats via gh
agentsview usage daily --json [--since 28d] [--breakdown] [--all]   # daily cost summary
agentsview health [session-id] [--limit N]    # recent sessions w/ grade+outcome, or one session's signals
agentsview secrets list --json [--confidence definite|candidate|all] [--reveal]
  # detected secret leaks (redacted by default)
agentsview token-use <id>                     # token usage for one session (JSON)
```

### Insights (AI-generated analyses)

```
agentsview insight generate --type daily_activity --date-from 2026-09-20 --date-to 2026-09-26
agentsview insight generate --type agent_analysis --session-id <id> [--prompt "focus on ..."]
  # --project, --agent, --automated-scope human|all|automated, --timezone
agentsview insight list [--json]   /   agentsview insight get <id>
```

### Archive & server maintenance

```
agentsview sync [--host <name>] [--full]      # refresh local (+configured remote_hosts) archive
agentsview serve | serve status | serve stop  # foreground UI server / state
agentsview daemon start|status|restart|stop   # detached writable daemon
agentsview prune                              # delete sessions matching filters (no undo)
agentsview db compact | db adopt-machine      # archive maintenance
agentsview doctor                             # support diagnostics
```

### Integrations

```
agentsview mcp                    # read-only MCP server (stdio) with tools:
                                  # search_sessions, list_sessions, get_session_overview,
                                  # get_messages, search_content, get_usage_summary, query_recall
                                  # MCP client config: {"mcpServers":{"agentsview":{"command":"agentsview","args":["mcp"]}}}
                                  # (optionally args ["mcp","--server",URL] for a remote daemon)
agentsview openapi                # print full OpenAPI 3.1 schema of the HTTP API
agentsview skills list | skills install
                                  # official companion skill `agentsview-finding-history` for
                                  # Claude Code / generic agents harnesses (complements this skill)
agentsview update                 # self-update
```

Key env vars: `AGENTSVIEW_DATA_DIR` (default `~/.agentsview/`),
`AGENTSVIEW_NO_DAEMON=1` (never auto-start a daemon in scripts),
`AGENTSVIEW_PG_URL` / `AGENTSVIEW_PG_MACHINE` / `AGENTSVIEW_PG_SCHEMA`.

## Analysis workflows

**"What did my agents do recently?"**
`/stats` for scale → `/sessions?limit=20` (default sort = recency) → for
interesting IDs, `/sessions/{id}` then `/md` for the actual content.

**"Find the session where we discussed X / the agent ran command Y"**
`/search/content?pattern=...` (use `regex` mode for exact commands,
`in=tool_input` to restrict) → open the hit's session with
`/messages?around=<ordinal>`.

**"Which sessions were problematic?"**
`/sessions?sort=health&limit=20` — inspect `health_grade`,
`outcome`/`outcome_confidence`, `consecutive_failure_max`,
`tool_failure_signal_count`, `mid_task_compaction_count`,
`secret_leak_count`. Drill in with `/tool-calls` to see the failing calls.

**"Token/cost report"**
List sessions (rows carry `total_output_tokens`, `peak_context_tokens`),
sum/aggregate in jq; per-session detail via `/sessions/{id}/usage`.

**"Trend over time"**
`/trends/terms?term=agent&granularity=day&from=...&to=...` for activity per
agent/project/machine.

**Hand a past session to a new agent**
`curl -s "$AV/api/v1/sessions/$SID/md?depth=all" -o ctx.md` and attach `ctx.md`.

### jq tip

Responses are JSON; filter compactly, e.g.:

```bash
curl -s "$AV/api/v1/sessions?project=kwisatz&limit=50" | jq -r '
  .sessions[] | [.started_at, .health_grade, .outcome, .message_count, .id] | @tsv'
```
