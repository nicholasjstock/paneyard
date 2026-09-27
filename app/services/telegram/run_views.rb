module Telegram
  # How a run looks in Telegram. Shared by UpdateProcessor, which answers
  # commands, and StreamTelegramPaneJob, which keeps a live pane message
  # current, so both render a run identically.
  #
  # Every message about a run starts with "run <ref> · ", which is how
  # UpdateProcessor routes a reply to that message back to the run.
  module RunViews
    module_function

    LIVE_PANE_LINES = 40

    def header(run)
      "run #{short_ref(run)} · #{run.worktree_name.presence || run.run_id}"
    end

    def short_ref(run)
      run.run_id.split("-").last
    end

    def ago(time)
      "#{ActionController::Base.helpers.time_ago_in_words(time)} ago"
    end

    # What herdr says the agent is doing right now. The stored agent_status is
    # only refreshed every 30 seconds by RunSessionReconcileJob, which is too
    # stale to decide between "show the recap" and "show the live pane" for a
    # session the operator just sent more work to.
    def live_agent_status(session)
      return session.agent_status if session.pane_gone?

      Orchestrator::Herdr.agent_get(session.herdr_pane_id)["agent_status"].presence || session.agent_status
    rescue Orchestrator::Herdr::Error
      session.agent_status
    end

    # The session's own newest report, if it has made one and has not gone back
    # to work since. That report is then the best description of where the run
    # stands. Otherwise there is nothing newer than the pane itself.
    def current_recap(session)
      checkpoint = session.checkpoints.last
      return nil if checkpoint.nil? || live_agent_status(session) == "working"

      checkpoint
    end

    # The pane's newest lines as one HTML message, trimmed from the top to fit.
    def pane_html(run, text, note:)
      head = ERB::Util.html_escape("#{header(run)}\n#{note}")
      body = Chunker.tail(text.to_s, limit: Client::MAX_MESSAGE_LENGTH - head.length - 64)
      "#{head}\n<pre>#{ERB::Util.html_escape(body.presence || ' ')}</pre>"
    end

    def send_recap(client, chat_id, run, checkpoint, footer: nil)
      client.send_message(chat_id:, text: [ "#{header(run)}\nRecap: #{checkpoint.outcome}, #{ago(checkpoint.created_at)}", footer ].compact.join("\n"))
      Chunker.split(checkpoint.summary.presence || "(empty summary)").each do |chunk|
        client.send_rich_message(chat_id:, markdown: chunk)
      rescue StandardError
        # Rendering is a nicety; the recap itself must still arrive.
        client.send_message(chat_id:, text: chunk)
      end
    end
  end
end
