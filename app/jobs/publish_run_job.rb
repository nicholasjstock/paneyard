# Pushes a finished run's branch and opens its pull request.
#
# Out of band from the run_done MCP call that triggers it: publication makes
# several network round trips to GitHub, and the session's tool call should
# return immediately rather than holding an MCP request open through all of
# them. RunPublication owns the run's final status either way.
class PublishRunJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)
    Orchestrator::RunPublication.publish!(run)
  end
end
