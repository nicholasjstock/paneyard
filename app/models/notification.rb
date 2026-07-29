class Notification < ApplicationRecord
  belongs_to :workspace
  belongs_to :user_question

  validates :kind, :title, :body, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :recent_first, -> { order(created_at: :desc) }

  def unread?
    read_at.nil?
  end

  def mark_read!
    update!(read_at: Time.current) if unread?
  end

  def target_url
    link_url.presence || user_question.github_comment_url.presence || user_question.run&.conversation_url
  end
end
