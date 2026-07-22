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
      unless status.in?(%w[ready_for_verification waived blocked])
        raise ArgumentError, "Planner may only request verification, waive, or block acceptance criteria"
      end
      RunContext.validate_evidence!(run_id: run.run_id, evidence_ref: update[:evidence_ref]) if status == "ready_for_verification"

      entry.update!(status:, evidence_ref: update[:evidence_ref].presence || entry.evidence_ref)
      request_verification!(run:, criterion: entry) if status == "ready_for_verification"
    end
    private_class_method :apply_update!

    # The planner's own evidence citation is only ever a candidate -- it
    # names what to check, not proof the criterion holds. Only an
    # independently spawned verifier's own submit_acceptance_verification
    # call (see #verify!) can actually flip a criterion to "verified".
    def request_verification!(run:, criterion:)
      SpawnRequest.create!(
        run_id: run.run_id, asked_by: "planner", requested_role: "verifier",
        scope: "acceptance-verify-#{criterion.key}", lineage_key: "acceptance:#{criterion.key}",
        model_tier: "small", priority: "blocking", execution_mode: "verification",
        write_scope: "artifact_only", allowed_paths: [],
        text: "Independently verify whether this acceptance criterion is actually satisfied. Do not treat the " \
          "candidate evidence as proof -- reproduce the underlying claim yourself (rerun the check, the test, " \
          "or the measurement). Criterion: #{criterion.content} Candidate evidence to investigate (not to " \
          "merely re-cite): #{criterion.evidence_ref}. Call submit_acceptance_verification with " \
          "criterionKey=#{criterion.key} once you have an independent, conclusive answer."
      )
    end
    private_class_method :request_verification!

    # The only path that may set status "verified" -- called from
    # McpTools::SubmitAcceptanceVerificationTool by an authenticated
    # verifier-role worker, never directly by the planner.
    def verify!(run:, criterion_key:, outcome:, evidence_ref:, summary:)
      criterion = run.acceptance_criteria.find_by!(key: criterion_key)
      raise ArgumentError, "Criterion #{criterion_key} is not awaiting verification" unless criterion.status == "ready_for_verification"
      raise ArgumentError, "Verification outcome must be verified or rejected" unless outcome.in?(%w[verified rejected])

      case outcome
      when "verified"
        raise ArgumentError, "evidenceRef is required to verify a criterion" if evidence_ref.blank?
        if evidence_ref == criterion.evidence_ref
          raise ArgumentError, "Verification evidence must be independently produced, not the same artifact already cited"
        end

        RunContext.validate_evidence!(run_id: run.run_id, evidence_ref: evidence_ref)
        criterion.update!(status: "verified", evidence_ref: evidence_ref)
        criterion.fulfillment_steps.create!(run_id: run.run_id, lineage_key: "acceptance-verify:#{criterion.key}")
      when "rejected"
        criterion.update!(status: "blocked")
        RunContext.upsert!(
          run_id: run.run_id, entry_key: "acceptance-verify-#{criterion.key}-#{Time.current.to_i}",
          kind: "rejected_approach", status: "rejected",
          content: "Independent verification rejected criterion '#{criterion.key}': #{summary}",
          evidence_ref: evidence_ref, created_by: "verifier"
        )
      end
      criterion
    end

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

    # Narrower than completion_blockers: excludes criteria already
    # ready_for_verification, since Rails (not the planner) owns getting
    # those to a resolution. Used to decide whether the planner may
    # legitimately submit nextStep=null.
    def planner_blockers(run_id:)
      Run.find_by!(run_id:).acceptance_criteria.roots.select(&:needs_planner_action?).map(&:key)
    end

    def current_keys(run_id:)
      Run.find_by!(run_id:).acceptance_criteria.pluck(:key)
    end

    def branch_key_for_step(run:, step:)
      keys = Array(step[:addresses_criteria]).map(&:to_s).reject(&:blank?)
      return if keys.empty?

      roots = keys.map do |key|
        criterion = run.acceptance_criteria.find_by!(key: key)
        criterion = criterion.parent while criterion.parent
        criterion.key
      end.uniq
      raise ArgumentError, "A handoff may not span acceptance branches: #{roots.join(', ')}" unless roots.one?

      roots.first
    end

    def branch_resolved?(run:, branch_key:)
      run.acceptance_criteria.roots.find_by!(key: branch_key).resolved?
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
