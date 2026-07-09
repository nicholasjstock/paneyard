require "open3"

module Orchestrator
  # Ports scripts/workflow-mcp.ts's buildGuardedCommand -- the fixed set of
  # approved repo environment commands worker/planner CLIs are allowed to
  # invoke via run_guarded_command, without giving them arbitrary shell
  # access.
  module GuardedCommand
    module_function

    def build(operation:, front_dir:, test_target: nil)
      case operation
      when "frontend_typecheck"
        { command: "npx", args: [ "tsc", "--noEmit" ], cwd: front_dir }
      when "frontend_test"
        { command: "npm", args: [ "test", "--", *(test_target ? [ test_target ] : []) ], cwd: front_dir }
      else
        raise ArgumentError, "Unknown guarded command operation: #{operation}"
      end
    end

    def run(operation:, front_dir:, test_target: nil)
      spec = build(operation: operation, front_dir: front_dir, test_target: test_target)
      # argv-array form (no shell) -- same command-injection-safe pattern
      # already used by LaunchRunJob's Process.spawn.
      stdout, stderr, status = Open3.capture3(spec[:command], *spec[:args], chdir: spec[:cwd])
      spec.merge(exit_code: status.exitstatus, stdout: stdout, stderr: stderr, success: status.success?)
    end
  end
end
