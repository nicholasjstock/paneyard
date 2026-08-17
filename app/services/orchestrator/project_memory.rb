module Orchestrator
  # Durable, target-project knowledge. Unlike RunContext, this survives
  # individual runs and is deliberately limited to evidence-backed facts.
  module ProjectMemory
    module_function

    DEFAULT_BRIEF_ENTRY_LIMIT = 8
    BRIEF_CONTENT_LIMIT = 600
    DETAIL_ENTRY_LIMIT = 20
    AVAILABLE_KEY_LIMIT = 50

    def snapshot(run_id:, entry_keys: nil)
      run = Run.find_or_create_for_bus!(run_id)
      workspace = run.workspace
      entries = brief_order(workspace.workspace_memory_entries.current.to_a)

      {
        workspace_id: workspace.id,
        workspace_name: workspace.name,
        target_root: workspace.source_root,
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

    # The primary dev-environment fact (see brief_order) is guaranteed a
    # brief slot in addition to DEFAULT_BRIEF_ENTRY_LIMIT, not counted
    # against it -- otherwise enough newer entries alone could still crowd
    # it out. At most one primary entry can be "current" at a time, so this
    # only ever adds 0 or 1 to the cap.
    def select_entries(entries, entry_keys)
      if entry_keys.present?
        entries.select { |entry| entry_keys.include?(entry.entry_key) }.first(DETAIL_ENTRY_LIMIT).map(&:as_json)
      else
        primary_count = entries.count { |entry| entry.entry_key == Orchestrator::WorkspaceInit::PRIMARY_ENTRY_KEY }
        entries.first(DEFAULT_BRIEF_ENTRY_LIMIT + primary_count).map do |entry|
          entry.as_json.merge(content: truncate(entry.content, BRIEF_CONTENT_LIMIT))
        end
      end
    end
    private_class_method :select_entries

    # A workspace's primary dev-environment fact always leads (see
    # Orchestrator::WorkspaceInit::PRIMARY_ENTRY_KEY). Everything else
    # is ordered by created_at alone -- the actual time it was recorded,
    # there is no separate "sent at" field -- most recent first, with no
    # kind-based tiering. A stale entry of any kind ages out of the compact
    # brief on its own as newer ones are confirmed; it stays reachable via
    # entry_keys detail retrieval, it just isn't forced into the default view.
    def brief_order(entries)
      primary, rest = entries.partition { |entry| entry.entry_key == Orchestrator::WorkspaceInit::PRIMARY_ENTRY_KEY }
      primary + rest.sort_by { |entry| -entry.created_at.to_i }
    end
    private_class_method :brief_order

    def truncate(value, limit)
      text = value.to_s
      text.length > limit ? "#{text.first(limit).rstrip}…" : text
    end
    private_class_method :truncate
  end
end
