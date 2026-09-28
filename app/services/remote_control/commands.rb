module RemoteControl
  # The operator's commands, listed once: the help text and each adapter's
  # command menu both come from here, so they cannot drift from what
  # Processor actually answers.
  module Commands
    module_function

    LIST = [
      [ "panes", "", "Every live session" ],
      [ "idle", "", "Live sessions that are not working" ],
      [ "pane", "[run]", "Its latest recap, or its live pane" ],
      [ "screen", "[run] [lines]", "The raw newest lines of its pane" ],
      [ "report", "[run]", "Its newest recap, even after it closed" ],
      [ "send", "[run] <text>", "Type into its pane (or just type)" ],
      [ "help", "", "Every command, and how to name a run" ]
    ].freeze

    HELP = <<~TEXT.freeze
      /panes — every live session
      /idle — live sessions that are not working
      /pane <run> — its latest recap, or its live pane if it hasn't reported since it last started working
      /screen <run> [lines] — the raw newest lines of its pane, once (default 200, up to 1000, over as many as 5 messages)
      /report <run> — its newest recap, even after the session is closed
      /send <run> <text> — type an instruction into its pane
      /send <text>, or just type — to the run you last looked at or wrote to

      <run> is the run id's last four characters (e.g. 33bd), a prefix of its worktree name, or the full run id.
      Leave it out to mean the run you last looked at or wrote to (/screen 120, /pane, /report).
      Reply to any message that starts with "run <id> ·" to send your reply to that run.
    TEXT

    # [[name, description], ...] for a platform's command menu.
    def menu
      LIST.map { |name, args, description| [ name, [ args, description ].reject(&:empty?).join(" ") ] }
    end

    # Publishes the menu once per command list and bot, and again daily in case
    # it was changed by hand on the platform. A menu is a convenience, so
    # failing to set it never stops anything.
    def publish(adapter)
      key = "remote_control/commands/#{adapter.name}/#{Digest::SHA256.hexdigest([ adapter.identity, menu ].to_json)}"
      return if Rails.cache.read(key)

      adapter.publish_commands(menu)
      Rails.cache.write(key, true, expires_in: 1.day)
    rescue StandardError => error
      Rails.logger.warn("[remote_control] #{adapter.name}: could not set the command menu: #{error.message}")
    end
  end
end
