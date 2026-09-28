module RemoteControl
  # How a run looks in any chat. Shared by Processor, which answers commands,
  # and StreamPaneJob, which keeps a live pane message current, so both render
  # a run identically; each adapter only decides how a title, a pane and
  # Markdown look on its platform.
  #
  # Every message about a run starts with "run <ref> · ", which is how
  # Processor routes a reply to that message back to the run.
  module Views
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

      state = Orchestrator::Runner.for(session.run.workspace).agent_state(session.herdr_pane_id)
      state&.dig("agent_status").presence || session.agent_status
    rescue Orchestrator::Runner::Error
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

    # The pane's newest lines as one [title, body] message, trimmed from the
    # top to fit.
    def pane(adapter, run, text, note:)
      pane_pages(adapter, run, text, note:).first
    end

    # The pane's newest lines as up to max_pages [title, body] messages, oldest
    # first, each filled from the bottom up. Whatever still does not fit is
    # dropped from the top, and the first page says so rather than pass itself
    # off as the start.
    def pane_pages(adapter, run, text, note:, max_pages: 1)
      # Room for the longest note a page gets below.
      limit = adapter.pane_capacity("#{header(run)}\n#{note} · 5/5 · 10000 older lines did not fit")
      lines = text.to_s.rstrip.lines
      pages = []
      while pages.size < max_pages
        lines.pop while lines.last&.strip == ""
        break if lines.empty?

        page = Chunker.tail(lines.join, limit:)
        pages.unshift(page)
        lines = lines[0...-page.lines.size]
      end
      pages = [ "" ] if pages.empty?

      pages.each_with_index.map do |body, index|
        page_note = note
        page_note += " · #{index + 1}/#{pages.size}" if pages.size > 1
        page_note += " · #{lines.size} older lines did not fit" if index.zero? && lines.any?
        [ "#{header(run)}\n#{page_note}", body ]
      end
    end

    def send_recap(adapter, chat_id, run, checkpoint, footer: nil)
      adapter.send_text(chat_id, [ "#{header(run)}\nRecap: #{checkpoint.outcome}, #{ago(checkpoint.created_at)}", footer ].compact.join("\n"))
      Chunker.split(checkpoint.summary.presence || "(empty summary)", limit: adapter.max_message_length - 96).each do |chunk|
        adapter.send_markdown(chat_id, chunk)
      rescue StandardError
        # Rendering is a nicety; the recap itself must still arrive.
        adapter.send_text(chat_id, chunk)
      end
    end
  end
end
