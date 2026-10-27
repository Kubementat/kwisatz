# Architecture

## Tech Stack

- **Language:** Bash (primary); the orchestrator is a small Python [pyinfra](https://docs.pyinfra.com/en/3.x/) deploy, run via `uv`
- **Configuration formats:** Environment variables (primary), with YAML, JSON, or `.env` files where individual components require them
- **Target OS:** Ubuntu

## System Structure

```text
repository root
├── kwisatz               # Entrypoint: `./kwisatz apply traefik`, `./kwisatz apply`, `status`…
├── deploy.py             # pyinfra adapter: the engine — one operation per target, in config order
├── src/kwisatz/          # The CLI package: command table, plan, exec, checks, config, services
│   ├── cli.py            # `kwisatz <command>` — dispatch, flags, exit codes, the JSON envelope
│   ├── orchestrator.py   # THE execution contract: config, enabled, task command, env, plan
│   ├── exec.py           # subprocess runner: env, stdin, timeout, log capture
│   ├── config.py         # machine-config.yml round-trip (ruamel), atomic write, validate
│   ├── services.py       # what is running: /srv stacks, compose labels, systemd units
│   └── data/
│       ├── prerequisites.yml   # ordering + host-fact table (§6.5 of the CLI spec)
│       └── services.yml        # manager/unit hints discovery cannot infer
├── pyproject.toml        # Python dependencies (pyinfra, pyyaml, ruamel.yaml), resolved by uv
├── tasks/                   # Task scripts (one per component)
│   ├── setup-basics.sh
│   ├── setup-sshd.sh
│   ├── setup-docker.sh
│   ├── setup-lm-studio.sh
│   ├── configure-firewall.sh
│   └── ...
└── utilities/               # Standalone helper scripts
    └── ssh-port-forward.sh
```

The architecture follows a simple **linear model**:

1. The user runs **the CLI**: `kwisatz apply` (everything enabled, in config order) or
   `kwisatz apply <target>` (one service). The only way past it is pyinfra itself
   (`uv run pyinfra @local deploy.py -y -vvv`) — that is the engine, not a second entry point,
   and the CLI is the documented way in.
2. Both halves read the same `kwisatz.orchestrator` module, which decides *what* runs and
   *how*: the `.scripts.<name>` contract, the `enabled` spellings, `tasks/<name>.sh` versus
   `tasks/<name>.py`, and each task's command, env and stdin.
3. The CLI resolves the targets it will run, prints the plan, and then starts a **pyinfra
   deploy of the checkout** per target — `deploy.py -y -vvv --data config=<file>
   --data select=<name>`. So the command line, the environment (`INTERACTIVE=false`, then the
   config's `env:`, then `--env`), the `/dev/null` stdin and the masking of `env:` values are
   pyinfra's, in a single-target run and in a full one alike.
4. The run stops at the first failing target (or continues with `--keep-going`, exit `8`).
5. **Utility scripts** are independent and run separately by the user after provisioning.

### One engine, and how the contract is kept

`apply` does not execute task scripts itself; it runs `deploy.py`, which runs them. That was
the decision on the spec's open question (§16.1): staying on pyinfra is worth more than the
~1 s of deploy startup per target, and it removes the drift this section used to warn about —
"install one service" and "provision the box" cannot install different things any more,
because they go through the same operation. The contract itself still lives in exactly one
place (`kwisatz/orchestrator.py`), `deploy.py` contains none of it, and
`tests/unit/test_conformance.py` asserts the `(command, env, stdin)` triple plus the task
script's own ancestor chain, so a change that quietly execs the script without a deploy fails
the gate (`docs/features/kwisatz-cli-specification.md` R-ARCH-101/102).

Two paths deliberately stay direct script runs, because pyinfra cannot attach a terminal:
`kwisatz apply <target> --interactive`, and `kwisatz run <target> -- <args>` — the second is
the sanctioned way to use a script's own flags, exactly as running `tasks/<name>.sh` by hand
always was.

Two decisions worth knowing before you change something here:

- **The package lives in `src/kwisatz/`, not in the repo root.** The spec asked for a
  root-level `kwisatz/` package *and* a root-level executable `./kwisatz` (R-ARCH-002/003);
  those two names collide, so the checkout keeps the executable at the root and the package
  under `src/`, which is also what lets `./kwisatz` work with `PYTHONPATH=src` before
  anything is installed.
- **The CLI is the only wrapper** (R-ARCH-103): there is no script in front of it. The old
  `run-setup.sh` shim was translated away and deleted, so `apply`/`status` have one implementation
  and one set of exit codes (`behaviors.md` §7) — `status` on a broken config exits `3`, where a
  bare pyinfra run exited `1`.

## Components

### Entrypoints
- **`kwisatz`** — the operator/agent CLI: `apply`, `status`, `list`, `info`, `doctor`,
  `config`, `services`, `logs`, `state`, `models`, `run`, `commands`, `install`, `init`.
  Specification: `docs/features/kwisatz-cli-specification.md`; behaviors:
  `specification/features/kwisatz-cli/behaviors.md`.
- **`deploy.py`** — the pyinfra deploy that actually executes the tasks. `kwisatz apply` starts
  it per target (`-y -vvv --data select=`); a bare
  `uv run pyinfra @local deploy.py -y -vvv` (or CI) starts it once for the whole config. Which task
  scripts run, and in what order, is defined by `machine-config.yml`; the contract itself lives
  in `kwisatz/orchestrator.py`, so the CLI and the deploy cannot drift.

### Task Scripts
- Each script is responsible for exactly one component.
- Scripts are idempotent — they guard against re-execution using checks like `command -v`, `dpkg -l`, or file existence tests.
- Scripts communicate exclusively through environment variables.

### Utility Scripts
- Post-provisioning helpers that are not part of the setup flow.
- Run independently by the user as needed.

## External Integrations

Task scripts pull from external sources during provisioning:

Download URLs and versions are currently hardcoded with env var overrides. A future iteration may centralise these in a YAML configuration file.

## Deployment

The repository is cloned directly onto the target machine and executed locally:
There is no remote execution, CI/CD pipeline, or container wrapping the scripts themselves.
