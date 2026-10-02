Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "health#show", as: :rails_health_check

  # The MCP endpoint a run's interactive CLI session connects to --
  # Streamable HTTP, hosted inside this already-running process. Scoped and
  # tokenized per session (app/services/orchestrator/run_mcp_server.rb).
  mount Orchestrator::RunMcpEndpoint.new => "/mcp/run"

  # A standing MCP endpoint for the operator's own external MCP clients --
  # their everyday Claude Code session, principally -- to queue and inspect
  # runs from the operator's own MCP clients. Unauthenticated like the rest of this
  # app; see Orchestrator::AdminMcpEndpoint's own comment for why that's an
  # accepted trust boundary here, not an oversight.
  mount Orchestrator::AdminMcpEndpoint.new => "/mcp/admin"
end
