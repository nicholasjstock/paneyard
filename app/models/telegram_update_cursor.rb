class TelegramUpdateCursor < ApplicationRecord
  validates :name, presence: true, uniqueness: true

  def self.for_bot
    find_or_create_by!(name: "default")
  end
end
