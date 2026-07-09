module McpTools
  class RunGuardedCommandTool < MCP::Tool
    tool_name "run_guarded_command"
    description "Execute one approved repo environment command and return structured stdout/stderr results."
    input_schema(
      properties: {
        runId: { type: "string" },
        operation: { type: "string", enum: %w[record_demo frontend_typecheck frontend_test] },
        scenario: { type: "string", enum: %w[admin phone both] },
        executionMode: { type: "string", enum: %w[local docker] },
        frontendUrl: { type: "string" },
        testTarget: { type: "string" }
      },
      required: %w[runId operation]
    )

    def self.call(runId:, operation:, server_context:, scenario: nil, executionMode: nil, frontendUrl: nil, testTarget: nil)
      run = Run.find_or_create_for_bus!(runId)
      structured = Orchestrator::GuardedCommand.run(
        operation: operation, root_dir: run.target_root, front_dir: File.join(run.target_root, "front"),
        scenario: scenario, execution_mode: executionMode, frontend_url: frontendUrl, test_target: testTarget
      )
      ToolResponse.structured(structured)
    end
  end
end
