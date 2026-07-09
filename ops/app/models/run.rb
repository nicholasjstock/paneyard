# Rails-owned bookkeeping for "which OS process, if any, is driving run X" --
# the orchestrator's own JSON state (workflow-bus.json / orchestrator-state/*)
# tracks worker subprocess PIDs but never the supervisor_launcher loop process
# itself, so this table is the only place that mapping exists.
#
# `status` (this model's own OS-process lifecycle enum) and `phase`
# (below, mirroring WorkflowRunStatus from workflow-bus.ts) are
# deliberately separate concepts that must not be conflated -- see
# scripts/orchestrator-turn.ts's OrchestratorDecisionPhase for the third,
# still-distinct phase enum (that one lives on OrchestratorTick).
class Run < ApplicationRecord
  LAUNCHER_VARIANTS = %w[claude codex].freeze
  STATUSES = %w[launching running stopping stopped completed failed].freeze
  NON_TERMINAL_STATUSES = %w[launching running stopping].freeze

  has_many :spawn_requests, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :user_questions, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :workers, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :orchestrator_ticks, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :bus_events, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy

  validates :run_id, presence: true, uniqueness: true
  validates :task, presence: true
  validates :target_root, presence: true
  validates :launcher_variant, inclusion: { in: LAUNCHER_VARIANTS }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: NON_TERMINAL_STATUSES) }

  # Every standalone/bus-only entrypoint (a bare supervisor loop tick, a
  # worker's own MCP tool calls) can reference a runId that was never
  # explicitly "launched" through the ops UI (LaunchRunJob is the only
  # place that creates a Run today) -- any runId string must still work.
  # Placeholder values keep the row valid without pretending to know real
  # task/target_root data nothing has told Rails yet.
  def self.find_or_create_for_bus!(run_id)
    find_by(run_id: run_id) || create_for_bus!(run_id)
  end

  def self.create_for_bus!(run_id)
    create!(
      run_id: run_id,
      task: "(unspecified — auto-created from bus activity)",
      target_root: Rails.application.config.x.workflow_target_root.presence || "(unspecified)",
      launcher_variant: "codex",
      status: "running"
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by!(run_id: run_id)
  end

  def active?
    NON_TERMINAL_STATUSES.include?(status)
  end

  def terminal?
    !active?
  end

  def to_param
    run_id
  end

  # Replaces WorkflowBus#publishRunStatus -- updates the free-text
  # phase/owner/summary WorkflowRunStatus mirrors, and emits the matching
  # "run.status" bus event.
  def publish_phase!(phase:, owner:, summary:)
    update!(phase: phase, phase_owner: owner, phase_summary: summary, phase_updated_at: Time.current)
    BusEvent.publish("run.status", run_id: run_id, payload: {
      runId: run_id, phase: phase, owner: owner, summary: summary
    })
  end

  def phase_status_json
    return nil if phase.blank?

    { runId: run_id, phase: phase, owner: phase_owner, summary: phase_summary, at: phase_updated_at&.iso8601(3) }
  end
end
