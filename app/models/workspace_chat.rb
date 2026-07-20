class WorkspaceChat < ApplicationRecord
  STATUSES = %w[idle processing failed].freeze
  LAUNCHER_VARIANTS = %w[claude codex].freeze

  belongs_to :workspace
  has_many :messages, class_name: "WorkspaceChatMessage", dependent: :destroy

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :launcher_variant, inclusion: { in: LAUNCHER_VARIANTS }
  validates :workspace_id, uniqueness: true

  after_commit :broadcast_refresh

  private

  def broadcast_refresh
    Turbo::StreamsChannel.broadcast_refresh_to("workspace_chat_#{id}")
  end
end
