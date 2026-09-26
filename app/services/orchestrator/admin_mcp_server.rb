module Orchestrator
  # The MCP surface a local, non-run MCP client gets -- principally an
  # operator's own everyday Claude Code session, registered as a remote MCP
  # server so they can queue and inspect runs without opening the web UI.
  # Reuses the exact tool classes RunMcpServer also carries: queuing a run
  # or asking what's running is the same operation regardless of who is
  # asking, and McpTools::WorkspaceResolution is what lets the same tool
  # code serve a caller with no run of its own (falls back to the oldest
  # registered workspace, or an explicit `workspace:` argument).
  module AdminMcpServer
    module_function

    TOOLS = [
      ::McpTools::PingTool,
      ::McpTools::QueueRunTool,
      ::McpTools::ListRunsTool,
      ::McpTools::GetRunTool,
      ::McpTools::ListWorkspacesTool
    ].freeze

    def build
      MCP::Server.new(
        name: "workflow-admin",
        title: "Workflow Admin",
        version: "0.1.0",
        server_context: {},
        tools: TOOLS
      )
    end
  end
end
