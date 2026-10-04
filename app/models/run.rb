# One queued job: a task, the worktree it runs in, and what became of it.
#
# A run does not decompose into steps. It is claimed by RunDispatchJob when a
# concurrency slot frees, handed to one interactive session that owns it from
# start to finish (RunSession), and ends when that session reports back.
class Run < ApplicationRecord
  # Removed in 20260709175910_remove_scenario_and_frontend_url_from_runs,
  # 20260817120200_simplify_runs and 20260926170000_remove_pull_request_publication.
  # Kept ignored so a long-lived Rails process
  # with stale schema metadata does not try to write them.
  self.ignored_columns += %w[
    scenario frontend_url active_branch_key phase phase_owner phase_summary phase_updated_at
    supervisor_pid capacity_available_at interactive_mode log_path parent_run_id
    github_issue_url github_issue_status conversation_pr_status
    publication_status publication_started_at publication_completed_at publication_error
    pull_request_url last_pull_request_comment_id
  ]

  LAUNCHER_VARIANTS = %w[claude codex].freeze
  # queued          -- created, waiting for a concurrency slot
  # launching       -- claimed by the dispatcher; worktree/session coming up
  # running         -- a live session owns it
  # awaiting_review -- session reported idle; the operator decides what next
  STATUSES = %w[queued launching running awaiting_review stopped completed failed].freeze
  NON_TERMINAL_STATUSES = %w[queued launching running awaiting_review].freeze
  # Something is, or is about to be, working in the run's worktree.
  SESSION_ACTIVE_STATUSES = %w[queued launching running].freeze

  belongs_to :workspace

  # Ordinary integer FK, unlike the string-run_id associations below: a
  # RunSession is Rails' own bookkeeping and never crosses the MCP wire, so it
  # has no reason to join on the natural key.
  has_many :run_sessions, dependent: :destroy
  # The run's own history: one row per time a session reported going idle.
  has_many :checkpoints, -> { chronological }, class_name: "RunCheckpoint", inverse_of: :run, dependent: :destroy


  validates :run_id, presence: true, uniqueness: true
  validates :task, presence: true
  validates :target_root, presence: true
  # The branch the run's worktree starts from and its work merges back into.
  # Fixed when the run is queued (the workspace's default unless the caller
  # named one), so changing the workspace's default later does not move it.
  validates :base_branch, presence: true, format: { with: Orchestrator::GitRef::BRANCH_FORMAT, message: "is not a valid branch name" }
  # On create only: runs from before opencode was dropped still settle.
  validates :launcher_variant, inclusion: { in: LAUNCHER_VARIANTS }, on: :create
  # Blank means the driver's default (Orchestrator::DefaultModels). A model id
  # becomes one argv element of the session's command line, so it may never
  # look like a flag.
  validates :model, format: { with: %r{\A[A-Za-z0-9][\w.:/\[\]@-]*\z} }, allow_blank: true
  validates :status, inclusion: { in: STATUSES }
  validate :launch_artifacts_are_safe
  # queue_run's `after` (Orchestrator::RunDependencies): run_ids whose work
  # must be merged into this run's base branch before it first launches.
  validate :dependency_run_ids_are_a_list

  before_validation :default_base_branch, on: :create

  scope :active, -> { where(status: NON_TERMINAL_STATUSES) }
  scope :queued, -> { where(status: "queued") }


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
      target_root: default_workspace.repository_path,
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
  # run never has two live sessions at once -- see the partial unique
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

  # Nothing is working in the worktree any more: the run has finished, or is
  # awaiting review with its session closed.
  def session_over?
    !status.in?(SESSION_ACTIVE_STATUSES) && live_session.nil?
  end

  # Still on disk after its session ended. WorktreeJanitor removes every such
  # worktree whose work is in its base branch or pushed, so one that remains
  # holds work that exists nowhere else, and is kept until the operator deals
  # with it.
  #
  # target_root existing as a directory is not enough: it is the workspace's
  # repository until GitWorktree.provision! records the run's own worktree,
  # and a worktree already removed can leave an inert leftover directory
  # behind. The runner asks git whether target_root is actually a linked
  # worktree of the repository, ruling out both.
  def kept_worktree?
    managed_worktree? && target_root.present? && session_over? &&
      Orchestrator::Runner.for(workspace).worktree_registered?(repository_path: workspace.repository_path, path: target_root)
  end

  def to_param
    run_id
  end

  private

  def default_base_branch
    self.base_branch = workspace&.default_base_branch if base_branch.blank?
  end

  def dependency_run_ids_are_a_list
    unless dependency_run_ids.is_a?(Array) && dependency_run_ids.all? { |id| id.is_a?(String) && id.present? }
      errors.add(:dependency_run_ids, "must be a list of run ids")
    end
  end

  def launch_artifacts_are_safe
    Array(launch_artifacts).each do |artifact|
      name = artifact["name"] || artifact[:name]
      if name.blank? || name.include?("/") || name.include?("\\") || [ ".", ".." ].include?(name)
        errors.add(:launch_artifacts, "contains an unsafe artifact name")
      end
    end
  end
end
