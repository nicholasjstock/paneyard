# Which half of Paneyard this process is (docs/multi-runner-plan.md).
#
#   orchestrator  the default: the database, the queue, both MCP endpoints,
#                 and the in-process local runner (bin/production).
#   runner        a runner-only process on a second machine (bin/runner): no
#                 queue, no recurring jobs, no MCP endpoints and no use of the
#                 orchestrator's database, only Orchestrator::Runner::Endpoint
#                 answering the orchestrator's Runner::Remote.
#
# Plain Ruby, needed by config/routes.rb and bin/runner, so
# config/application.rb requires it and the autoloader ignores it.
module PaneyardRole
  ENV_VAR = "PANEYARD_ROLE".freeze
  ROLES = %w[orchestrator runner].freeze

  module_function

  def current(env = ENV)
    role = env[ENV_VAR].to_s.strip
    role = "orchestrator" if role.empty?
    raise ArgumentError, "#{ENV_VAR} must be one of #{ROLES.join(', ')}, not #{role.inspect}" unless ROLES.include?(role)

    role
  end

  def runner?(env = ENV)
    current(env) == "runner"
  end
end
