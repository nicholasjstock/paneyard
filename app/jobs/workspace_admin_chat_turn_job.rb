class WorkspaceAdminChatTurnJob < ApplicationJob
  queue_as :default

  def perform(assistant_message_id)
    assistant_message = WorkspaceAdminChatMessage.find(assistant_message_id)
    return unless assistant_message.status == "running"

    Orchestrator::WorkspaceAdminChatDriver::Runner.perform_turn(assistant_message)
  end
end
