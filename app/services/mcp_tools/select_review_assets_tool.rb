module McpTools
  class SelectReviewAssetsTool < MCP::Tool
    tool_name "select_review_assets"
    description "Select reviewer-facing local files for post-push upload to the run's draft GitHub release. Only the terminal committer may call it."
    input_schema(properties: { runId: { type: "string" }, assets: { type: "array", minItems: 1, maxItems: 20, items: { type: "object", properties: { path: { type: "string" }, label: { type: "string" } }, required: %w[path label] } } }, required: %w[runId assets])

    def self.call(runId:, assets:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "select_review_assets requires an authenticated committer worker" unless worker.role == "committer"

      run = Run.find_by!(run_id: runId)
      selected = assets.map do |asset|
        path = asset.fetch(:path).to_s
        absolute = Pathname(run.target_root).join(path).cleanpath
        raise ArgumentError, "Review asset must be a workspace-relative file: #{path}" unless absolute.to_s.start_with?("#{Pathname(run.target_root).expand_path}/") && absolute.file?

        run.review_assets.create_or_find_by!(workspace_path: path) { |record| record.label = asset.fetch(:label).to_s }
      end
      ToolResponse.structured(assets: selected.map { |asset| asset.attributes.slice("workspace_path", "label") })
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end
  end
end
