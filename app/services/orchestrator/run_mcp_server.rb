module Orchestrator
  # The whole MCP surface a run session gets. One flat tool set, because
  # there are no roles any more -- a session does the entire job, so it needs
  # everything or nothing.
  #
  # This is deliberately small (eight tools, down from thirty). Anything a real
  # interactive CLI can already do for itself -- reading files, running
  # commands, editing code, starting a dev server -- is its own business now
  # that it runs with full access to its own worktree. What remains is only
  # what Rails alone knows or owns: how the run reports its result, the
  # run-scoped artifact store, and the workspace knowledge that outlives any
  # single run.
  module RunMcpServer
    module_function

    TOOLS = [
      ::McpTools::PingTool,
      ::McpTools::ReportIdleTool,
      ::McpTools::WriteWorkflowArtifactTool,
      ::McpTools::ReadWorkflowArtifactTool,
      ::McpTools::GetProjectMemoryTool,
      ::McpTools::RecordProjectMemoryEntryTool,
      ::McpTools::RecordWorkspaceEnvVarTool,
      ::McpTools::RecordProjectSetupTool
    ].freeze

    def build(server_context:)
      MCP::Server.new(
        name: "workflow",
        title: "Workflow Run",
        version: "0.1.0",
        server_context:,
        tools: TOOLS
      )
    end
  end
end
