require "digest"

# Keeps one Telegram message showing a working session's pane, for a few
# minutes after the operator asks for it with /pane.
#
# Each tick is short (one herdr pane read, at most one Telegram edit) and
# schedules the next one, so it never holds a worker thread between ticks. It
# stops on its own in three ways:
#
#   - the session reports idle: the message says so, and the recap follows it,
#     which is what the operator was waiting to read;
#   - the session ends: the message says so;
#   - the time runs out: the message says it stopped updating. Tapping /pane
#     again starts a new stream.
#
# Only this message is edited. Nothing about the run or its session changes.
class StreamTelegramPaneJob < ApplicationJob
  queue_as :default

  INTERVAL = 5.seconds
  DURATION = 3.minutes

  def perform(chat_id:, message_id:, session_id:, since_checkpoint_id:, until_time:, last_digest: nil)
    session = RunSession.find_by(id: session_id)
    return unless session

    run = session.run
    client = Telegram::Client.new
    checkpoint = session.checkpoints.where("run_checkpoints.id > ?", since_checkpoint_id.to_i).last

    if checkpoint
      finish(client, chat_id, message_id, session, run, "Reported idle (#{checkpoint.outcome}). Recap below.")
      Telegram::RunViews.send_recap(client, chat_id, run, checkpoint)
    elsif session.ended?
      finish(client, chat_id, message_id, session, run, "Session ended.")
    elsif Time.current >= Time.zone.parse(until_time)
      finish(client, chat_id, message_id, session, run, "Stopped updating. /pane_#{Telegram::RunViews.short_ref(run)} to watch again.")
    else
      text = Orchestrator::RunSessionRunner.snapshot(session, lines: Telegram::RunViews::LIVE_PANE_LINES)
      html = Telegram::RunViews.pane_html(run, text, note: "Live · #{session.agent_status || 'working'} · updated #{Time.current.strftime('%H:%M:%S')}")
      digest = text && Digest::SHA256.hexdigest(text)
      edit(client, chat_id, message_id, html) if digest && digest != last_digest
      self.class.set(wait: INTERVAL).perform_later(
        chat_id:, message_id:, session_id:, since_checkpoint_id:, until_time:, last_digest: digest || last_digest
      )
    end
  end

  private

  # The final state of the message: the last pane content, with why it
  # stopped updating in place of the "Live" note.
  def finish(client, chat_id, message_id, session, run, note)
    text = Orchestrator::RunSessionRunner.snapshot(session, lines: Telegram::RunViews::LIVE_PANE_LINES)
    edit(client, chat_id, message_id, Telegram::RunViews.pane_html(run, text, note:))
  end

  # A failed edit (the message was deleted, or Telegram refused it) must not
  # stop the recap or the next tick.
  def edit(client, chat_id, message_id, html)
    client.edit_message_text(chat_id:, message_id:, text: html, parse_mode: "HTML")
  rescue StandardError => error
    Rails.logger.warn("StreamTelegramPaneJob: could not edit #{chat_id}/#{message_id}: #{error.message}")
  end
end
