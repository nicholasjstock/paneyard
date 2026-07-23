module McpTools
  class GetRunAuditTool < MCP::Tool
    tool_name "get_run_audit"
    description "Read the compact persisted audit trail for a completed run. Only the terminal committer may call it."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "get_run_audit requires an authenticated committer worker" unless worker.role == "committer"

      run = Run.find_by!(run_id: runId)
      ToolResponse.structured(
        run: run.attributes.slice("run_id", "task", "status", "phase", "phase_summary"),
        workers: run.workers.order(:created_at).map { |candidate| candidate.as_diagnostic_json },
        timeline: audit_events(run)
      )
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end

    def self.audit_events(run)
      BusEvent.where(run_id: run.run_id).order(:created_at).filter_map do |event|
        payload = event.payload
        case event.event_type
        when "worker.spawned", "worker.stopped", "run.status", "command.exited"
          { at: event.created_at.iso8601(3), type: event.event_type, details: payload.slice("role", "nickname", "phase", "owner", "summary", "reason", "stopReason") }
        when "spawn_request.created"
          context = payload["context"].to_s
          next unless context.include?("reported this result") || context.start_with?("Chaperone stopped")

          { at: event.created_at.iso8601(3), type: event.event_type, details: { scope: payload["scope"], report: context.truncate(6_000) } }
        end
      end
    end
    private_class_method :audit_events
  end
end
