# Rails-owned bookkeeping for a workspace's interactive claude/codex terminal
# session. The tracked pid is a PTY-attached process group leader spawned by
# Orchestrator::TerminalSessionRunner -- see that module for spawn/reattach/
# resume/stop. Unlike WorkspaceChat's one-shot turns, the transcript lives in
# log_path (raw pty scrollback), not in per-turn DB rows.
class TerminalSession < ApplicationRecord
  LAUNCHER_VARIANTS = %w[claude codex].freeze
  STATUSES = %w[starting running exited].freeze
  ACTIVE_STATUSES = %w[starting running].freeze

  belongs_to :workspace

  validates :launcher_variant, inclusion: { in: LAUNCHER_VARIANTS }
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
