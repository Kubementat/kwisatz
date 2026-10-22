#!/usr/bin/env bash
# run-setup.sh — DEPRECATED: the thin wrapper this script was is now the `kwisatz` CLI.
#
# It stays for one release so that old docs, CI jobs and muscle memory keep working, and
# it does not implement anything: it translates `apply`/`status` (and pyinfra's
# `--data config=<file>`) into the equivalent CLI call and execs it. Everything the
# operator used to get from this script — the plan, the env, the masking, the exit
# codes — comes from `kwisatz` now, and the exit codes are the CLI's table
# (`specification/features/kwisatz-cli/behaviors.md`), so `status` on a broken config
# exits 3, where pyinfra used to exit 1. Remove this file one release after it was
# deprecated; `tasks/<name>.sh` stays runnable by hand as always.
#
#   ./run-setup.sh apply [--data config=<file>]   ->  ./kwisatz apply [--config <file>]
#   ./run-setup.sh status [--data config=<file>]  ->  ./kwisatz status [--config <file>]
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: ./run-setup.sh apply|status [pyinfra args...]   (DEPRECATED — use ./kwisatz)

  apply    = ./kwisatz apply     run every enabled task script, in config order
  status   = ./kwisatz status    the plan, without running anything
  --data config=<file>  = ./kwisatz --config <file> ...

Use the CLI instead: it runs the same deploy.py, adds single-target apply
(`./kwisatz apply traefik`), and documents its exit codes in
specification/features/kwisatz-cli/behaviors.md.

To run one script by hand, with the script's own defaults, run it directly:
  INTERACTIVE=true ./tasks/<name>.sh
USAGE
}

case "${1:-}" in
  apply | status)
    command="$1"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

# translate only what pyinfra's --data could mean here; anything else is forwarded
# verbatim, so an unknown key fails loudly in the CLI instead of running nothing
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data)
      case "${2:-}" in
        config=*) extra+=(--config "${2#config=}") ;;
        *) extra+=(--data "$2") ;;
      esac
      shift 2
      ;;
    *)
      extra+=("$1")
      shift
      ;;
  esac
done

echo "run-setup.sh: DEPRECATED — run './kwisatz ${command}' instead." >&2
exec "${dir}/kwisatz" "${command}" "${extra[@]+"${extra[@]}"}"
