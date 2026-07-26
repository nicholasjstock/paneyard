module McpTools
  class CollectArtifactsTool < MCP::Tool
    tool_name "collect_artifacts"
    description "Discover artifacts in the current run. Returns metadata for available artifacts, optionally filtered by producer worker or inheritance status."
    input_schema(
      properties: {
        runId: { type: "string" },
        producedBy: { type: "string", description: "Filter by producer worker_id" },
        inherited: { type: "boolean", description: "Filter by inheritance status (true/false)" }
      },
      required: %w[runId]
    )

    def self.call(runId:, server_context:, producedBy: nil, inherited: nil)
      run = Run.find_or_create_for_bus!(runId)
      all_artifact_names = Orchestrator::ArtifactStore.names(run.target_root, runId)
      metadata = Orchestrator::ArtifactStore.collect(run.target_root, runId, all_artifact_names)

      artifacts = build_artifact_list(runId, metadata[:artifacts], producedBy, inherited)

      ToolResponse.structured({
        runId: runId,
        artifacts: artifacts,
        totalCount: artifacts.length,
        truncated: artifacts.length < metadata[:artifacts].length
      })
    end

    private_class_method def self.build_artifact_list(run_id, artifacts_metadata, produced_by, inherited_filter)
      workers_by_artifact = build_producer_map(run_id)

      artifacts_metadata.map do |metadata|
        artifact_info = {
          name: metadata[:name],
          exists: metadata[:exists],
          sizeBytes: metadata[:size_bytes],
          updatedAt: metadata[:updated_at],
          preview: metadata[:preview]
        }

        producer = workers_by_artifact[metadata[:name]]
        artifact_info[:producedBy] = producer if producer

        artifact_info[:inherited] = is_inherited?(run_id, metadata[:name])

        artifact_info
      end.select do |artifact|
        matches_producer_filter?(artifact, produced_by) && matches_inherited_filter?(artifact, inherited_filter)
      end
    end

    private_class_method def self.build_producer_map(run_id)
      map = {}
      Worker.where(run_id: run_id, status: "stopped").each do |worker|
        next unless worker.produced_artifacts.is_a?(Array)

        worker.produced_artifacts.each do |artifact_name|
          map[artifact_name] = worker.worker_id
        end
      end
      map
    end

    private_class_method def self.is_inherited?(run_id, artifact_name)
      Worker.where(run_id: run_id, status: "stopped")
        .where("inherited_artifacts LIKE ?", "%\"#{artifact_name}\"%")
        .exists?
    end

    private_class_method def self.matches_producer_filter?(artifact, producer_filter)
      return true if producer_filter.blank?

      artifact[:producedBy] == producer_filter
    end

    private_class_method def self.matches_inherited_filter?(artifact, inherited_filter)
      return true if inherited_filter.nil?

      (artifact[:inherited] || false) == inherited_filter
    end
  end
end
