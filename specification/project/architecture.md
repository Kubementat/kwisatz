# Architecture

## Tech Stack

- **Language:** Bash (primary); the orchestrator is a small Python [pyinfra](https://docs.pyinfra.com/en/3.x/) deploy, run via `uv`
- **Configuration formats:** Environment variables (primary), with YAML, JSON, or `.env` files where individual components require them
- **Target OS:** Ubuntu

## System Structure

```text
repository root
├── kwisatz               # Zero-install entry point: `./kwisatz apply traefik` from a checkout
├── run-setup.sh          # Entrypoint: thin wrapper around `uv run pyinfra @local deploy.py` (apply | status)
├── deploy.py             # pyinfra adapter: one operation per enabled script, in config order
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

1. The user runs an **entry point**: `kwisatz apply` (or `./kwisatz apply traefik` for one
   target), `./run-setup.sh apply`, or pyinfra directly
   (`uv run pyinfra @local deploy.py -y -vvv`).
2. All three read the same `kwisatz.orchestrator` module, which decides *what* runs and
   *how*: the `.scripts.<name>` contract, the `enabled` spellings, `tasks/<name>.sh` versus
   `tasks/<name>.py`, and each task's command, env and stdin. `deploy.py` is the pyinfra
   adapter of that module; `kwisatz apply` is the direct-subprocess adapter of it.
3. Each task script runs as its own `bash` process with `INTERACTIVE=false` plus its
   configured `env`/`args` and stdin from `/dev/null`; the run stops at the first failing
   script.
4. **Utility scripts** are independent and run separately by the user after provisioning.

### The two execution paths and why parity is enforced

`kwisatz apply` executes a script directly (fast, TTY-capable, no pyinfra in the run path);
`run-setup.sh apply` / `deploy.py` run it through pyinfra. Both must hand the *same* argv,
environment and stdin to the same script, or "install one service" and "provision the box"
silently install different things. That is why `deploy.py` contains no contract of its own,
and why `tests/unit/test_conformance.py` asserts the `(command, env, stdin)` triple from both
paths as a release gate (`docs/features/kwisatz-cli-specification.md` R-ARCH-102).

Two decisions worth knowing before you change something here:

- **The package lives in `src/kwisatz/`, not in the repo root.** The spec asked for a
  root-level `kwisatz/` package *and* a root-level executable `./kwisatz` (R-ARCH-002/003);
  those two names collide, so the checkout keeps the executable at the root and the package
  under `src/`, which is also what lets `./kwisatz` work with `PYTHONPATH=src` before
  anything is installed.
- **`run-setup.sh` is unchanged and stays the documented batch entry point** (R-ARCH-103).
  The CLI is additive: it does not replace the pyinfra path, it re-implements the *same*
  contract on top of the same module.

## Components

### Entrypoints
- **`kwisatz`** — the operator/agent CLI: `apply`, `status`, `list`, `info`, `doctor`,
  `config`, `services`, `logs`, `state`, `models`, `run`, `commands`, `install`, `init`.
  Specification: `docs/features/kwisatz-cli-specification.md`; behaviors:
  `specification/features/kwisatz-cli/behaviors.md`.
- **`deploy.py`**, wrapped by **`run-setup.sh`** — the pyinfra path for a whole-machine run
  from CI or a bare checkout. Which task scripts run, and in what order, is defined by
  `machine-config.yml`; the contract itself lives in `kwisatz/orchestrator.py`, so both
  entry points cannot drift.

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
