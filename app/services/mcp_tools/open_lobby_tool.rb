module McpTools
  # Opens a workspace's lobby for the herdr plugin's lobby action or the
  # operator's own agent. Orchestrator::LobbyOpen does the work.
  #
  # Admin-only: it switches the operator's own checkout, which is the
  # operator's call, never a run session's.
  class OpenLobbyTool < MCP::Tool
    tool_name "open_lobby"
    description "Open the workspace's lobby: the operator's own agent session on the repository's checkout (not " \
      "a worktree), connected to this endpoint so it can queue jobs, read their reports and merge their branches. " \
      "It holds no job slot and is given no task; the operator types to it first. With no branch, it opens on the " \
      "branch the checkout has checked out, switching nothing. With one, the checkout is switched to it first, only " \
      "if it has no uncommitted changes to tracked files; a branch only origin has is fetched. For a pull request, " \
      "pass its head branch (e.g. from `gh pr view <number> --json headRefName`); a PR from a fork is not " \
      "supported. If the lobby is already open (on that branch, or anywhere when no branch is given), it is " \
      "returned as already_open; if it is open on another branch, this is refused until its agent is gone. Only do this when the operator asks. workspace is required."
    input_schema(
      properties: {
        workspace: { type: "string", description: "Workspace name (list_workspaces)." },
        branch: { type: "string", description: "Branch to open the lobby on (default: whatever the checkout has checked out, unswitched)." },
        driver: { type: "string", enum: Run::LAUNCHER_VARIANTS, description: "Which agent to start (default claude)." },
        model: { type: "string", description: "Model id for that agent's CLI (default: the driver's default model)." }
      },
      required: %w[workspace]
    )

    def self.call(workspace:, server_context:, branch: nil, driver: nil, model: nil)
      target = WorkspaceResolution.resolve!(server_context:, workspace:, explicit: true)
      opened = Orchestrator::LobbyOpen.call(target, branch:, driver:, model:)
      lobby = opened.fetch(:lobby)

      ToolResponse.structured(
        state: opened.fetch(:state),
        workspace: target.name,
        repository_path: target.repository_path,
        branch: lobby.branch,
        switched_from: opened.fetch(:switched_from),
        herdr_workspace: lobby.herdr_workspace_id,
        driver: lobby.driver,
        model: lobby.model
      )
    rescue Orchestrator::LobbyOpen::Busy => error
      ToolResponse.error(error.message, code: "lobby_busy")
    rescue Orchestrator::Runner::Error => error
      ToolResponse.error(error.message, code: "lobby_failed")
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end
  end
end
