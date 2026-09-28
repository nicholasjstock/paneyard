# Telegram's way in for remote control (RemoteControl::Adapters::Telegram),
# every few seconds from config/recurring.yml.
class PollTelegramUpdatesJob < ApplicationJob
  queue_as :default

  def perform
    RemoteControl::Adapters::Telegram::Poller.call
  end
end
