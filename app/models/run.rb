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
  LAUNCH_STALE_AFTER = 30.seconds

  # Removed in 20260709175910_remove_scenario_and_frontend_url_from_runs.
  # Keep them ignored so a long-lived Rails process with stale schema
  # metadata does not try to write them during create/update.
  self.ignored_columns += %w[scenario frontend_url]

  LAUNCHER_VARIANTS = %w[claude codex].freeze
  STATUSES = %w[launching running stopping stopped completed failed].freeze
  NON_TERMINAL_STATUSES = %w[launching running stopping].freeze

  belongs_to :workspace

  has_many :spawn_requests, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :user_questions, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :workers, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :orchestrator_ticks, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :bus_events, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :run_context_entries, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :acceptance_criteria, class_name: "AcceptanceCriterion", foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :planner_decisions, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :step_attempts, foreign_key: :run_id, primary_key: :run_id, dependent: :destroy
  has_many :chaperone_reviews, foreign_key: :run_id, primary_key: :run_id, dependent: :destroy
  has_many :run_commands, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :review_assets, class_name: "RunReviewAsset", foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy

  validates :run_id, presence: true, uniqueness: true
  validates :task, presence: true
  validates :target_root, presence: true
  validates :launcher_variant, inclusion: { in: LAUNCHER_VARIANTS }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: NON_TERMINAL_STATUSES) }

  after_commit :broadcast_workspace_refresh, on: %i[create update]
  # Single integration point for all run-command cleanup: fires whether the
  # run reaches a terminal status via explicit cancellation (StopRunJob),
  # normal completion (TickRunJob), or failure -- no other job needs its own
  # cleanup call.
  after_commit :stop_active_run_commands, on: :update, if: -> { saved_change_to_status? && terminal? }

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
    default_workspace = Workspace.default
    unless default_workspace
      run = new
      run.errors.add(:workspace, "must exist before creating runs")
      raise ActiveRecord::RecordInvalid.new(run)
    end

    create!(
      run_id: run_id,
      task: "(unspecified — auto-created from bus activity)",
      workspace: default_workspace,
      target_root: default_workspace.source_root,
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

  def managed_worktree?
    worktree_name.present?
  end

  # branch_name is only ever set by GitWorktree.provision! after it actually
  # succeeds -- worktree_name alone is not proof of that: it's assigned
  # eagerly at run creation (RunsController#create), before LaunchRunJob
  # ever attempts provisioning, so a run whose provisioning failed (for
  # example, a dirty source checkout) can carry a worktree_name with no real
  # worktree behind it. Without this, publication_retryable? would offer a
  # retry that spawns the git worker's full .git write access directly
  # against the plain source checkout instead of a real isolated worktree.
  def publication_retryable?
    managed_worktree? && branch_name.present? && publication_status == "failed"
  end

  # At most one blocking question is ever open on a run at a time -- a
  # second one would just be noise once the operator is already the
  # blocker, and Orchestrator::PullRequestResume relies on "the sole open
  # blocking question" as the implicit target for a PR reply that doesn't
  # reference one by id.
  def open_blocking_question?
    user_questions.open_only.where(priority: "blocking").exists?
  end

  def capacity_blocked?(now: Time.current)
    capacity_available_at.present? && capacity_available_at > now
  end

  def alternate_launcher_variant
    (LAUNCHER_VARIANTS - [ launcher_variant ]).sole
  end

  # The root acceptance criterion whose subtree owns the next handoff.
  # Later root siblings stay pending until this branch resolves.
  def active_branch
    acceptance_criteria.roots.find_by(key: active_branch_key) if active_branch_key.present?
  end

  def launch_queued?(now: Time.current)
    status == "launching" && started_at.blank? && created_at <= now - LAUNCH_STALE_AFTER
  end

  def status_badge_label(now: Time.current)
    launch_queued?(now: now) ? "launch queued" : status
  end

  def status_badge_class(now: Time.current)
    launch_queued?(now: now) ? "queued" : status
  end

  def to_param
    run_id
  end

  # Replaces WorkflowBus#publishRunStatus -- updates the free-text
  # phase/owner/summary WorkflowRunStatus mirrors, and emits the matching
  # "run.status" bus event.
  def publish_phase!(phase:, owner:, summary:)
    with_lock do
      return phase_status_json if self.phase == phase && phase_owner == owner && phase_summary == summary

      update!(phase: phase, phase_owner: owner, phase_summary: summary, phase_updated_at: Time.current)
      BusEvent.publish("run.status", run_id: run_id, payload: {
        runId: run_id, phase: phase, owner: owner, summary: summary
      })
    end

    phase_status_json
  end

  def phase_status_json
    return nil if phase.blank?

    { runId: run_id, phase: phase, owner: phase_owner, summary: phase_summary, at: phase_updated_at&.iso8601(3) }
  end

  private

  def broadcast_workspace_refresh
    Turbo::StreamsChannel.broadcast_refresh_to("run_#{run_id}")
    Turbo::StreamsChannel.broadcast_refresh_to("workspace_#{workspace_id}_runs") if workspace_id.present?
  end

  def stop_active_run_commands
    run_commands.active.find_each do |command|
      Orchestrator::RunCommandRunner.stop(command: command, reason: "run reached terminal status: #{status}")
    end
  end
end
