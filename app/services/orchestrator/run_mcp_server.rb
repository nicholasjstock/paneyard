module Orchestrator
  # The whole MCP surface a run session gets. One flat tool set, because
  # there are no roles any more -- a session does the entire job, so it needs
  # everything or nothing.
  #
  # This is deliberately small (down from thirty). Anything a real
  # interactive CLI can already do for itself -- reading files, running
  # commands, editing code, starting a dev server -- is its own business now
  # that it runs with full access to its own worktree. What remains is only
  # what Rails alone knows or owns: how the run reports its result, the
  # run-scoped artifact store, workspace-scoped env vars a future run's
  # process needs, and queuing/inspecting runs (shared with AdminMcpServer,
  # since a session spinning off follow-up work or checking a sibling run is
  # the same operation an external MCP client does through /mcp/admin).
  module RunMcpServer
    module_function

    TOOLS = [
      ::McpTools::ReportIdleTool,
      ::McpTools::WriteWorkflowArtifactTool,
      ::McpTools::ReadWorkflowArtifactTool,
      ::McpTools::RecordWorkspaceEnvVarTool,
      ::McpTools::QueueRunTool,
      ::McpTools::ListRunsTool,
      ::McpTools::GetRunTool,
      ::McpTools::ListWorkspacesTool
    ].freeze

    # Belt and braces: clients that surface server instructions (Claude Code
    # does) get a one-paragraph map. The lifecycle itself lives in RunPrompt,
    # because not every driver is known to show these.
    INSTRUCTIONS = "Orchestrator tools for an agent session. Call report_idle every time you stop working; the " \
      "others are optional, e.g. queue_run / list_runs / get_run / list_workspaces for other jobs, and " \
      "record_workspace_env_var to save an env fix for future jobs in this workspace. Files, shell and git are " \
      "yours to do directly; there are no tools for them.".freeze

    def build(server_context:)
      MCP::Server.new(
        name: "workflow",
        title: "Workflow Run",
        version: "0.1.0",
        instructions: INSTRUCTIONS,
        server_context:,
        tools: TOOLS
      )
    end
  end
end
