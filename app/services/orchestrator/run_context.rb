module Orchestrator
  # Compiles curated, current operational knowledge for one run. It is kept
  # separate from the unbounded event log so planners receive decisions and
  # acceptance gates without replaying every worker transcript.
  module RunContext
    module_function

    def snapshot(run_id:)
      entries = RunContextEntry.where(run_id: run_id).order(:kind, :entry_key)
      grouped = entries.group_by(&:kind)
      criteria = grouped.fetch("acceptance_criterion", []).map(&:as_json)

      {
        run_id: run_id,
        acceptance_criteria: criteria,
        constraints: grouped.fetch("constraint", []).map(&:as_json),
        facts: grouped.fetch("fact", []).map(&:as_json),
        rejected_approaches: grouped.fetch("rejected_approach", []).map(&:as_json),
        operator_decisions: grouped.fetch("operator_decision", []).map(&:as_json),
        completion_blockers: criteria_completion_blockers(criteria)
      }
    end

    def completion_blockers(run_id:)
      criteria_completion_blockers(snapshot(run_id: run_id)[:acceptance_criteria])
    end

    def upsert!(run_id:, entry_key:, kind:, status:, content:, evidence_ref:, created_by:)
      entry = RunContextEntry.find_or_initialize_by(run_id: run_id, entry_key: entry_key)
      entry.assign_attributes(
        kind: kind,
        status: status,
        content: content,
        evidence_ref: evidence_ref.presence,
        created_by: created_by
      )
      entry.save!
      entry
    end

    def criteria_completion_blockers(criteria)
      criteria.select { |criterion| !%w[verified waived].include?(criterion[:status] || criterion["status"]) }
        .map { |criterion| criterion[:key] || criterion["key"] }
    end
    private_class_method :criteria_completion_blockers
  end
end
