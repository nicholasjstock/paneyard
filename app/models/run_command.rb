# Rails-owned bookkeeping for a run-scoped background process: a command a
# worker started that must outlive that worker (see start_run_command). The
# tracked pid is the process group leader started by
# Orchestrator::RunCommandRunner -- see that module for spawn/reconcile/stop.
class RunCommand < ApplicationRecord
  STATUSES = %w[pending running exited failed stopped lost].freeze
  ACTIVE_STATUSES = %w[pending running].freeze

  EVENT_TYPES = {
    "running" => "command.started",
    "exited" => "command.exited",
    "failed" => "command.failed",
    "stopped" => "command.stopped",
    "lost" => "command.lost"
  }.freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, inverse_of: :run_commands

  validates :command_id, presence: true, uniqueness: true
  validates :run_id, :executable, :working_directory, :status, presence: true
  validates :status, inclusion: { in: STATUSES }

  before_validation :assign_command_id, on: :create

  after_update_commit :publish_status_event, if: :saved_change_to_status?

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def terminal?
    !active?
  end

  def to_param
    command_id
  end

  # Environment values are withheld here -- a different worker on the same
  # run can read this via get_run_command/list_run_commands, and env vars
  # may carry secrets the starting worker set (tokens, credentials). Only
  # the spawned process itself needs the values.
  def as_json(*)
    {
      commandId: command_id,
      runId: run_id,
      requestedByWorkerId: requested_by_worker_id,
      executable: executable,
      arguments: arguments,
      workingDirectory: working_directory,
      environment: environment.to_h.keys,
      purpose: purpose,
      pid: pid,
      processGroupId: process_group_id,
      status: status,
      exitCode: exit_code,
      signal: signal,
      logPath: log_path,
      startedAt: started_at&.iso8601(3),
      finishedAt: finished_at&.iso8601(3),
      lastCheckedAt: last_checked_at&.iso8601(3),
      failureMessage: failure_message
    }
  end

  private

  def assign_command_id
    self.command_id ||= SecureRandom.uuid
  end

  def publish_status_event
    event_type = EVENT_TYPES[status]
    return unless event_type

    BusEvent.publish(event_type, run_id: run_id, payload: {
      runId: run_id, commandId: command_id, executable: executable, purpose: purpose,
      status: status, exitCode: exit_code, pid: pid
    })
  end
end
