# Replaces OrchestratorDecisionState + its append-only tick history
# (orchestrator-state/<runId>.json + .history.json in workflow-mcp.ts) --
# one immutable row per tick. "Current state" = the latest row by
# tick_count; "history" = all rows for a run, ordered.
class OrchestratorTick < ApplicationRecord
  PHASES = %w[starting planning waiting_on_workers stalled blocked_on_user completed].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, optional: true, inverse_of: :orchestrator_ticks

  validates :run_id, :phase, presence: true
  validates :tick_count, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :phase, inclusion: { in: PHASES }

  scope :for_run, ->(run_id) { where(run_id: run_id).order(:tick_count) }

  def as_json(*)
    {
      runId: run_id,
      phase: phase,
      tickCount: tick_count,
      lastPlanSummary: last_plan_summary,
      pendingSpawnKeys: pending_spawn_keys,
      followingSteps: following_steps,
      lastStallFinding: last_stall_finding,
      lastUpdatedAt: created_at&.iso8601(3)
    }
  end
end
