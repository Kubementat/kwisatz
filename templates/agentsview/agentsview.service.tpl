# Managed by kwisatz tasks/setup-agentsview.sh -- see docs/research/agentsview.md
# The bearer token is NOT in this unit; it is read by agentsview from
# config.toml (mode 600) in the data dir. The optional insight-generation API
# key is also secret-free here: systemd sources it from insights.env (mode 600)
# in the data dir (leading '-' = no error when the file is absent, i.e. when
# insights are not configured).
[Unit]
Description=agentsview session log viewer and API server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Runs as the invoking user: agentsview auto-detects that user's agent logs
# (~/.claude/projects, ~/.codex/sessions, ~/.pi/agent/sessions, ...).
User=${AGENTSVIEW_SERVICE_USER}
Environment=AGENTSVIEW_TELEMETRY_ENABLED=0
Environment=AGENTSVIEW_DATA_DIR=${AGENTSVIEW_DATA_DIR}
EnvironmentFile=-${AGENTSVIEW_DATA_DIR}/insights.env
ExecStart=${AGENTSVIEW_BIN_DIR}/agentsview serve --host ${AGENTSVIEW_HOST} --port ${AGENTSVIEW_PORT} --no-browser
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
