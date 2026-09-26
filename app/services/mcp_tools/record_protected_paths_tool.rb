module McpTools
  class RecordProtectedPathsTool < MCP::Tool
    tool_name "record_protected_paths"
    description "Declare this workspace's protected source glob patterns -- the paths a run should not touch unless " \
      "its task is explicitly about them. Include source, configuration, and maintained tests, but exclude dependency " \
      "caches, build output, and generated artifacts. Replaces any previously declared patterns for this workspace."
    input_schema(
      properties: {
        runId: { type: "string" },
        patterns: {
          type: "array", minItems: 1, maxItems: 30,
          items: { type: "string" }
        }
      },
      required: %w[runId patterns]
    )

    def self.call(runId:, patterns:, server_context:)
      SessionAuthorization.session!(server_context:, run_id: runId)
      run = Run.find_by!(run_id: runId)
      cleaned = patterns.map(&:to_s).map(&:strip).reject(&:blank?).uniq
      validate_patterns!(cleaned)
      run.workspace.update!(protected_path_patterns: cleaned)
      ToolResponse.structured(patterns: run.workspace.protected_path_patterns)
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end

    def self.validate_patterns!(patterns)
      raise ArgumentError, "record_protected_paths requires at least one source pattern" if patterns.empty?

      invalid = patterns.select do |pattern|
        Pathname(pattern).absolute? || Pathname(pattern).cleanpath.to_s.start_with?("../") || pattern == "." || pattern == "**" || pattern.start_with?("!")
      end
      raise ArgumentError, "invalid protected source patterns: #{invalid.join(', ')}" if invalid.any?

      cache_patterns = patterns.select { |pattern| pattern.match?(%r{(^|/)(\.git|node_modules|vendor/bundle|tmp|log)(/|\z)}) }
      raise ArgumentError, "protected source patterns must exclude caches and runtime state: #{cache_patterns.join(', ')}" if cache_patterns.any?
    end
    private_class_method :validate_patterns!
  end
end
