class WorkspaceAdminChatTurnJob < ApplicationJob
  # Its own queue/worker pool (config/queue.yml) -- this job blocks a thread
  # for the CLI subprocess's entire turn duration (ProcessStream.run is a
  # blocking read loop with no timeout). On the shared "default" pool, a
  # couple of long turns would starve RunDispatchJob, the reconcilers,
  # and the Telegram pollers of threads at the same time -- queued runs stop
  # starting, dead sessions stop being noticed, and Telegram goes quiet, all
  # simultaneously and for no reason visible from any of those jobs
  # individually.
  queue_as :chat

  def perform(assistant_message_id)
    assistant_message = WorkspaceAdminChatMessage.find(assistant_message_id)
    return unless assistant_message.status == "running"

    Orchestrator::WorkspaceAdminChatDriver::Runner.perform_turn(assistant_message)
  end
end
