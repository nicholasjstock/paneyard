module Orchestrator
  # An operator may change drivers only while a run is explicitly paused for
  # provider capacity. It preserves all run evidence and queued handoffs;
  # TickRunJob resumes the existing workflow under the newly selected CLI.
  module SwitchRunLauncher
    class Ineligible < StandardError; end

    module_function

    def call(run:, launcher_variant:)
      target = launcher_variant.to_s

      run.with_lock do
        run.reload
        validate!(run:, target:)

        previous_launcher = run.launcher_variant
        run.update!(launcher_variant: target, capacity_available_at: nil)
        run.publish_phase!(
          phase: "planning",
          owner: "operator",
          summary: "Switched to #{target.capitalize} after #{previous_launcher.capitalize} capacity became unavailable; resuming queued work."
        )
      end

      TickRunJob.perform_later
      run
    end

    def validate!(run:, target:)
      raise Ineligible, "Run is not active." unless run.status == "running"
      raise Ineligible, "Run is not waiting for launcher capacity." unless run.capacity_blocked?
      raise Ineligible, "Unsupported launcher: #{target}." unless Run::LAUNCHER_VARIANTS.include?(target)
      raise Ineligible, "Run already uses #{target}." if run.launcher_variant == target
      raise Ineligible, "Unchanged launcher variant." if target == run.launcher_variant
      raise Ineligible, "A worker is still active on this run." if run.workers.exists?(status: "running")
      raise Ineligible, "A planner decision is still active on this run." if PlannerDecision.active.where(run_id: run.run_id).exists?
    end
    private_class_method :validate!
  end
end
