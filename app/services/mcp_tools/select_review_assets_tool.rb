require "open3"

module McpTools
  class SelectReviewAssetsTool < MCP::Tool
    tool_name "select_review_assets"
    description "Select reviewer-facing local files for post-push upload to the run's draft GitHub release. Only the evidence curator may call it."
    input_schema(properties: { runId: { type: "string" }, assets: { type: "array", maxItems: 20, items: { type: "object", properties: { path: { type: "string" }, label: { type: "string" } }, required: %w[path label] } } }, required: %w[runId assets])

    def self.call(runId:, assets:, server_context:)
      worker = WorkerAuthorization.worker!(server_context:, run_id: runId)
      raise ArgumentError, "select_review_assets requires an authenticated curator worker" unless worker.role == "curator"

      run = Run.find_by!(run_id: runId)
      selected = assets.map do |asset|
        path = asset.fetch(:path).to_s
        absolute = Pathname(run.target_root).join(path).cleanpath
        raise ArgumentError, "Review asset must be a workspace-relative file: #{path}" unless absolute.to_s.start_with?("#{Pathname(run.target_root).expand_path}/") && absolute.file?
        raise ArgumentError, "Review asset cannot be source, Git metadata, or workflow runtime output: #{path}" if excluded_path?(run, absolute)

        record = run.review_assets.create_or_find_by!(workspace_path: path) { |candidate| candidate.label = asset.fetch(:label).to_s }
        record.update!(label: asset.fetch(:label).to_s) if record.label != asset.fetch(:label).to_s
        record
      end
      ToolResponse.structured(assets: selected.map { |asset| asset.attributes.slice("workspace_path", "label") })
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end

    def self.excluded_path?(run, absolute)
      relative = absolute.relative_path_from(Pathname(run.target_root)).to_s
      runtime_root = Orchestrator::ArtifactStore.output_dir(run.target_root)
      runtime_relative = Pathname(runtime_root).relative_path_from(Pathname(run.target_root)).to_s
      return true if relative == ".git" || relative.start_with?(".git/")
      return true if relative == runtime_relative || relative.start_with?("#{runtime_relative}/")
      return true if File.basename(relative).match?(/(?:\.log|\.prompt(?:\.txt)?|\.env(?:\.json)?|\.mcp\.json)\z/i)
      return true if relative.match?(%r{(?:^|/)(?:log|logs|tmp|config)(?:/|\z)}i)
      return true if absolute.size > 2.gigabytes

      _output, _error, status = Open3.capture3("git", "-C", run.target_root, "ls-files", "--error-unmatch", "--", relative)
      status.success?
    end
    private_class_method :excluded_path?
  end
end
