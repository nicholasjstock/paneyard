module Orchestrator
  # Mounted at /mcp/admin. Unlike /mcp/run (tokenized per run session, dead
  # the moment that session ends), this is a standing, unauthenticated
  # surface for the operator's own external MCP clients -- their everyday
  # Claude Code session, principally -- to queue and inspect runs across
  # every registered workspace. It carries no more auth than the rest of
  # this app: Puma binds 127.0.0.1 only, production answers loopback Host
  # names only (SECURITY.md), and "no auth in v1 (single-user local tool)"
  # is this app's accepted trust boundary everywhere else too
  # (ApplicationController#current_operator).
  #
  # One shared transport is enough here: every caller gets the same tool set
  # and the same (empty) server_context. It is stateless (McpTransport), so
  # it keeps no per-client sessions either: an operator's client stays
  # connected across idle hours and Paneyard restarts.
  class AdminMcpEndpoint
    def initialize
      @transport = McpTransport.build(AdminMcpServer.build)
    end

    def call(env)
      @transport.call(env)
    end
  end
end
