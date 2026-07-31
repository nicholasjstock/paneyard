module McpTools
  class WorkerTurnTool < MCP::Tool
    tool_name "worker_turn"
    description "Report one worker result. A [DONE] result deterministically promotes the head of followingSteps; " \
      "otherwise it queues one bounded Rails-owned planner decision. It never spawns a planner process. If your " \
      "change added or altered a human-visible state, pass clickPath (starting page, what to click, which seeded " \
      "record to look for) -- this is persisted regardless of outcome and is the only reliable way for that " \
      "information to reach the run's terminal reporter; putting it in `result` text is not sufficient, since a " \
      "preplanned followingSteps promotion never re-reads that text."
    input_schema(
      properties: {
        runId: { type: "string" },
        role: { type: "string", enum: %w[planner orchestrator worker] },
        nickname: { type: "string" },
        scope: { type: "string" },
        result: { type: "string" },
        task: { type: "string" },
        clickPath: { type: "string" },
        evidenceOutcome: { type: [ "string", "null" ], enum: [ *Orchestrator::DiagnosisEvidenceGate::OUTCOMES, nil ] },
        evidenceCitations: { type: "array", items: { type: "string" } },
        producedArtifacts: {
          type: [ "array", "null" ],
          items: {
            type: "object", additionalProperties: false,
            properties: { name: { type: "string" }, description: { type: "string" } },
            required: %w[name]
          }
        }
      },
      required: %w[runId role result task]
    )

    def self.call(runId:, role:, result:, task:, server_context:, nickname: nil, scope: nil, evidenceOutcome: nil, evidenceCitations: [], producedArtifacts: nil, clickPath: nil)
      authenticated_worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      worker = authenticated_worker || resolve_worker!(run_id: runId, role:, nickname:, scope:)
      nickname = worker.nickname
      scope = worker.scope
      # Persisted directly on the worker row, independent of whichever
      # branch Turn.run_worker_turn takes below -- a [DONE] result with a
      # preplanned followingSteps queue promotes the next step without ever
      # recording the free-text result anywhere the reporter can read it
      # later (see Turn.run_worker_turn's fast path), so this cannot ride
      # along inside `result` and still reach get_reporter_context reliably.
      worker.update!(click_path: clickPath) if clickPath.present?
      previous_state = Orchestrator::TickState.latest(runId)
      structured = Orchestrator::Turn.run_worker_turn(
        run_id: runId, role: role, nickname: nickname, scope: scope, result: result,
        evidence_outcome: evidenceOutcome, evidence_citations: evidenceCitations,
        previous_state: previous_state, produced_artifacts: producedArtifacts
      )
      Orchestrator::TickState.write(structured[:next_state])
      worker.update_column(:handoff_completed_at, Time.current)
      ToolResponse.structured(structured)
    rescue ArgumentError, Orchestrator::ObjectiveAlignment::Error => error
      BusEvent.publish(
        "worker.handoff_rejected",
        run_id: runId,
        payload: { runId: runId, nickname: nickname, scope: scope, error: error.message }
      )
      ToolResponse.error("worker_turn rejected: #{error.message}")
    end

    def self.resolve_worker!(run_id:, role:, nickname:, scope:)
      exact = Worker.find_by(run_id:, nickname:) if nickname.present?
      return exact if exact

      candidates = Worker.active.where(run_id:, role:)
      scoped = candidates.where(scope:)
      return scoped.first if scoped.one?
      return candidates.first if candidates.one?

      raise ArgumentError, "worker_turn identity does not match one active worker"
    end
    private_class_method :resolve_worker!
  end
end
