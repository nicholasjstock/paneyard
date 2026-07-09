module McpTools
  class BuildGuardedCommandTool < MCP::Tool
    tool_name "build_guarded_command"
    description "Build one of the approved repo environment commands without executing it."
    input_schema(
      properties: {
        runId: { type: "string" },
        operation: { type: "string", enum: %w[frontend_typecheck frontend_test] },
        testTarget: { type: "string" }
      },
      required: %w[runId operation]
    )

    def self.call(runId:, operation:, server_context:, testTarget: nil)
      run = Run.find_or_create_for_bus!(runId)
      structured = Orchestrator::GuardedCommand.build(
        operation: operation, front_dir: File.join(run.target_root, "front"), test_target: testTarget
      )
      ToolResponse.structured(structured)
    end
  end
end
