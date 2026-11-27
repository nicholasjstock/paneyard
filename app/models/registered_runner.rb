# A machine runs happen on (docs/multi-runner-plan.md): the runner registry.
# Orchestrator::Runner.for turns one into the runner object the orchestrator
# calls; this row is only the orchestrator's record of it.
#
#   local   this process, on this machine (Orchestrator::Runner::Local). There
#           is exactly one, with no url, and it always exists: .local makes
#           it the first time it is needed, so a fresh database (a schema
#           load, a sandbox, preflight) needs no seeding.
#   remote  another machine's runner-only process (bin/runner) at url, over
#           the tailnet (Orchestrator::Runner::Remote). It registers itself
#           (register_runner), saying where its sessions reach this
#           orchestrator (orchestrator_url) and where workspaces are checked
#           out there (workspace_checkouts) and where it clones the ones it
#           has not got (projects_dir).
#
# Every runner, local included, can be handed a workspace it has no checkout
# of: Orchestrator::WorkspaceCheckout clones it into the runner's projects
# directory (clone_projects_dir) as <projects dir>/<workspace name>.
#
# Named RegisteredRunner rather than Runner, because inside the Orchestrator
# module Runner is the runner interface itself.
class RegisteredRunner < ApplicationRecord
  self.table_name = "runners"

  LOCAL_NAME = "local".freeze
  KINDS = %w[local remote].freeze
  # The local runner's projects directory comes from here first (the herdr
  # plugin's setup writes it to the plugin's .env), then the projects_dir
  # column (update_settings, or the old projects_dir setting), then
  # DEFAULT_PROJECTS_DIR. A path on the runner's own machine, which expands
  # `~` there: the orchestrator never does.
  PROJECTS_DIR_ENV_VAR = "PANEYARD_PROJECTS_DIR".freeze
  DEFAULT_PROJECTS_DIR = "~/Source".freeze

  has_many :runs, foreign_key: :runner_id, inverse_of: :runner, dependent: :restrict_with_error
  has_many :workspace_checkouts, foreign_key: :runner_id, inverse_of: :runner, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :max_concurrent_runs, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :url, presence: true, if: :remote?
  validates :url, absence: true, if: :local?
  validates :orchestrator_url, absence: true, if: :local?
  validate :projects_dir_is_absolute
  validate :urls_are_http
  validate :one_local_runner, if: :local?

  before_destroy :keep_the_local_runner

  scope :remote, -> { where(kind: "remote") }

  # The local runner's row, made the first time anything asks for it.
  def self.local
    find_by(kind: "local") || create!(name: LOCAL_NAME, kind: "local")
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by!(kind: "local")
  end

  def local?
    kind == "local"
  end

  def remote?
    kind == "remote"
  end

  normalizes :projects_dir, with: ->(path) { path.strip.delete_suffix("/").presence }

  # Where this runner clones a workspace it has no checkout of, and where
  # create_workspace puts a new project on it: nil for a remote runner that
  # registered without one (it gets no clones). See PROJECTS_DIR_ENV_VAR.
  def clone_projects_dir
    return projects_dir.presence unless local?

    ENV[PROJECTS_DIR_ENV_VAR].to_s.strip.delete_suffix("/").presence || projects_dir.presence || DEFAULT_PROJECTS_DIR
  end

  # Where clone_projects_dir comes from: "env", "setting" (the column),
  # "default", or nil (none).
  def projects_dir_source
    return (projects_dir.present? ? "setting" : nil) unless local?
    return "env" if ENV[PROJECTS_DIR_ENV_VAR].to_s.strip.present?

    projects_dir.present? ? "setting" : "default"
  end

  private

  def projects_dir_is_absolute
    return if projects_dir.blank? || projects_dir.start_with?("/", "~")

    errors.add(:projects_dir, "must be an absolute path (or start with ~)")
  end

  def urls_are_http
    { url:, orchestrator_url: }.each do |attribute, value|
      next if value.blank?

      uri = URI.parse(value)
      errors.add(attribute, "must be an http(s) URL") unless %w[http https].include?(uri.scheme) && uri.host.present?
    rescue URI::InvalidURIError
      errors.add(attribute, "must be an http(s) URL")
    end
  end

  def one_local_runner
    errors.add(:kind, "local is taken: there is one local runner") if self.class.where(kind: "local").where.not(id:).exists?
  end

  def keep_the_local_runner
    return unless local?

    errors.add(:base, "the local runner cannot be removed")
    throw :abort
  end
end
