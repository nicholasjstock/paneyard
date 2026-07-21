module McpTools
  class SubmitAcceptanceVerificationTool < MCP::Tool
    tool_name "submit_acceptance_verification"
    description "Report an independent verification outcome for one acceptance criterion. Only an authenticated " \
      "verifier-role worker scoped to that criterion may call this -- it is the only way a criterion becomes " \
      "verified. A rejected outcome sends the criterion back to blocked with your reasoning."
    input_schema(
      properties: {
        runId: { type: "string" },
        criterionKey: { type: "string" },
        outcome: { type: "string", enum: %w[verified rejected] },
        evidenceRef: { type: [ "string", "null" ] },
        summary: { type: "string" }
      },
      required: %w[runId criterionKey outcome summary]
    )

    def self.call(runId:, criterionKey:, outcome:, summary:, server_context:, evidenceRef: nil)
      expected_scope = "acceptance-verify-#{criterionKey}"
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId) ||
        resolve_worker!(run_id: runId, scope: expected_scope)
      raise ArgumentError, "submit_acceptance_verification requires an authenticated verifier worker" unless worker.role == "verifier"
      raise ArgumentError, "This verifier is not authorized for criterion #{criterionKey}" unless worker.scope == expected_scope

      run = Run.find_by!(run_id: runId)
      criterion = Orchestrator::AcceptanceCriteria.verify!(
        run: run, criterion_key: criterionKey, outcome: outcome, evidence_ref: evidenceRef, summary: summary
      )
      ToolResponse.structured(Orchestrator::AcceptanceCriteria.criterion_json(criterion))
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end

    # Direct service/unit specs and the test-only fake-agent harness call
    # tools without going through the real MCP transport, so
    # WorkerAuthorization.worker! has nothing to authenticate against (see
    # its Rails.env.test? escape hatch). Mirrors
    # McpTools::WorkerTurnTool.resolve_worker! -- identity is resolved from
    # the run-scoped (role, scope) slot instead of a capability token.
    def self.resolve_worker!(run_id:, scope:)
      Worker.active.find_by(run_id:, role: "verifier", scope:) ||
        raise(ArgumentError, "No active verifier worker found for #{scope}")
    end
  end
end
