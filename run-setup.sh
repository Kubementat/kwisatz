#!/usr/bin/env bash
# run-setup.sh — thin wrapper around the pyinfra deploy (deploy.py). Requires uv.
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  apply)  flags=(-y -vvv) ;;
  status) flags=(--dry) ;;
  *) cat <<'USAGE'
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
USAGE
     [[ "${1:--h}" == -h || "${1:-}" == --help ]] && exit 0
     exit 2 ;;
esac
PATH="$PATH:$HOME/.local/bin"  # where the uv installer puts it; not on PATH before the next login
command -v uv >/dev/null || { echo "run-setup.sh: uv not found — install it: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2; exit 1; }
exec uv run --project "$dir" pyinfra @local "$dir/deploy.py" "${flags[@]}" "${@:2}"
