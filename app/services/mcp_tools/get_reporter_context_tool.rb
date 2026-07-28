module McpTools
  class GetReporterContextTool < MCP::Tool
    tool_name "get_reporter_context"
    description "Read the evidence for the reporter's current assignment. Only the reporter role may call it. " \
      "Rails decides upstream what evidence is relevant and who it's for (`audience`) -- render exactly what's " \
      "in `evidence`, for `audience`, to `outputArtifact`; the reporter has no other orchestration knowledge to " \
      "reason from."
    input_schema(properties: { runId: { type: "string" } }, required: %w[runId])

    def self.call(runId:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "get_reporter_context requires an authenticated reporter worker" unless worker.role == "reporter"

      run = Run.find_by!(run_id: runId)
      plan_approval = Orchestrator::PlanApprovalQuestion.plan_summary_scope?(worker.scope)
      extra = plan_approval ? plan_approval_evidence(run) : finalization_evidence(run)
      # `request` and `audience` are the two fields guaranteed present in
      # every evidence payload, under the same names with the same meaning
      # (the operator's original ask; who this account is being written
      # for) -- computed once here, as plain data, rather than left for the
      # reporter's own prompt to know as orchestration-specific vocabulary
      # ("a PR reviewer" vs "an operator approving a plan").
      audience = plan_approval ? "the operator, deciding whether to approve this before any code is written" : "the reviewer of the resulting pull request"
      evidence = { request: run.task, audience:, **extra }
      validate_shared_envelope!(evidence)
      ToolResponse.structured(outputArtifact: worker.scope, evidence:)
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end

    # The reporter never validates its own input -- see agent_personas/reporter.md,
    # which deliberately has no shape knowledge to check against. That
    # validation has to live here instead, with whichever code actually
    # supplies the evidence, so a bug in evidence construction is caught at
    # its source rather than silently handed to the reporter to render.
    def self.validate_shared_envelope!(evidence)
      raise ArgumentError, "get_reporter_context evidence.request must be present" if evidence[:request].blank?
      raise ArgumentError, "get_reporter_context evidence.audience must be present" if evidence[:audience].blank?
    end
    private_class_method :validate_shared_envelope!

    def self.finalization_evidence(run)
      workers = run.workers.order(:created_at)
      evidence = {
        status: run.attributes.slice("status", "phase", "phase_summary"),
        # Surfaced on its own, clearly-named field rather than left buried
        # in one worker's diagnostic dump alongside a dozen unrelated
        # technical fields -- a reporter rendering "everything in the
        # evidence, faithfully" naturally covers this without a
        # special-cased rule telling it where to look or how to format it.
        howToSeeIt: workers.filter_map(&:click_path).last,
        workers: workers.map { |candidate| candidate.as_diagnostic_json.except(:clickPath) },
        timeline: audit_events(run)
      }
      raise ArgumentError, "finalization evidence.status must be a Hash" unless evidence[:status].is_a?(Hash)
      raise ArgumentError, "finalization evidence.workers must be an Array" unless evidence[:workers].is_a?(Array)
      raise ArgumentError, "finalization evidence.timeline must be an Array" unless evidence[:timeline].is_a?(Array)

      evidence
    end
    private_class_method :finalization_evidence

    def self.plan_approval_evidence(run)
      decision = run.planner_decisions.where(status: "completed").order(created_at: :desc).first
      raise ArgumentError, "plan-approval evidence requires a completed planner decision for #{run.run_id}" unless decision
      raise ArgumentError, "plan-approval evidence requires decision.next_step for #{run.run_id}" unless decision.decision["next_step"].present?

      { proposedStep: decision.decision["next_step"], planSummary: decision.decision["summary"] }
    end
    private_class_method :plan_approval_evidence

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
