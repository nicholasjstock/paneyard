module McpTools
  class SubmitPlannerDecisionTool < MCP::Tool
    STEP_SCHEMA = {
      type: "object",
      additionalProperties: false,
      properties: {
        owner: { type: "string", enum: Orchestrator::StepPolicy::PLANNER_STEP_OWNERS },
        artifact: { type: "string" },
        successCheck: { type: "string" },
        mode: { type: "string", enum: Orchestrator::StepPolicy::MODES },
        writeScope: { type: "string", enum: Orchestrator::StepPolicy::WRITE_SCOPES },
        allowedPaths: { type: "array", items: { type: "string" } },
        evidenceRefs: { type: "array", items: { type: "string" } },
        addressesCriteria: { type: "array", items: { type: "string" }, maxItems: 8 },
        operatorApprovalQuestionId: { type: [ "string", "null" ] },
        lineageKey: { type: [ "string", "null" ] },
        humanSummary: {
          type: [ "string", "null" ],
          description: "Required when writeScope is scoped_changes (the step that will trigger the operator " \
            "plan-approval gate, see Orchestrator::PlanApprovalQuestion): one or two plain-language sentences " \
            "explaining what this step will do and why it follows from the operator's original request, addressed " \
            "directly to the operator -- not a restatement of the fields above (artifact, writeScope, " \
            "addressesCriteria, ...) and not internal jargon. This is what the operator actually reads to decide " \
            "whether to approve; the structured fields are reference detail underneath it. Leave null for any " \
            "step that will not itself trigger that gate (diagnosis, verification, non-scoped_changes work)."
        }
      },
      required: %w[owner artifact successCheck mode writeScope allowedPaths evidenceRefs addressesCriteria]
    }.freeze

    ACCEPTANCE_CRITERION_SCHEMA = {
      type: "object", additionalProperties: false,
      properties: {
        key: { type: "string", pattern: "^[a-z0-9][a-z0-9-]{0,63}$" },
        content: { type: "string" },
        parentKey: { type: [ "string", "null" ] }
      },
      required: %w[key content parentKey]
    }.freeze

    ACCEPTANCE_UPDATE_SCHEMA = {
      type: "object", additionalProperties: false,
      properties: {
        key: { type: "string" }, status: { type: "string", enum: %w[ready_for_verification waived blocked] },
        evidenceRef: { type: [ "string", "null" ] }
      },
      required: %w[key status evidenceRef]
    }.freeze

    MEMORY_ENTRY_SCHEMA = {
      type: "object", additionalProperties: false,
      properties: {
        key: { type: "string" },
        kind: { type: "string", enum: WorkspaceMemoryEntry::KINDS },
        content: { type: "string" },
        evidenceRef: { type: "string" }
      },
      required: %w[key kind content evidenceRef]
    }.freeze

    tool_name "submit_planner_decision"
    description "Submit exactly one bounded orchestration decision: a plan (decision), a request for more " \
      "evidence (needs_context), or a request for stronger reasoning (needs_stronger_model). A rejected decision " \
      "returns accepted=false with the exact reason -- fix it and call this again. Call as many times as needed " \
      "for needs_context; exactly once to finish with decision or needs_stronger_model. A text-only response " \
      "without ever calling this is a failure. Only a decision outcome persists memoryEntries -- an entry with " \
      "the same key supersedes the prior one and must cite evidenceRef."
    input_schema(
      properties: {
        outcome: { type: "string", enum: %w[decision needs_context needs_stronger_model] },
        summary: { type: "string" },
        nextStep: STEP_SCHEMA.merge(type: [ "object", "null" ]),
        followingSteps: { type: "array", maxItems: 5, items: STEP_SCHEMA },
        contextRequest: {
          type: [ "object", "null" ],
          additionalProperties: false,
          properties: {
            source: { type: "string", enum: Orchestrator::PlannerContextResolver::SOURCES },
            reference: { type: "string" },
            question: { type: "string" },
            offset: { type: [ "integer", "null" ], minimum: 0 },
            maxChars: { type: "integer", minimum: 1 }
          },
          required: %w[source reference question offset maxChars]
        },
        acceptanceCriteria: { type: "array", maxItems: 8, items: ACCEPTANCE_CRITERION_SCHEMA },
        acceptanceUpdates: { type: "array", maxItems: 8, items: ACCEPTANCE_UPDATE_SCHEMA },
        memoryEntries: { type: "array", maxItems: 5, items: MEMORY_ENTRY_SCHEMA }
      },
      required: %w[outcome summary nextStep followingSteps contextRequest acceptanceCriteria acceptanceUpdates memoryEntries]
    )

    def self.call(outcome:, summary:, nextStep:, followingSteps:, contextRequest:, acceptanceCriteria:, acceptanceUpdates:, memoryEntries:, server_context:)
      decision = server_context && PlannerDecision.find_by(decision_id: server_context[:decision_id])
      raise ArgumentError, "submit_planner_decision requires an authenticated planner decision capability" unless decision

      params = {
        outcome: outcome, summary: summary,
        next_step: Orchestrator::WireFormat.underscore_keys(nextStep),
        following_steps: Orchestrator::WireFormat.underscore_keys(followingSteps),
        context_request: Orchestrator::WireFormat.underscore_keys(contextRequest),
        acceptance_criteria: Orchestrator::WireFormat.underscore_keys(acceptanceCriteria),
        acceptance_updates: Orchestrator::WireFormat.underscore_keys(acceptanceUpdates),
        memory_entries: Orchestrator::WireFormat.underscore_keys(memoryEntries)
      }
      result = Orchestrator::PlannerDecisionSubmission.call(decision: decision, params: params)
      ToolResponse.structured(result)
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end
