module Orchestrator
  # The MCP surface a local, non-run MCP client gets -- principally an
  # operator's own everyday Claude Code session, registered as a remote MCP
  # server so they can queue and inspect runs without opening the web UI.
  # Reuses the exact tool classes RunMcpServer also carries: queuing a run
  # or asking what's running is the same operation regardless of who is
  # asking, and McpTools::WorkspaceResolution is what lets the same tool
  # code serve a caller with no run of its own (falls back to the oldest
  # registered workspace, or an explicit `workspace:` argument).
  #
  # register_workspace is the one tool only this endpoint has beyond ping:
  # adding a workspace is the operator's decision about what this instance
  # manages, while a run session works inside the workspace it was given.
  module AdminMcpServer
    module_function

    TOOLS = [
      ::McpTools::PingTool,
      ::McpTools::QueueRunTool,
      ::McpTools::ListRunsTool,
      ::McpTools::GetRunTool,
      ::McpTools::ListWorkspacesTool,
      ::McpTools::RegisterWorkspaceTool
    ].freeze

    # Clients that surface server instructions (Claude Code does) get the one
    # workflow that is easy to get wrong from outside a run: which workspace.
    INSTRUCTIONS = "Paneyard queues jobs for agent sessions, each in its own worktree of a registered workspace. " \
      "To queue a job for the repository you are working in: call list_workspaces and find the workspace whose " \
      "sourceRoot is that repository; if there is none, call register_workspace with rootPath set to " \
      "the repository's directory (it works out the workspace root) and follow any fixes it returns before " \
      "calling it again; then call queue_run with that workspace. queue_run always needs workspace from here.".freeze

    def build
      MCP::Server.new(
        name: "paneyard-admin",
        title: "Paneyard Admin",
        version: "0.1.0",
        instructions: INSTRUCTIONS,
        server_context: {},
        tools: TOOLS
      )
    end
  end
end
