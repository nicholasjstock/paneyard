require "open3"

module Orchestrator
  # Ports scripts/workflow-mcp.ts's buildGuardedCommand -- the fixed set of
  # approved repo environment commands worker/planner CLIs are allowed to
  # invoke via run_guarded_command, without giving them arbitrary shell
  # access.
  module GuardedCommand
    module_function

    def build(operation:, root_dir:, front_dir:, scenario: nil, execution_mode: nil, frontend_url: nil, test_target: nil)
      case operation
      when "frontend_typecheck"
        { command: "npx", args: [ "tsc", "--noEmit" ], cwd: front_dir }
      when "frontend_test"
        { command: "npm", args: [ "test", "--", *(test_target ? [ test_target ] : []) ], cwd: front_dir }
      when "record_demo"
        if scenario.blank? || execution_mode.blank? || frontend_url.blank?
          raise ArgumentError, "record_demo requires scenario, executionMode, and frontendUrl"
        end

        { command: "bin/record_demo", args: [ scenario, "--#{execution_mode}", "--frontend-url=#{frontend_url}" ], cwd: root_dir }
      else
        raise ArgumentError, "Unknown guarded command operation: #{operation}"
      end
    end

    def run(operation:, root_dir:, front_dir:, scenario: nil, execution_mode: nil, frontend_url: nil, test_target: nil)
      spec = build(
        operation: operation, root_dir: root_dir, front_dir: front_dir,
        scenario: scenario, execution_mode: execution_mode, frontend_url: frontend_url, test_target: test_target
      )
      # argv-array form (no shell) -- same command-injection-safe pattern
      # already used by LaunchRunJob's Process.spawn.
      stdout, stderr, status = Open3.capture3(spec[:command], *spec[:args], chdir: spec[:cwd])
      spec.merge(exitCode: status.exitstatus, stdout: stdout, stderr: stderr, success: status.success?)
    end
  end
end
