module Orchestrator
  # The MCP surface a local, non-run MCP client gets -- principally an
  # operator's own everyday Claude Code session, registered as a remote MCP
  # server so they can queue and inspect runs from their coding agent.
  # Reuses the exact tool classes RunMcpServer also carries: queuing a run
  # or asking what's running is the same operation regardless of who is
  # asking, and McpTools::WorkspaceResolution is what lets the same tool
  # code serve a caller with no run of its own (falls back to the oldest
  # registered workspace, or an explicit `workspace:` argument).
  #
  # register_workspace, create_workspace, get_settings, update_settings,
  # update_workspace_layout, close_session,
  # reopen_session, update_run_dependencies and open_lobby are the tools only
  # this endpoint has beyond ping: changing what Paneyard manages or what panes
  # a run starts, ending a session or bringing one back, letting a run start
  # without the work it was queued after, starting a new project (which makes
  # a GitHub repository) or where projects go, or switching the operator's own
  # checkout for their lobby, is the operator's decision, while a run session
  # works inside the workspace it was given.
  module AdminMcpServer
    module_function

    TOOLS = [
      ::McpTools::PingTool,
      ::McpTools::QueueRunTool,
      ::McpTools::ListRunsTool,
      ::McpTools::GetRunTool,
      ::McpTools::ListWorkspacesTool,
      ::McpTools::ListModelsTool,
      ::McpTools::RegisterWorkspaceTool,
      ::McpTools::CreateWorkspaceTool,
      ::McpTools::GetSettingsTool,
      ::McpTools::UpdateSettingsTool,
      ::McpTools::UpdateWorkspaceLayoutTool,
      ::McpTools::CloseSessionTool,
      ::McpTools::ReopenSessionTool,
      ::McpTools::UpdateRunDependenciesTool,
      ::McpTools::OpenLobbyTool
    ].freeze

    # Clients that surface server instructions (Claude Code does) get the one
    # workflow that is easy to get wrong from outside a run: which workspace.
    INSTRUCTIONS = "Paneyard queues jobs for agent sessions, each in its own worktree of a registered workspace's " \
      "repository. To queue a job for the repository you are working in: call list_workspaces and find the " \
      "workspace whose repositoryPath is that repository (its main checkout, if you are in a linked worktree); if " \
      "there is none, call register_workspace with path set to the repository's directory and follow any fixes it " \
      "returns before calling it again; then call queue_run with that workspace. queue_run always needs workspace " \
      "from here. Pass baseBranch as the branch you have checked out (git branch --show-current) unless the " \
      "operator names another: the job starts from it and merges back into it. Leave it out only on a detached " \
      "HEAD, or when queueing into a workspace other than the repository you are in, and the job starts from the " \
      "workspace's defaultBaseBranch. When the operator asks to start a new project, or to set up one that is " \
      "not ready yet (a local directory or repository with no GitHub repository, or a GitHub repository not cloned " \
      "here), call create_workspace with its name (or path): it does only the missing steps -- directory, git " \
      "repository on main, GitHub repository, clone, push -- registers the workspace and returns it, ready for " \
      "queue_run; only do this when asked. If it says no projects directory is set, ask the operator where projects " \
      "go and save it with update_settings. Pass driver as the agent CLI you are " \
      "(claude or codex), and model as the model id you are running on if you know it, unless the operator names " \
      "others. When one job must build on another's work, queue it with after: [that job's runId] rather than " \
      "asking the operator to merge them in order; it waits, holding no slot, until that work is merged into the " \
      "shared baseBranch. A workspace's lobby (open_lobby) is the operator's own integration session on its " \
      "checkout; open one only when the operator asks.".freeze

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
