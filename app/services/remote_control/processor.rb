require "digest"

module RemoteControl
  # Remote control for the operator's live run sessions, from a chat app on
  # their phone -- whichever one the adapter speaks (RemoteControl::Adapter).
  #
  # Every command is a direct, deterministic call onto something Rails already
  # owns -- a session's pane (RunSessionRunner.snapshot), its checkpoints, or
  # its live input (RunSessionRunner.prompt!). There is no agent in between:
  # the session itself is the intelligence, and text the operator sends it is
  # delivered verbatim.
  #
  # Security: an allow-listed user can type into sessions that run with full
  # access to their worktrees, which makes it a shell on this machine. So only
  # the adapter's allow-listed users are answered at all, and the adapter only
  # hands over messages from a one-to-one chat -- never a group, where other
  # members could read panes.
  class Processor
    DEFAULT_PANE_LINES = 200
    MAX_PANE_LINES = 1000
    # /screen splits a long read over a few messages rather than cut it to
    # one; past this many it is dropped from the top.
    MAX_SCREEN_MESSAGES = 5
    # A run is named in the first line of every message about it, which is how
    # a reply to that message finds its way back to the run.
    RUN_HEADER = /\Arun ([\w.-]+) ·/
    # The run a chat last named (/pane, /screen, /report, /send <run>, or a
    # reply), which plain text and a bare /send <text> go to; every "Sent."
    # names the run, so the operator sees where it went. Ephemeral by design: a
    # cache entry, forgotten after a while so a stale choice can't catch the
    # operator out the next day.
    FOCUS_TTL = 12.hours
    SEND_USAGE = "Usage: /send <run> <text>, or /send <text> after /pane <run>.".freeze

    def self.call(adapter, message)
      new(adapter, message).call
    end

    def initialize(adapter, message)
      @adapter = adapter
      @message = message
      @chat_id = message.chat_id
    end

    def call
      return unless @adapter.authorized?(@message.user_id)

      text = @message.text
      return if text.empty?

      if text.start_with?("/")
        dispatch(text)
      elsif (ref = replied_run_ref || focused_run_id)
        send_to(ref, text)
      else
        reply("Pick a run first (/panes, then /pane <run>): after that, anything you type goes to it.\n\n#{Commands::HELP}")
      end
    end

    private

    # "/pane_33bd 80" and "/pane 33bd 80" are the same command -- the first
    # form is what the lists print where the adapter makes it tappable.
    def dispatch(text)
      command, rest = text.split(/\s+/, 2)
      command, inline_ref = command.delete_prefix("/").split("_", 2)
      rest = [ inline_ref, rest ].compact.join(" ")

      case command
      when "panes" then list_panes(idle_only: false)
      when "idle" then list_panes(idle_only: true)
      when "pane" then show_pane(rest.split(/\s+/).first)
      when "screen"
        ref, lines = rest.split(/\s+/, 2)
        # "/screen 120" is the focused run's last 120 lines -- unless 120 is a
        # run's ref: a short ref is four hex digits, and often all numbers.
        ref, lines = nil, ref if lines.nil? && ref.to_s.match?(/\A\d+\z/) && !exact_live_ref?(ref)
        show_screen(ref, lines)
      when "report" then show_report(rest.split(/\s+/).first)
      when "send" then send_command(rest)
      else reply(Commands::HELP)
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
        "  #{@adapter.command_link('pane', ref)} #{@adapter.command_link('screen', ref)}"
      ].compact.join("\n")
    end

    # What the operator wants to know about a session: if it has reported and
    # not gone back to work since, its recap says where things stand. If not,
    # the pane is all there is, so show it -- live, where the adapter can edit
    # a message (StreamPaneJob), until the session reports and the recap
    # follows on its own.
    def show_pane(ref)
      run = resolve(ref) or return
      session = run.live_session
      if (checkpoint = Views.current_recap(session))
        footer = "#{@adapter.command_link('screen', short_ref(run))} for the raw pane"
        return Views.send_recap(@adapter, @chat_id, run, checkpoint, footer:)
      end

      stream_pane(run, session)
    end

    def stream_pane(run, session)
      text = Orchestrator::RunSessionRunner.snapshot(session, lines: Views::LIVE_PANE_LINES)
      return reply("#{header(run)}\nherdr could not read this session's pane.") if text.nil?

      last_checkpoint = session.checkpoints.last
      state = last_checkpoint ? "Working again since its last report" : "No report yet"
      unless @adapter.supports_edit?
        return @adapter.send_pane(@chat_id, *Views.pane(@adapter, run, text, note: state))
      end

      minutes = StreamPaneJob::DURATION.in_minutes.to_i
      message_id = @adapter.send_pane(@chat_id, *Views.pane(@adapter, run, text, note: "#{state} · live for #{minutes} min"))
      return unless message_id

      StreamPaneJob.set(wait: StreamPaneJob::INTERVAL).perform_later(
        adapter: @adapter.name, chat_id: @chat_id, message_id:, session_id: session.id,
        since_checkpoint_id: last_checkpoint&.id.to_i, until_time: StreamPaneJob::DURATION.from_now.iso8601,
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
      Views.pane_pages(@adapter, run, text, note:, max_pages: MAX_SCREEN_MESSAGES).each do |title, body|
        @adapter.send_pane(@chat_id, title, body)
      end
    end

    def show_report(ref)
      run = resolve(ref, live_only: false) or return
      checkpoint = run.checkpoints.last
      return reply("#{header(run)}\nNo report yet.") unless checkpoint

      Views.send_recap(@adapter, @chat_id, run, checkpoint)
    end

    # "/send 33bd text" names its run. Otherwise, once the chat has a run in
    # focus, the whole text goes there -- only an exact short ref or run id
    # counts as naming another run, since a worktree-name prefix could be the
    # first word of an instruction.
    def send_command(rest)
      return reply(SEND_USAGE) if rest.blank?

      ref, body = rest.split(/\s+/, 2)
      focus = focused_run_id
      if focus && !exact_live_ref?(ref)
        return send_to(focus, rest)
      end
      return reply(SEND_USAGE) if body.blank?

      send_to(ref, body)
    end

    def send_to(ref, text)
      run = resolve(ref) or return
      Orchestrator::RunSessionRunner.prompt!(run.live_session, text)
      Rails.logger.info("[remote_control] #{@adapter.name}: sent #{text.length} characters to #{run.run_id}")
      reply("#{header(run)}\nSent.")
    rescue Orchestrator::RunSessionRunner::Error, Orchestrator::Runner::Error => error
      reply("#{header(run)}\nNot sent: #{error.message}")
    end

    # Runs whose session is live, newest first. With live_only: false, recent
    # finished runs resolve too, so /report still works after Close session.
    # With no ref, the chat's focused run.
    def resolve(ref, live_only: true)
      ref = ref.presence || focused_run_id
      return refuse("Which run? Try /panes.") if ref.blank?

      candidates = live_only ? live_runs : Run.includes(:workspace).order(created_at: :desc).limit(50).to_a
      matches = candidates.select { |run| matches?(run, ref) }
      exact = matches.select { |run| run.run_id == ref || short_ref(run) == ref }
      matches = exact if exact.any?

      case matches.size
      when 1 then matches.first.tap { |run| focus!(run) }
      when 0 then refuse("No #{'live ' if live_only}run matches #{ref.inspect}. Try /panes.")
      else refuse("#{ref.inspect} matches more than one run:\n#{matches.map { |run| "#{short_ref(run)} · #{run.worktree_name}" }.join("\n")}")
      end
    end

    def focus_key = "remote_control/focus/#{@adapter.name}/#{@chat_id}"
    def focus!(run) = Rails.cache.write(focus_key, run.run_id, expires_in: FOCUS_TTL)
    def focused_run_id = Rails.cache.read(focus_key)

    def exact_live_ref?(ref)
      live_runs.any? { |run| run.run_id == ref || short_ref(run) == ref }
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

    def replied_run_ref
      @message.reply_to_text.to_s.lines.first.to_s[RUN_HEADER, 1]
    end

    def header(run) = Views.header(run)
    def short_ref(run) = Views.short_ref(run)
    def ago(time) = Views.ago(time)

    def reply(text)
      @adapter.send_text(@chat_id, text)
    end

    # Replies, and returns nil so a failed lookup can `or return`.
    def refuse(text)
      reply(text)
      nil
    end

    def reply_long(text)
      Chunker.split(text, limit: @adapter.max_message_length - 96).each { |chunk| reply(chunk) }
    end
  end
end
