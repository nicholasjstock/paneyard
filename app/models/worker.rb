require "digest"

# Replaces WorkflowWorkerRecord (workflow-worker-runtime.ts) as the source
# of truth for the worker registry. Wire format (#as_json) mirrors that TS
# type field-for-field.
#
# Unlike SpawnRequest/UserQuestion/BusEvent, worker_id is NOT
# server-generated: supervisor-loop.ts pre-generates it so it can claim a
# spawn request's fulfilledWorkerId *before* the worker actually exists
# (deliberate race-avoidance -- see supervisor-loop.ts's spawnRequestedWorkers).
# Accepting a client-supplied id here and treating it as authoritative is
# required for that ordering to keep working.
class Worker < ApplicationRecord
  ROLES = %w[orchestrator worker planner infrastructure chaperone project_init verifier].freeze
  STATUSES = %w[launching running stopped].freeze
  OUTPUT_TAIL_MAX_CHARS = 1_200

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, optional: true, inverse_of: :workers

  validates :worker_id, presence: true, uniqueness: true
  validates :run_id, :role, :nickname, :reason, :scope, :pid, :prompt_path, :log_path,
            :last_message_path, :env_path, :command, presence: true
  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }

  before_validation :assign_started_at, on: :create

  after_create_commit :publish_spawned_event, if: -> { status == "running" }
  after_update_commit :publish_running_event
  after_update_commit :publish_stopped_event

  scope :active, -> { where(status: "running") }

  def self.issue_capability
    token = SecureRandom.hex(32)
    [ token, Digest::SHA256.hexdigest(token) ]
  end

  def self.authenticate_capability(token)
    return if token.blank?

    find_by(capability_token_digest: Digest::SHA256.hexdigest(token), status: %w[launching running])
  end

  def self.mark_handoff_completed!(run_id:, nickname: nil, role: nil)
    workers = where(run_id: run_id)
    workers = workers.where(nickname: nickname) if nickname.present?
    workers = workers.where(role: role) if role.present?

    workers.order(created_at: :desc).first&.update_column(:handoff_completed_at, Time.current)
  end

  def as_json(*)
    {
      workerId: worker_id,
      runId: run_id,
      role: role,
      nickname: nickname,
      reason: reason,
      scope: scope,
      status: status,
      pid: pid,
      promptPath: prompt_path,
      logPath: log_path,
      lastMessagePath: last_message_path,
      exitStatusPath: exit_status_path,
      exitCode: exit_code,
      model: model,
      executionMode: execution_mode,
      writeScope: write_scope,
      allowedPaths: allowed_paths,
      agentTurnCount: agent_turn_count,
      inputTokens: input_tokens,
      outputTokens: output_tokens,
      cacheReadInputTokens: cache_read_input_tokens,
      cacheCreationInputTokens: cache_creation_input_tokens,
      totalCostUsd: total_cost_usd,
      outputTail: output_tail,
      envPath: env_path,
      command: command,
      args: args,
      startedAt: started_at.iso8601(3),
      stoppedAt: stopped_at&.iso8601(3),
      handoffCompletedAt: handoff_completed_at&.iso8601(3),
      stopReason: stop_reason
    }
  end

  def as_diagnostic_json
    {
      workerId: worker_id,
      runId: run_id,
      role: role,
      nickname: nickname,
      scope: scope,
      status: status,
      startedAt: started_at&.iso8601(3),
      stoppedAt: stopped_at&.iso8601(3),
      exitCode: exit_code,
      stopReason: stop_reason,
      model: model,
      executionMode: execution_mode,
      writeScope: write_scope,
      agentTurnCount: agent_turn_count,
      inputTokens: input_tokens,
      outputTokens: output_tokens,
      cacheReadInputTokens: cache_read_input_tokens,
      cacheCreationInputTokens: cache_creation_input_tokens,
      totalCostUsd: total_cost_usd,
      outputTail: output_tail
    }
  end

  private

  def output_tail
    tail = Orchestrator::LogReader.read_tail_lines(log_path, 12).to_s
    return if tail.blank?

    tail.length > OUTPUT_TAIL_MAX_CHARS ? "...#{tail.last(OUTPUT_TAIL_MAX_CHARS)}" : tail
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def assign_started_at
    self.started_at ||= Time.current
  end

  def publish_spawned_event
    BusEvent.publish("worker.spawned", run_id: run_id, payload: {
      runId: run_id, role: role, nickname: nickname, reason: reason, workerId: worker_id
    })
  end

  def publish_running_event
    publish_spawned_event if saved_change_to_status? && status == "running"
  end

  def publish_stopped_event
    return unless saved_change_to_status? && status == "stopped"

    BusEvent.publish("worker.stopped", run_id: run_id, payload: {
      runId: run_id, role: role, nickname: nickname, reason: reason, workerId: worker_id, stopReason: stop_reason
    })
  end
end
