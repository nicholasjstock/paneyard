# Path to the workflow-orchestrator repo (where bin/supervisor_launcher*
# and scripts/workflow-mcp-http.ts live) -- ops/ is a subdirectory of it by
# construction, but this stays overridable for a non-standard layout.
Rails.application.config.x.orchestrator_root = ENV.fetch("ORCHESTRATOR_ROOT") { Rails.root.parent.to_s }

# The project(s) being orchestrated (e.g. simple-retail-planner) are no
# longer a single global config value -- see the Workspace model. Each
# launched Run picks one explicitly and carries its root_path forward as
# Run#target_root.
