# Path to the workflow-orchestrator repo (where bin/supervisor_launcher*
# and scripts/workflow-mcp-http.ts live) -- ops/ is a subdirectory of it by
# construction, but this stays overridable for a non-standard layout.
Rails.application.config.x.orchestrator_root = ENV.fetch("ORCHESTRATOR_ROOT") { Rails.root.parent.to_s }

# The project being orchestrated (e.g. simple-retail-planner) -- must match
# WORKFLOW_TARGET_ROOT on the running workflow-mcp-http.ts process, since
# that's what determines which WORKFLOW_STATE_DIR both sides read/write.
# Intentionally left nil if unset rather than guessing: LaunchRunJob raises
# a clear error at launch time instead of silently spawning a supervisor
# loop pointed at the wrong (or a made-up) target.
Rails.application.config.x.workflow_target_root = ENV["WORKFLOW_TARGET_ROOT"].presence
