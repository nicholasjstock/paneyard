module RemoteControl
  # Every chat platform the operator can drive sessions from. To add one,
  # implement RemoteControl::Adapter under RemoteControl::Adapters::<Name>,
  # give it a way to receive messages (a recurring poll job like
  # PollTelegramUpdatesJob, a webhook route, ...), register it here, and add
  # its sandbox opt-in to bin/sandbox (see Orchestrator::Sandbox).
  module Adapters
    module_function

    def registry
      { "telegram" => Telegram::Adapter }
    end

    def fetch(name)
      registry.fetch(name.to_s).new
    end

    def enabled
      registry.values.map(&:new).select(&:enabled?)
    end
  end
end
