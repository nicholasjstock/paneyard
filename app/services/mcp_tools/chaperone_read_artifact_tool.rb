module McpTools
  class ChaperoneReadArtifactTool < MCP::Tool
    tool_name "read_chaperone_artifact"
    description "Read a bounded window from one artifact in the authorized chaperone run."
    input_schema(
      properties: {
        artifactName: { type: "string" }, offset: { type: "integer", minimum: 0 },
        maxChars: { type: "integer", minimum: 1 }
      },
      required: %w[artifactName offset maxChars]
    )

    def self.call(artifactName:, offset:, maxChars:, server_context:)
      review = ChaperoneReview.find(server_context[:review_id])
      review.record_tool_call!(tool_name)
      path = Orchestrator::ArtifactStore.resolve_path(review.run.target_root, review.run_id, artifactName)
      total = File.size(path)
      start = offset.to_i.clamp(0, total)
      content = File.binread(path, maxChars.to_i, start).force_encoding("UTF-8").scrub
      next_offset = start + content.bytesize
      ToolResponse.structured(
        artifactName:, content:, offset: start, totalBytes: total,
        nextOffset: next_offset < total ? next_offset : nil
      )
    end
  end
end
