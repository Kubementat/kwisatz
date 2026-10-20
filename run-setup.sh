#!/usr/bin/env bash
# run-setup.sh — thin wrapper around the pyinfra deploy (deploy.py). Requires uv.
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: ./run-setup.sh apply|status [pyinfra args...]

  apply    run all enabled task scripts of the config, in config order;
           stops at the first failing script (exit 1)
  status   list the enabled task scripts without running anything

  --data config=<file>   use <file> instead of <repo>/machine-config.yml
  -h, --help             show this help

Requires uv:  curl -LsSf https://astral.sh/uv/install.sh | sh
Runs:         uv run pyinfra @local deploy.py -y -vvv   (apply)
              uv run pyinfra @local deploy.py --dry     (status)
Task scripts run with INTERACTIVE=false and stdin from /dev/null. For prompts
run one directly: INTERACTIVE=true tasks/<name>.sh

WARNING: apply runs pyinfra at -vvv, the only level that streams task output,
and that also echoes every command line. Values from a script's `env:` block
are printed as *MASKED* (pyinfra HiddenValue), but script names, `args:` and
all task output are printed verbatim. Treat machine-config.yml as secret-free:
the task scripts keep their own credentials in /srv/<service>/.env.
USAGE
}

case "${1:-}" in
  apply)  flags=(-y -vvv) ;;
  status) flags=(--dry) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
PATH="$PATH:$HOME/.local/bin"  # where the uv installer puts it; not on PATH before the next login
command -v uv >/dev/null || { echo "run-setup.sh: uv not found — install it: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2; exit 1; }
exec uv run --project "$dir" pyinfra @local "$dir/deploy.py" "${flags[@]}" "${@:2}"
