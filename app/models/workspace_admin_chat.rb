# Rails-owned bookkeeping for a workspace's admin chat: a persistent,
# non-interactive conversation with either the claude or codex CLI (see
# Orchestrator::WorkspaceAdminChat::Runner). Unlike TerminalSession (a raw,
# interactive pty), each turn is a single non-interactive CLI invocation --
# no xterm.js, no pty -- and both drivers' resumable session ids are kept
# side by side so switching active_provider never loses either history.
class WorkspaceAdminChat < ApplicationRecord
  PROVIDERS = %w[claude codex opencode].freeze
  STATUSES = %w[idle running failed].freeze

  # Hardcoded rather than free text: the CLIs only accept a known alias/id
  # anyway, and a dropdown scoped to the selected provider means an invalid
  # cross-provider value (a codex id while claude is active) can't happen.
  # Ordered cheapest to most expensive -- #model_for defaults to the first
  # entry, so an unset model starts cheap rather than jumping straight to
  # the priciest tier.
  CLAUDE_MODELS = %w[haiku sonnet opus].freeze
  CODEX_MODELS = [ Orchestrator::WorkerSpawner::CODEX_SMALL_MODEL, Orchestrator::WorkerSpawner::CODEX_PROMOTED_MODEL ].freeze
  OPENCODE_MODELS = %w[ollama/qwen2.5-coder:7b].freeze

  belongs_to :workspace
  has_many :messages, -> { order(:created_at) }, class_name: "WorkspaceAdminChatMessage", dependent: :destroy

  validates :active_provider, inclusion: { in: PROVIDERS }
  validates :status, inclusion: { in: STATUSES }
  validates :workspace_id, uniqueness: true

  after_commit :broadcast_refresh

  def active?
    active_turn_id.present?
  end

  # The transcript actually shown: claude and codex hold entirely separate
  # context (separate CLI sessions -- see session_id_for), so a message
  # tagged for the other provider is no more part of "this conversation"
  # than a session that had never been resumed. Filtering here rather than
  # deleting the other provider's rows keeps both histories intact underneath
  # switching active_provider back and forth.
  def visible_messages
    messages.where(provider: active_provider)
  end

  def session_id_for(provider)
    case provider
    when "codex" then codex_session_id
    when "opencode" then opencode_session_id
    else claude_session_id
    end
  end

  def set_session_id!(provider, session_id)
    return if session_id.blank?

    update!(case provider
            when "codex" then { codex_session_id: session_id }
            when "opencode" then { opencode_session_id: session_id }
            else { claude_session_id: session_id }
            end)
  end

  def model_for(provider)
    stored = case provider
             when "codex" then codex_model
             when "opencode" then opencode_model
             else claude_model
             end
    stored.presence || self.class.models_for(provider).first
  end

  def self.models_for(provider)
    case provider
    when "codex" then CODEX_MODELS
    when "opencode" then OPENCODE_MODELS
    else CLAUDE_MODELS
    end
  end

  def reset_session!(provider)
    update!(case provider
            when "codex" then { codex_session_id: nil }
            when "opencode" then { opencode_session_id: nil }
            else { claude_session_id: nil }
            end)
  end

  private

  def broadcast_refresh
    Turbo::StreamsChannel.broadcast_refresh_to("workspace_admin_chat_#{id}")
  end
end
