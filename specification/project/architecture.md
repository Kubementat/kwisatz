# Architecture

## Tech Stack

- **Language:** Bash (primary); the orchestrator is a small Python [pyinfra](https://docs.pyinfra.com/en/3.x/) deploy, run via `uv`
- **Configuration formats:** Environment variables (primary), with YAML, JSON, or `.env` files where individual components require them
- **Target OS:** Ubuntu

## System Structure

```text
repository root
├── run-setup.sh          # Entrypoint: thin wrapper around `uv run pyinfra @local deploy.py` (apply | status)
├── deploy.py             # pyinfra deploy: runs the task scripts enabled in machine-config.yml, in config order
├── pyproject.toml        # Python dependencies of the orchestrator (pyinfra, pyyaml), resolved by uv
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

1. The user runs the **entrypoint** (`./run-setup.sh apply`, or pyinfra directly: `uv run pyinfra @local deploy.py -y -vvv`).
2. `deploy.py` emits one pyinfra `server.shell` operation per enabled script in `machine-config.yml`, in config order.
3. Each task script runs as its own `bash` process with `INTERACTIVE=false` plus its configured `env`/`args` and stdin from `/dev/null`; the run stops at the first failing script.
4. **Utility scripts** are independent and run separately by the user after provisioning.

## Components

### Entrypoints
- One thin orchestration layer (`deploy.py`, wrapped by `run-setup.sh`); which task scripts run, and in what order, is defined by `machine-config.yml`.

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
