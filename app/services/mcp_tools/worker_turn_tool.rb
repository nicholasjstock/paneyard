module McpTools
  class WorkerTurnTool < MCP::Tool
    tool_name "worker_turn"
    description "Report one worker result. A [DONE] result deterministically promotes the head of followingSteps; " \
      "otherwise it queues one bounded Rails-owned planner decision. It never spawns a planner process."
    input_schema(
      properties: {
        runId: { type: "string" },
        role: { type: "string", enum: %w[planner orchestrator worker] },
        nickname: { type: "string" },
        scope: { type: "string" },
        result: { type: "string" },
        task: { type: "string" },
        evidenceOutcome: { type: [ "string", "null" ], enum: [ *Orchestrator::DiagnosisEvidenceGate::OUTCOMES, nil ] },
        evidenceCitations: { type: "array", items: { type: "string" } },
        diagnosisFindings: {
          type: [ "object", "null" ], additionalProperties: false,
          properties: {
            targetPaths: { type: "array", maxItems: 12, items: { type: "string" } },
            measurements: {
              type: "array", maxItems: 12,
              items: {
                type: "object", additionalProperties: false,
                properties: { name: { type: "string" }, value: { type: "number" }, unit: { type: "string" } },
                required: %w[name value unit]
              }
            },
            objective: { type: [ "string", "null" ] }
          }
        }
      },
      required: %w[runId role nickname scope result task]
    )

    def self.call(runId:, role:, nickname:, scope:, result:, task:, server_context:, evidenceOutcome: nil, evidenceCitations: [], diagnosisFindings: nil)
      worker = resolve_worker!(run_id: runId, role:, nickname:, scope:)
      nickname = worker.nickname
      scope = worker.scope
      previous_state = Orchestrator::TickState.latest(runId)
      structured = Orchestrator::Turn.run_worker_turn(
        run_id: runId, role: role, nickname: nickname, scope: scope, result: result,
        evidence_outcome: evidenceOutcome, evidence_citations: evidenceCitations,
        diagnosis_findings: diagnosisFindings&.deep_symbolize_keys, previous_state: previous_state
      )
      Orchestrator::TickState.write(structured[:next_state])
      worker.update_column(:handoff_completed_at, Time.current)
      ToolResponse.structured(structured)
    end

    def self.resolve_worker!(run_id:, role:, nickname:, scope:)
      exact = Worker.find_by(run_id:, nickname:)
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
