module McpTools
  class TerminalSessionRunControlTool < MCP::Tool
    ACTIONS = %w[stop resume tick reconcile retry_handoff].freeze

    tool_name "control_workspace_run"
    description "Perform one workspace-scoped run operation. Use retry_handoff only for an interrupted fulfilled request."
    input_schema(
      properties: {
        runId: { type: "string" }, action: { type: "string", enum: ACTIONS },
        requestId: { type: [ "string", "null" ] }
      },
      required: %w[runId action]
    )

    def self.call(runId:, action:, server_context:, requestId: nil)
      session = server_context && TerminalSession.find_by(id: server_context[:terminal_session_id])
      workspace = session&.workspace or raise "Terminal session capability missing"
      run = workspace.runs.find_by!(run_id: runId)
      case action
      when "stop"
        StopRunJob.perform_later(run.id)
      when "resume"
        previous_state = Orchestrator::TickState.latest(run.run_id)
        run.update!(status: "running", stopped_at: nil, capacity_available_at: nil)
        Orchestrator::TickState.write(
          previous_state.merge(
            phase: "planning", tick_count: previous_state[:tick_count] + 1,
            last_plan_summary: "Terminal session resumed this run for recovery planning.",
            pending_spawn_keys: [], last_stall_finding: nil, last_updated_at: Time.current.iso8601(3)
          )
        )
        TickRunJob.perform_later
      when "tick"
        TickRunJob.perform_later
      when "reconcile"
        WorkerReconcileJob.perform_later
      when "retry_handoff"
        request = requestId.present? ? run.spawn_requests.find_by!(request_id: requestId) : interrupted_request(run)
        raise ArgumentError, "No interrupted handoff found" unless request
        raise ArgumentError, "An active worker already owns this handoff" if run.workers.exists?(status: "running", scope: request.scope)

        request.update!(
          status: "open", fulfilled_by: nil, fulfilled_at: nil, fulfillment_note: nil, fulfilled_worker_id: nil
        )
        run.update!(status: "running", capacity_available_at: nil)
        run.publish_phase!(phase: "planning", owner: "terminal_session", summary: "Terminal session requeued #{request.scope}.")
        TickRunJob.perform_later
      end
      ToolResponse.structured(runId:, action:, accepted: true)
    end

    def self.interrupted_request(run)
      stopped = run.workers.where(status: "stopped").order(stopped_at: :desc).first
      stopped && run.spawn_requests.find_by(fulfilled_worker_id: stopped.worker_id, status: "fulfilled")
    end
    private_class_method :interrupted_request
  end
end
