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
#           out there (workspace_checkouts).
#
# Named RegisteredRunner rather than Runner, because inside the Orchestrator
# module Runner is the runner interface itself.
class RegisteredRunner < ApplicationRecord
  self.table_name = "runners"

  LOCAL_NAME = "local".freeze
  KINDS = %w[local remote].freeze

  has_many :runs, foreign_key: :runner_id, inverse_of: :runner, dependent: :restrict_with_error
  has_many :workspace_checkouts, foreign_key: :runner_id, inverse_of: :runner, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :max_concurrent_runs, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :url, presence: true, if: :remote?
  validates :url, absence: true, if: :local?
  validates :orchestrator_url, absence: true, if: :local?
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

  private

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
