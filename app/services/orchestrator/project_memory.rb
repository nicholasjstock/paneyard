module Orchestrator
  # Durable, target-project knowledge. Unlike RunContext, this survives
  # individual runs and is deliberately limited to evidence-backed facts.
  module ProjectMemory
    module_function

    DEFAULT_BRIEF_ENTRY_LIMIT = 8
    BRIEF_CONTENT_LIMIT = 600
    DETAIL_ENTRY_LIMIT = 20
    AVAILABLE_KEY_LIMIT = 50

    # Relevance tier for the brief, most load-bearing first: how to
    # operate this workspace at all (operational_rule) beats a hazard you
    # can only hit after you're already running it, which beats general
    # architecture notes. Not the same order as WorkspaceMemoryEntry::KINDS
    # (that list's order is just its declared vocabulary).
    KIND_BRIEF_PRIORITY = %w[operational_rule known_hazard architecture convention].freeze

    def snapshot(run_id:, entry_keys: nil)
      run = Run.find_or_create_for_bus!(run_id)
      workspace = run.workspace
      entries = brief_order(workspace.workspace_memory_entries.current.to_a)

      {
        workspace_id: workspace.id,
        workspace_name: workspace.name,
        target_root: workspace.root_path,
        context_mode: entry_keys.present? ? "selected" : "brief",
        entries: select_entries(entries, entry_keys),
        available_entry_keys: entries.first(AVAILABLE_KEY_LIMIT).map(&:entry_key),
        available_entry_count: entries.size,
        retrieval_hint: "Request entryKeys for full details only when a specific durable rule or its evidence is needed."
      }
    end

    def record!(run_id:, entry_key:, kind:, content:, evidence_ref:, recorded_by:)
      run = Run.find_or_create_for_bus!(run_id)
      workspace = run.workspace

      WorkspaceMemoryEntry.transaction do
        previous = workspace.workspace_memory_entries.current.where(entry_key: entry_key).order(created_at: :desc).first
        previous&.update!(status: "superseded")

        workspace.workspace_memory_entries.create!(
          entry_key: entry_key,
          kind: kind,
          status: "confirmed",
          content: content,
          evidence_ref: evidence_ref,
          recorded_by: recorded_by,
          supersedes: previous
        )
      end
    end

    def select_entries(entries, entry_keys)
      if entry_keys.present?
        entries.select { |entry| entry_keys.include?(entry.entry_key) }.first(DETAIL_ENTRY_LIMIT).map(&:as_json)
      else
        entries.first(DEFAULT_BRIEF_ENTRY_LIMIT).map do |entry|
          entry.as_json.merge(content: truncate(entry.content, BRIEF_CONTENT_LIMIT))
        end
      end
    end
    private_class_method :select_entries

    # A workspace's primary dev-environment fact always leads (see
    # Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY) -- alphabetical
    # order by entry_key is otherwise meaningless for relevance, so within
    # a kind prefer the most recently confirmed entry, since a newer
    # confirmation is more likely to reflect the current state of the repo.
    def brief_order(entries)
      entries.sort_by do |entry|
        [ kind_rank(entry), entry.created_at.to_i * -1 ]
      end
    end
    private_class_method :brief_order

    def kind_rank(entry)
      return -1 if entry.entry_key == Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY

      KIND_BRIEF_PRIORITY.index(entry.kind) || KIND_BRIEF_PRIORITY.length
    end
    private_class_method :kind_rank

    def truncate(value, limit)
      text = value.to_s
      text.length > limit ? "#{text.first(limit).rstrip}…" : text
    end
    private_class_method :truncate
  end
end
