# Pushes a finished run's branch and opens its pull request.
#
# Triggered by the operator from the run screen, never by the session: a
# finished session reports idle and waits, and whether its work becomes a pull
# request is the operator's call. Out of band because publication makes several
# network round trips to GitHub. RunPublication owns the run's final status.
class PublishRunJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)
    Orchestrator::RunPublication.publish!(run)
  end
end
