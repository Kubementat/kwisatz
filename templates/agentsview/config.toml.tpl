# Managed by kwisatz tasks/setup-agentsview.sh -- see docs/research/agentsview.md
# auth_token lives here (mode 600 in a mode-700 data dir) because agentsview has
# no env-var alternative for it; it is read back from an existing config before
# a new one is generated, so re-runs never rotate it.
# The PostgreSQL URL stays out of TOML files: ${AGENTSVIEW_DATA_DIR}/pg.env (mode 600).
local_machine_name = "${AGENTSVIEW_MACHINE_NAME}"
disable_update_check = ${AGENTSVIEW_DISABLE_UPDATE_CHECK}
require_auth = true
auth_token = "${AGENTSVIEW_AUTH_TOKEN}"
