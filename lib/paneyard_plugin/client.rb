require_relative "../paneyard_sandbox/mcp_client"

module PaneyardPlugin
  # The plugin's view of a running daemon: its /mcp/admin tools, the same ones
  # an operator's own Claude Code uses, so the herdr surface adds no API of
  # its own. Results are the tools' structuredContent (camelCase keys).
  class Client
    Error = PaneyardSandbox::McpClient::Error

    def initialize(url)
      @mcp = PaneyardSandbox::McpClient.new("#{url}/mcp/admin", client_name: "paneyard-herdr-plugin")
    end

    def workspaces
      @mcp.call_tool("list_workspaces").fetch("workspaces")
    end

    # [workspace name, list_runs result] for every workspace.
    def runs(include_finished: true, limit: 20)
      workspaces.map do |workspace|
        listed = @mcp.call_tool("list_runs", workspace: workspace.fetch("name"), includeFinished: include_finished, limit:)
        [ workspace, listed ]
      end
    end

    def run(run_id, workspace:)
      @mcp.call_tool("get_run", runId: run_id, workspace:)
    end

    def queue(task:, workspace:, driver: nil)
      @mcp.call_tool("queue_run", task:, workspace:, **(driver ? { driver: } : {}))
    end

    def register(name:, root_path:)
      @mcp.call_tool("register_workspace", name:, rootPath: root_path)
    end

    def close(run_id, workspace:)
      @mcp.call_tool("close_session", runId: run_id, workspace:)
    end
  end
end
