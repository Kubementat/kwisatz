[Unit]
Description=agentsview PostgreSQL push watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# AGENTSVIEW_PG_URL (contains credentials) is read from a mode-600 file, never written here.
EnvironmentFile=${AGENTSVIEW_DATA_DIR}/pg.env
Environment=AGENTSVIEW_TELEMETRY_ENABLED=0
Environment=AGENTSVIEW_DATA_DIR=${AGENTSVIEW_DATA_DIR}
ExecStart=${AGENTSVIEW_BIN_DIR}/agentsview pg push --watch
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
