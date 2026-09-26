# One queued job: a task, the worktree it runs in, and what became of it.
#
# A run does not decompose into steps. It is claimed by RunDispatchJob when a
# concurrency slot frees, handed to one interactive session that owns it from
# start to finish (RunSession), and ends when that session reports back.
class Run < ApplicationRecord
  # Removed in 20260709175910_remove_scenario_and_frontend_url_from_runs and
  # 20260817120200_simplify_runs. Kept ignored so a long-lived Rails process
  # with stale schema metadata does not try to write them.
  self.ignored_columns += %w[
    scenario frontend_url active_branch_key phase phase_owner phase_summary phase_updated_at
    supervisor_pid capacity_available_at interactive_mode log_path parent_run_id
    github_issue_url github_issue_status conversation_pr_status
  ]

  LAUNCHER_VARIANTS = %w[claude codex opencode].freeze
  # queued          -- created, waiting for a concurrency slot
  # launching       -- claimed by the dispatcher; worktree/session coming up
  # running         -- a live session owns it
  # awaiting_review -- session finished, PR open, waiting on a human to merge
  STATUSES = %w[queued launching running awaiting_review stopped completed failed].freeze
  NON_TERMINAL_STATUSES = %w[queued launching running awaiting_review].freeze

  belongs_to :workspace

  # Ordinary integer FK, unlike the string-run_id associations below: a
  # RunSession is Rails' own bookkeeping and never crosses the MCP wire, so it
  # has no reason to join on the natural key.
  has_many :run_sessions, dependent: :destroy
  # The run's own history: one row per time a session reported going idle.
  has_many :checkpoints, -> { chronological }, class_name: "RunCheckpoint", inverse_of: :run, dependent: :destroy

  has_many :bus_events, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy
  has_many :outbound_comments, class_name: "RunOutboundComment", foreign_key: :run_id, primary_key: :run_id, inverse_of: :run, dependent: :destroy

  validates :run_id, presence: true, uniqueness: true
  validates :task, presence: true
  validates :target_root, presence: true
  validates :launcher_variant, inclusion: { in: LAUNCHER_VARIANTS }
  validates :status, inclusion: { in: STATUSES }
  validate :launch_artifacts_are_safe

  scope :active, -> { where(status: NON_TERMINAL_STATUSES) }
  scope :queued, -> { where(status: "queued") }

  after_commit :broadcast_workspace_refresh, on: %i[create update]

  # Every bus-only entrypoint (a session's own MCP calls) can reference a
  # runId that was never launched through the UI. Placeholder values keep the
  # row valid without pretending to know real task/target_root data.
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

  # The one session currently holding this run's concurrency slot, if any. A
  # run accumulates sessions over its life (a pull-request comment can reopen
  # a closed one) but never has two live at once -- see the partial unique
  # index on run_sessions.
  def live_session
    run_sessions.live.order(created_at: :desc).first
  end

  def latest_session
    run_sessions.order(created_at: :desc).first
  end

  def managed_worktree?
    worktree_name.present?
  end

  # branch_name is only ever set by GitWorktree.provision! after it actually
  # succeeds -- worktree_name alone is not proof of that: it is assigned
  # eagerly at run creation, before StartRunSessionJob attempts provisioning,
  # so a run whose provisioning failed (a dirty source checkout, say) can
  # carry a worktree_name with no real worktree behind it.
  # Publication is an operator decision now, not something a finished session
  # triggers, so the run screen offers it for any run with a real branch rather
  # than only after a failed automatic attempt. "publishing" is excluded so a
  # double click cannot race two PublishRunJobs into `gh pr create`.
  def publishable?
    managed_worktree? && branch_name.present? && publication_status != "publishing"
  end

  def publication_retryable?
    publishable? && publication_status == "failed"
  end

  def to_param
    run_id
  end

  private

  def launch_artifacts_are_safe
    Array(launch_artifacts).each do |artifact|
      name = artifact["name"] || artifact[:name]
      if name.blank? || name.include?("/") || name.include?("\\") || [ ".", ".." ].include?(name)
        errors.add(:launch_artifacts, "contains an unsafe artifact name")
      end
    end
  end

  def broadcast_workspace_refresh
    Turbo::StreamsChannel.broadcast_refresh_to("run_#{run_id}")
    Turbo::StreamsChannel.broadcast_refresh_to("workspace_#{workspace_id}_runs") if workspace_id.present?
  end
end
