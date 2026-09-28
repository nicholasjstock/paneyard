require "digest"

module Telegram
  # Remote control for the operator's live run sessions, from their phone.
  #
  # Every command is a direct, deterministic call onto something Rails already
  # owns -- a session's pane (RunSessionRunner.snapshot), its checkpoints, or
  # its live input (RunSessionRunner.prompt!). There is no agent in between:
  # the session itself is the intelligence, and text the operator sends it is
  # delivered verbatim.
  #
  # Security: an allow-listed Telegram account can type into sessions that run
  # with full access to their worktrees, which makes it a shell on this
  # machine. So only allow-listed users are answered at all, and only in their
  # private chat with the bot -- never in a group, where other members could
  # read panes.
  class UpdateProcessor
    HELP = <<~TEXT.freeze
      /panes — every live session
      /idle — live sessions that are not working
      /pane <run> — its latest recap, or its live pane if it hasn't reported since it last started working
      /screen <run> [lines] — the raw newest lines of its pane, once
      /report <run> — its newest recap, even after the session is closed
      /send <run> <text> — type an instruction into its pane

      <run> is the run id's last four characters (e.g. 33bd), a prefix of its worktree name, or the full run id.
      Reply to any message that starts with "run <id> ·" to send your reply to that run.
    TEXT

    DEFAULT_PANE_LINES = 40
    MAX_PANE_LINES = 200
    # A run is named in the first line of every message about it, which is how
    # a reply to that message finds its way back to the run.
    RUN_HEADER = /\Arun ([\w.-]+) ·/

    def self.call(update)
      new(update.deep_stringify_keys).call
    end

    def initialize(update)
      @update = update
      @client = Client.new
    end

    def call
      message = @update["message"]
      return unless message && authorized?(message)

      @chat_id = message.dig("chat", "id")
      text = message["text"].to_s.strip
      return if text.empty?

      if text.start_with?("/")
        dispatch(text)
      elsif (ref = replied_run_ref(message))
        send_to(ref, text)
      else
        reply("Reply to a message about a run to talk to it, or use /send <run> <text>.\n\n#{HELP}")
      end
    end

    private

    # "/pane_33bd 80" and "/pane 33bd 80" are the same command -- the first
    # form is what the lists print, because Telegram makes it tappable.
    def dispatch(text)
      command, rest = text.split(/\s+/, 2)
      command = command.delete_prefix("/").sub(/@\w+\z/, "")
      command, inline_ref = command.split("_", 2)
      rest = [ inline_ref, rest ].compact.join(" ")

      case command
      when "panes" then list_panes(idle_only: false)
      when "idle" then list_panes(idle_only: true)
      when "pane" then show_pane(rest.split(/\s+/).first)
      when "screen"
        ref, lines = rest.split(/\s+/, 2)
        show_screen(ref, lines)
      when "report" then show_report(rest.split(/\s+/).first)
      when "send"
        ref, body = rest.split(/\s+/, 2)
        return reply("Usage: /send <run> <text>") if ref.blank? || body.blank?

        send_to(ref, body)
      else reply(HELP)
      end
    end

    def list_panes(idle_only:)
      runs = live_runs
      runs = runs.select { |run| idle?(run.live_session) } if idle_only
      header = "#{runs.size} #{idle_only ? 'idle' : 'live'} session#{'s' unless runs.size == 1} " \
        "(#{Orchestrator::RunConcurrency.in_flight}/#{Orchestrator::RunConcurrency.limit} slots in use)"
      return reply(header) if runs.empty?

      reply_long(([ header ] + runs.map { |run| pane_line(run) }).join("\n\n"))
    end

    def pane_line(run)
      session = run.live_session
      ref = short_ref(run)
      checkpoint = run.checkpoints.last
      [
        "#{ref} · #{run.workspace.name} · #{activity(session)}",
        "  #{run.worktree_name.presence || run.run_id}",
        ("  last report: #{checkpoint.outcome}, #{ago(checkpoint.created_at)}" if checkpoint),
        "  /pane_#{ref} /screen_#{ref}"
      ].compact.join("\n")
    end

    # What the operator wants to know about a session: if it has reported and
    # not gone back to work since, its recap says where things stand. If not,
    # the pane is all there is, so show it live until the session reports
    # (StreamTelegramPaneJob), when the recap follows on its own.
    def show_pane(ref)
      run = resolve(ref) or return
      session = run.live_session
      if (checkpoint = RunViews.current_recap(session))
        return RunViews.send_recap(@client, @chat_id, run, checkpoint, footer: "/screen_#{short_ref(run)} for the raw pane")
      end

      stream_pane(run, session)
    end

    def stream_pane(run, session)
      text = Orchestrator::RunSessionRunner.snapshot(session, lines: RunViews::LIVE_PANE_LINES)
      return reply("#{header(run)}\nherdr could not read this session's pane.") if text.nil?

      last_checkpoint = session.checkpoints.last
      minutes = StreamTelegramPaneJob::DURATION.in_minutes.to_i
      note = "#{last_checkpoint ? 'Working again since its last report' : 'No report yet'} · live for #{minutes} min"
      sent = @client.send_message(chat_id: @chat_id, parse_mode: "HTML", text: RunViews.pane_html(run, text, note:))
      return unless sent.is_a?(Hash) && sent["message_id"]

      StreamTelegramPaneJob.set(wait: StreamTelegramPaneJob::INTERVAL).perform_later(
        chat_id: @chat_id, message_id: sent["message_id"], session_id: session.id,
        since_checkpoint_id: last_checkpoint&.id.to_i, until_time: StreamTelegramPaneJob::DURATION.from_now.iso8601,
        last_digest: Digest::SHA256.hexdigest(text)
      )
    end

    def show_screen(ref, lines)
      run = resolve(ref) or return
      session = run.live_session
      count = (lines.presence || DEFAULT_PANE_LINES).to_i.clamp(1, MAX_PANE_LINES)
      text = Orchestrator::RunSessionRunner.snapshot(session, lines: count)
      return reply("#{header(run)}\nherdr could not read this session's pane.") if text.nil?

      note = "Screen · #{session.agent_status.presence || session.status}"
      @client.send_message(chat_id: @chat_id, parse_mode: "HTML", text: RunViews.pane_html(run, text, note:))
    end

    def show_report(ref)
      run = resolve(ref, live_only: false) or return
      checkpoint = run.checkpoints.last
      return reply("#{header(run)}\nNo report yet.") unless checkpoint

      RunViews.send_recap(@client, @chat_id, run, checkpoint)
    end

    def send_to(ref, text)
      run = resolve(ref) or return
      Orchestrator::RunSessionRunner.prompt!(run.live_session, text)
      Rails.logger.info("[telegram] sent #{text.length} characters to #{run.run_id}")
      reply("#{header(run)}\nSent.")
    rescue Orchestrator::RunSessionRunner::Error, Orchestrator::Runner::Error => error
      reply("#{header(run)}\nNot sent: #{error.message}")
    end

    # Runs whose session is live, newest first. With live_only: false, recent
    # finished runs resolve too, so /report still works after Close session.
    def resolve(ref, live_only: true)
      return refuse("Which run? Try /panes.") if ref.blank?

      candidates = live_only ? live_runs : Run.includes(:workspace).order(created_at: :desc).limit(50).to_a
      matches = candidates.select { |run| matches?(run, ref) }
      exact = matches.select { |run| run.run_id == ref || short_ref(run) == ref }
      matches = exact if exact.any?

      case matches.size
      when 1 then matches.first
      when 0 then refuse("No #{'live ' if live_only}run matches #{ref.inspect}. Try /panes.")
      else refuse("#{ref.inspect} matches more than one run:\n#{matches.map { |run| "#{short_ref(run)} · #{run.worktree_name}" }.join("\n")}")
      end
    end

    def matches?(run, ref)
      run.run_id == ref || short_ref(run) == ref || run.worktree_name.to_s.start_with?(ref)
    end

    def live_runs
      Run.joins(:run_sessions).merge(RunSession.live).includes(:workspace).order(created_at: :desc).distinct.to_a
    end

    # Not working, so waiting on the operator: herdr sees it idle, finished or
    # blocked at a prompt, or it has reported idle and herdr hasn't said
    # otherwise since. agent_status is refreshed every 30 seconds by
    # RunSessionReconcileJob, so it can lag by that much.
    def idle?(session)
      return false if session.agent_status == "working"

      session.agent_status.in?(%w[idle done blocked]) || session.run.status == "awaiting_review"
    end

    def activity(session)
      status = session.agent_status.presence || session.status
      idle?(session) ? "#{status} (idle)" : status
    end

    def replied_run_ref(message)
      message.dig("reply_to_message", "text").to_s.lines.first.to_s[RUN_HEADER, 1]
    end

    def header(run) = RunViews.header(run)
    def short_ref(run) = RunViews.short_ref(run)
    def ago(time) = RunViews.ago(time)

    def reply(text)
      @client.send_message(chat_id: @chat_id, text:)
    end

    # Replies, and returns nil so a failed lookup can `or return`.
    def refuse(text)
      reply(text)
      nil
    end

    def reply_long(text)
      Chunker.split(text).each { |chunk| reply(chunk) }
    end

    def authorized?(message)
      user_id = message.dig("from", "id")
      return false if message.dig("from", "is_bot")
      return false unless message.dig("chat", "type") == "private" && message.dig("chat", "id").to_s == user_id.to_s

      Configuration.authorized_user?(user_id.to_s)
    end
  end
end
