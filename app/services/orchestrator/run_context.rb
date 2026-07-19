require "pathname"

module Orchestrator
  # Compiles curated, current operational knowledge for one run. It is kept
  # separate from the unbounded event log so planners receive decisions and
  # acceptance gates without replaying every worker transcript.
  module RunContext
    module_function

    DEFAULT_BRIEF_ENTRY_LIMIT = 8
    BRIEF_CONTENT_LIMIT = 600
    DETAIL_ENTRY_LIMIT = 20
    AVAILABLE_KEY_LIMIT = 50

    # The default snapshot is deliberately a small briefing, not a replay of
    # the whole run. Agents can request exact entry keys when a fact needs
    # its full evidence or wording. Keeping the default bounded prevents a
    # new agent from spending its context window on history it may not need.
    def snapshot(run_id:, entry_keys: nil)
      entries = RunContextEntry.where(run_id: run_id).order(:kind, :entry_key)
      grouped = entries.group_by(&:kind)
      criteria = grouped.fetch("acceptance_criterion", []).map(&:as_json)
      selected_entries = select_entries(entries.to_a, entry_keys)

      {
        run_id: run_id,
        context_mode: entry_keys.present? ? "selected" : "brief",
        entries: selected_entries,
        available_entry_keys: entries.limit(AVAILABLE_KEY_LIMIT).pluck(:entry_key),
        available_entry_count: entries.count,
        retrieval_hint: "Request entryKeys for full details only when a specific fact, decision, or evidence reference is needed.",
        completion_blockers: criteria_completion_blockers(criteria)
      }
    end

    def completion_blockers(run_id:)
      criteria = RunContextEntry.where(run_id: run_id, kind: "acceptance_criterion").map(&:as_json)
      criteria_completion_blockers(criteria)
    end

    def upsert!(run_id:, entry_key:, kind:, status:, content:, evidence_ref:, created_by:)
      validate_evidence!(run_id:, evidence_ref:) if kind == "acceptance_criterion" && status == "verified"
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

    def apply_planner_acceptance!(run:, criteria:, updates:)
      existing = run.run_context_entries.where(kind: "acceptance_criterion")
      if existing.empty?
        raise ArgumentError, "Initial planner decision requires an acceptance contract" if criteria.empty?

        criteria.each do |criterion|
          key = criterion.fetch(:key).to_s
          raise ArgumentError, "Invalid acceptance criterion key: #{key}" unless key.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)

          upsert!(
            run_id: run.run_id, entry_key: key, kind: "acceptance_criterion", status: "pending",
            content: criterion.fetch(:content), evidence_ref: nil, created_by: "planner"
          )
        end
      elsif criteria.any?
        raise ArgumentError, "Acceptance contract is immutable after the initial planner decision"
      end

      updates.each do |update|
        entry = existing.find_by(entry_key: update.fetch(:key)) ||
          run.run_context_entries.find_by!(kind: "acceptance_criterion", entry_key: update.fetch(:key))
        status = update.fetch(:status).to_s
        raise ArgumentError, "Planner may only verify or waive acceptance criteria" unless status.in?(%w[verified waived])

        upsert!(
          run_id: run.run_id, entry_key: entry.entry_key, kind: entry.kind, status:,
          content: entry.content, evidence_ref: update[:evidence_ref], created_by: "planner"
        )
      end
    end

    def validate_evidence!(run_id:, evidence_ref:)
      run = Run.find_by!(run_id:)
      root = Pathname.new(run.target_root).expand_path
      candidate = root.join(evidence_ref.to_s).cleanpath
      inside_workspace = candidate.to_s == root.to_s || candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")
      workspace_evidence = inside_workspace && candidate.file?
      artifact_evidence = begin
        File.file?(ArtifactStore.resolve_path(run.target_root, run.run_id, evidence_ref))
      rescue ArgumentError
        false
      end
      raise ArgumentError, "Verified acceptance evidence does not exist: #{evidence_ref}" unless workspace_evidence || artifact_evidence
    end
    private_class_method :validate_evidence!

    def criteria_completion_blockers(criteria)
      criteria.select { |criterion| !%w[verified waived].include?(criterion[:status] || criterion["status"]) }
        .map { |criterion| criterion[:key] || criterion["key"] }
    end
    private_class_method :criteria_completion_blockers

    def select_entries(entries, entry_keys)
      if entry_keys.present?
        entries.select { |entry| entry_keys.include?(entry.entry_key) }
          .first(DETAIL_ENTRY_LIMIT)
          .map(&:as_json)
      else
        entries
          .sort_by { |entry| [ brief_kind_rank(entry.kind), -entry.updated_at.to_i ] }
          .first(DEFAULT_BRIEF_ENTRY_LIMIT)
          .map { |entry| brief_entry(entry) }
      end
    end
    private_class_method :select_entries

    def brief_kind_rank(kind)
      %w[operator_decision acceptance_criterion constraint fact rejected_approach].index(kind) || 99
    end
    private_class_method :brief_kind_rank

    def brief_entry(entry)
      entry.as_json.merge(content: truncate(entry.content, BRIEF_CONTENT_LIMIT))
    end
    private_class_method :brief_entry

    def truncate(value, limit)
      text = value.to_s
      text.length > limit ? "#{text.first(limit).rstrip}…" : text
    end
    private_class_method :truncate
  end
end
