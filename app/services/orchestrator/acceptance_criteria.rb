module Orchestrator
  # Owns the acceptance-criteria tree's whole lifecycle: establishing the
  # immutable top-level contract on a run's first decision, letting any
  # existing criterion be decomposed into children at any later decision,
  # applying verified/waived/blocked updates, and recording which steps
  # worked toward which criterion. Replaces the old flat, RunContextEntry-
  # backed acceptance handling in Orchestrator::RunContext entirely.
  module AcceptanceCriteria
    module_function

    def apply!(run:, criteria:, updates:)
      # Checked once before the loop, not per-criterion -- the initial
      # decision commonly establishes several top-level criteria in the same
      # call, and each of those is itself a still-unestablished contract at
      # the time it's proposed.
      contract_established = run.acceptance_criteria.roots.exists?
      criteria.each { |criterion| add!(run:, criterion:, contract_established:) }
      updates.each { |update| apply_update!(run:, update:) }
    end

    def add!(run:, criterion:, contract_established:)
      key = criterion.fetch(:key).to_s
      parent_key = criterion[:parent_key].presence
      raise ArgumentError, "Acceptance criterion key already exists: #{key}" if run.acceptance_criteria.exists?(key:)

      if parent_key
        # Any existing criterion can be a parent, not just a root -- depth is
        # unbounded, a child can later be decomposed into its own children.
        parent = run.acceptance_criteria.find_by(key: parent_key)
        raise ArgumentError, "Unknown parent acceptance criterion: #{parent_key}" unless parent

        run.acceptance_criteria.create!(key:, parent:, content: criterion.fetch(:content), status: "pending")
      else
        raise ArgumentError, "Acceptance contract is immutable after the initial planner decision" if contract_established

        run.acceptance_criteria.create!(key:, content: criterion.fetch(:content), status: "pending")
      end
    end
    private_class_method :add!

    def apply_update!(run:, update:)
      entry = run.acceptance_criteria.find_by!(key: update.fetch(:key))
      status = update.fetch(:status).to_s
      raise ArgumentError, "Planner may only verify, waive, or block acceptance criteria" unless status.in?(%w[verified waived blocked])
      RunContext.validate_evidence!(run_id: run.run_id, evidence_ref: update[:evidence_ref]) if status == "verified"

      entry.update!(status:, evidence_ref: update[:evidence_ref].presence || entry.evidence_ref)
    end
    private_class_method :apply_update!

    # Called once per accepted decision, for the step actually being
    # dispatched (not followingSteps -- those are speculative and get
    # replaced wholesale on the next turn anyway). Automatic pending ->
    # in_progress transition: the model declares *what* a step addresses;
    # Rails tracks *whether anything has started* on it.
    def record_step!(run:, next_step:)
      return unless next_step

      Array(next_step[:addresses_criteria]).each do |key|
        criterion = run.acceptance_criteria.find_by(key:)
        next unless criterion

        criterion.update!(status: "in_progress") if criterion.status == "pending"
        criterion.fulfillment_steps.create!(run_id: run.run_id, lineage_key: next_step[:lineage_key].presence || next_step[:artifact])
      end
    end

    def completion_blockers(run_id:)
      Run.find_by!(run_id:).acceptance_criteria.roots.reject(&:resolved?).map(&:key)
    end

    def current_keys(run_id:)
      Run.find_by!(run_id:).acceptance_criteria.pluck(:key)
    end

    def tree(run_id:)
      Run.find_by!(run_id:).acceptance_criteria.roots.includes(:children).map { |root| criterion_json(root) }
    end

    def criterion_json(criterion)
      {
        key: criterion.key, content: criterion.content, status: criterion.status,
        evidenceRef: criterion.evidence_ref, resolved: criterion.resolved?,
        children: criterion.children.map { |child| criterion_json(child) }
      }
    end
  end
end
