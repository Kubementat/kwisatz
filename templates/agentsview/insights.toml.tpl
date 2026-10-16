
# LLM-generated insights (agentsview insight generate). Generation runs inside
# the agentsview daemon, which POSTs the transcript-derived prompt to this
# OpenAI-compatible chat endpoint.
#
# api_key_env names the ENVIRONMENT VARIABLE the daemon reads -- the key itself
# stays out of this file. Systemd injects it from
# ${AGENTSVIEW_DATA_DIR}/insights.env (mode 600) via EnvironmentFile in
# agentsview.service, because api_key_env resolves against the daemon's
# environment, not the caller's shell.
[insights]
endpoint = "${AGENTSVIEW_INSIGHTS_URL}"
model = "${AGENTSVIEW_INSIGHTS_MODEL}"
timeout = "${AGENTSVIEW_INSIGHTS_TIMEOUT}"
allow_http = ${AGENTSVIEW_INSIGHTS_ALLOW_HTTP}
${AGENTSVIEW_INSIGHTS_API_KEY_ENV_LINE}
