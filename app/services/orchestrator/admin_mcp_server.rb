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
  # register_workspace, update_workspace_layout and close_session are the tools
  # only this endpoint has beyond ping: changing what Paneyard manages or what
  # panes a run starts, or ending a session, is the operator's decision, while
  # a run session works inside the workspace it was given.
  module AdminMcpServer
    module_function

    TOOLS = [
      ::McpTools::PingTool,
      ::McpTools::QueueRunTool,
      ::McpTools::ListRunsTool,
      ::McpTools::GetRunTool,
      ::McpTools::ListWorkspacesTool,
      ::McpTools::RegisterWorkspaceTool,
      ::McpTools::UpdateWorkspaceLayoutTool,
      ::McpTools::CloseSessionTool
    ].freeze

    # Clients that surface server instructions (Claude Code does) get the one
    # workflow that is easy to get wrong from outside a run: which workspace.
    INSTRUCTIONS = "Paneyard queues jobs for agent sessions, each in its own worktree of a registered workspace's " \
      "repository. To queue a job for the repository you are working in: call list_workspaces and find the " \
      "workspace whose repositoryPath is that repository (its main checkout, if you are in a linked worktree); if " \
      "there is none, call register_workspace with path set to the repository's directory and follow any fixes it " \
      "returns before calling it again; then call queue_run with that workspace. queue_run always needs workspace " \
      "from here. A job starts from the workspace's defaultBaseBranch; pass baseBranch to start from another local " \
      "branch, such as the one you are on.".freeze

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
