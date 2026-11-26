module McpTools
  # The runner registry (RegisteredRunner): the machines a run can be queued
  # on, as queue_run's runner names them. Admin-only: which machine a job runs
  # on is the operator's call, and the herdr plugin's queue popup offers these.
  class ListRunnersTool < MCP::Tool
    tool_name "list_runners"
    description "List the runners (machines) runs can be queued on, by the names queue_run accepts as runner: " \
      "kind (local is this orchestrator's own machine), url, maxConcurrentRuns (its own cap beside the global one; " \
      "null: only the global cap), how many runs hold a slot on it, the workspaces checked out there, and whether " \
      "it is reachable."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      in_flight = Orchestrator::RunConcurrency.in_flight_by_runner
      local = RegisteredRunner.local
      checked_out = WorkspaceCheckout.joins(:workspace).order("workspaces.name").pluck(:runner_id, "workspaces.name")
        .group_by(&:first).transform_values { |rows| rows.map(&:last) }

      ToolResponse.structured(
        capacity: { limit: Orchestrator::RunConcurrency.limit, in_flight: in_flight.values.sum },
        runners: RegisteredRunner.order(:name).sort_by { |runner| runner == local ? 0 : 1 }.map do |runner|
          workspaces = runner.local? ? Workspace.order(:name).pluck(:name) : checked_out.fetch(runner.id, [])
          {
            name: runner.name,
            kind: runner.kind,
            url: runner.url,
            max_concurrent_runs: runner.max_concurrent_runs,
            in_flight: in_flight.fetch(runner.id, 0),
            workspaces:,
            **reachability(runner)
          }
        end
      )
    end

    # The local runner is this process. Another answers only if its runner
    # object can be had and says who it is.
    def self.reachability(runner)
      return { reachable: true } if runner.local?

      Orchestrator::Runner.for(runner).id
      { reachable: true }
    rescue Orchestrator::Runner::Error => error
      { reachable: false, unreachable_reason: error.message }
    end
  end
end
