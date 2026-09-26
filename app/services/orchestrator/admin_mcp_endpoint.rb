module Orchestrator
  # Mounted at /mcp/admin. Unlike /mcp/run (tokenized per run session, dead
  # the moment that session ends), this is a standing, unauthenticated
  # surface for the operator's own external MCP clients -- their everyday
  # Claude Code session, principally -- to queue and inspect runs across
  # every registered workspace. It carries no more auth than the rest of
  # this app: Puma binds 127.0.0.1 only, and "no auth in v1 (single-user
  # local tool)" is this app's accepted trust boundary everywhere else too
  # (ApplicationController#current_operator).
  #
  # One shared transport is enough here (unlike RunMcpEndpoint's
  # per-session cache): every caller gets the same tool set and the same
  # (empty) server_context, so there is nothing to key a cache on. The
  # transport itself still tracks each connecting MCP client's own
  # session/stream internally.
  class AdminMcpEndpoint
    def initialize
      @transport = MCP::Server::Transports::StreamableHTTPTransport.new(AdminMcpServer.build)
    end

    def call(env)
      @transport.call(env)
    end
  end
end
