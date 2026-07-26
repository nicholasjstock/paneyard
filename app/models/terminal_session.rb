# Rails-owned bookkeeping for a workspace's plain interactive shell
# session. The tracked pid is a PTY-attached process group leader spawned by
# Orchestrator::TerminalSessionRunner -- see that module for spawn/reattach/
# resume/stop. The transcript lives in log_path (raw pty scrollback), not in
# per-turn DB rows.
class TerminalSession < ApplicationRecord
  STATUSES = %w[starting running exited].freeze
  ACTIVE_STATUSES = %w[starting running].freeze

  belongs_to :workspace

  validates :status, inclusion: { in: STATUSES }
  validates :workspace_id, uniqueness: true

  after_commit :broadcast_refresh

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  private

  def broadcast_refresh
    Turbo::StreamsChannel.broadcast_refresh_to("terminal_session_#{id}")
  end
end
