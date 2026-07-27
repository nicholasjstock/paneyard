class TelegramConversation < ApplicationRecord
  belongs_to :workspace, optional: true
  has_many :workspace_admin_chat_messages, dependent: :nullify

  validates :telegram_chat_id, presence: true, uniqueness: true
  validates :telegram_user_id, presence: true
end
