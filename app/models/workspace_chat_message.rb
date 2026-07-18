class WorkspaceChatMessage < ApplicationRecord
  ROLES = %w[user assistant].freeze
  STATUSES = %w[queued processing completed failed].freeze

  belongs_to :workspace_chat, touch: true

  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :content, presence: true

  after_commit :broadcast_refresh

  private

  def broadcast_refresh
    Turbo::StreamsChannel.broadcast_refresh_to("workspace_chat_#{workspace_chat_id}")
  end
end
