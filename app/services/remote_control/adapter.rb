module RemoteControl
  # What a chat platform has to provide for the operator to drive run sessions
  # from it. RemoteControl::Processor owns everything else -- the commands,
  # finding a run, the focused run, talking to sessions, paging a pane -- so an
  # adapter is only transport and rendering. Telegram
  # (RemoteControl::Adapters::Telegram::Adapter) is the reference.
  #
  # An adapter must:
  #
  #   - receive messages (poll, gateway, webhook: its own business) and hand
  #     each one to Processor.call(adapter, message) as a RemoteControl::Message
  #     -- and only ones from a direct, one-to-one chat with the operator: a
  #     group or channel would let other people read panes;
  #   - say whether it is configured, and who is allowed (allowed_user_ids);
  #   - send plain text and a pane (monospace, never interpreted), and report
  #     how long one message may be.
  #
  # It may also edit a sent pane (live /pane), render Markdown (recaps),
  # publish a command menu, and make commands tappable. The defaults below are
  # what Processor falls back to when it can't.
  #
  # Anyone on the allow-list can type into sessions with full access to their
  # worktrees -- a shell on this machine -- so an adapter must never widen who
  # is answered. And a sandbox instance (Orchestrator::Sandbox) must never
  # reach a real platform unless bin/sandbox opted this adapter in: enabled?
  # enforces that, and credentials should refuse too.
  class Adapter
    # A short, lowercase name ("telegram"): part of cache keys and of what
    # StreamPaneJob uses to find the adapter again.
    def name
      raise NotImplementedError
    end

    def enabled?
      Orchestrator::Sandbox.allows_remote_control?(name) && configured?
    end

    def configured?
      raise NotImplementedError
    end

    def allowed_user_ids
      raise NotImplementedError
    end

    def authorized?(user_id)
      allowed_user_ids.include?(user_id.to_s)
    end

    # The most characters one message may carry.
    def max_message_length
      raise NotImplementedError
    end

    # Returns the sent message's id (used to edit it later), or nil.
    def send_text(chat_id, text)
      raise NotImplementedError
    end

    # title is plain text ("run 33bd · name\nnote"), body is pane text to show
    # verbatim in a monospace block. Processor has already cut body to fit
    # pane_capacity(title). Returns the sent message's id, or nil.
    def send_pane(chat_id, title, body)
      raise NotImplementedError
    end

    # How much pane text fits in one message under this title, after
    # whatever the monospace markup costs.
    def pane_capacity(title)
      max_message_length - title.length - 96
    end

    # Whether edit_pane works; without it /pane sends the pane once instead
    # of keeping it live.
    def supports_edit?
      false
    end

    def edit_pane(chat_id, message_id, title, body)
      raise NotImplementedError
    end

    # A recap is the session's own Markdown report. Plain text is the fallback.
    def send_markdown(chat_id, markdown)
      send_text(chat_id, markdown)
    end

    # How a command naming a run is written in a list, e.g. "/pane_33bd" where
    # the platform makes that tappable. Processor accepts both forms.
    def command_link(command, ref)
      "/#{command} #{ref}"
    end

    # commands: [[name, description], ...] (RemoteControl::Commands.menu).
    # Platforms without a command menu ignore it.
    def publish_commands(commands); end

    # Distinguishes one bot or account from another, so a menu is republished
    # when the adapter is pointed at a different one.
    def identity
      name
    end
  end
end
