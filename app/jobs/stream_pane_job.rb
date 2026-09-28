require "digest"

# Keeps one remote-control message showing a working session's pane, for a
# few minutes after the operator asks for it with /pane -- on any adapter that
# can edit a sent message (RemoteControl::Adapter#supports_edit?).
#
# Each tick is short (one herdr pane read, at most one edit) and schedules the
# next one, so it never holds a worker thread between ticks. It stops on its
# own in three ways:
#
#   - the session reports idle: the message says so, and the recap follows it,
#     which is what the operator was waiting to read;
#   - the session ends: the message says so;
#   - the time runs out: the message says it stopped updating. Asking for
#     /pane again starts a new stream.
#
# Only this message is edited. Nothing about the run or its session changes.
class StreamPaneJob < ApplicationJob
  queue_as :default

  INTERVAL = 5.seconds
  DURATION = 3.minutes

  def perform(adapter:, chat_id:, message_id:, session_id:, since_checkpoint_id:, until_time:, last_digest: nil)
    session = RunSession.find_by(id: session_id)
    return unless session

    @adapter = RemoteControl::Adapters.fetch(adapter)
    return unless @adapter.enabled?

    run = session.run
    checkpoint = session.checkpoints.where("run_checkpoints.id > ?", since_checkpoint_id.to_i).last

    if checkpoint
      finish(chat_id, message_id, session, run, "Reported idle (#{checkpoint.outcome}). Recap below.")
      RemoteControl::Views.send_recap(@adapter, chat_id, run, checkpoint)
    elsif session.ended?
      finish(chat_id, message_id, session, run, "Session ended.")
    elsif Time.current >= Time.zone.parse(until_time)
      again = @adapter.command_link("pane", RemoteControl::Views.short_ref(run))
      finish(chat_id, message_id, session, run, "Stopped updating. #{again} to watch again.")
    else
      text = Orchestrator::RunSessionRunner.snapshot(session, lines: RemoteControl::Views::LIVE_PANE_LINES)
      note = "Live · #{session.agent_status || 'working'} · updated #{Time.current.strftime('%H:%M:%S')}"
      digest = text && Digest::SHA256.hexdigest(text)
      edit(chat_id, message_id, run, text, note) if digest && digest != last_digest
      self.class.set(wait: INTERVAL).perform_later(
        adapter:, chat_id:, message_id:, session_id:, since_checkpoint_id:, until_time:, last_digest: digest || last_digest
      )
    end
  end

  private

  # The final state of the message: the last pane content, with why it
  # stopped updating in place of the "Live" note.
  def finish(chat_id, message_id, session, run, note)
    text = Orchestrator::RunSessionRunner.snapshot(session, lines: RemoteControl::Views::LIVE_PANE_LINES)
    edit(chat_id, message_id, run, text, note)
  end

  # A failed edit (the message was deleted, or the platform refused it) must
  # not stop the recap or the next tick.
  def edit(chat_id, message_id, run, text, note)
    @adapter.edit_pane(chat_id, message_id, *RemoteControl::Views.pane(@adapter, run, text, note:))
  rescue StandardError => error
    Rails.logger.warn("StreamPaneJob: #{@adapter.name} could not edit #{chat_id}/#{message_id}: #{error.message}")
  end
end
