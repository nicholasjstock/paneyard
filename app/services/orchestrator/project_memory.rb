module Orchestrator
  # Durable, target-project knowledge. Unlike RunContext, this survives
  # individual runs and is deliberately limited to evidence-backed facts.
  module ProjectMemory
    module_function

    def snapshot(run_id:)
      run = Run.find_or_create_for_bus!(run_id)
      workspace = run.workspace

      {
        workspace_id: workspace.id,
        workspace_name: workspace.name,
        target_root: workspace.root_path,
        entries: workspace.workspace_memory_entries.current.order(:kind, :entry_key, :created_at).map(&:as_json)
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
  end
end
