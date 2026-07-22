class PublishUserQuestionJob < ApplicationJob
  queue_as :default
  retry_on Orchestrator::RunPublication::Error, wait: :polynomially_longer, attempts: 5

  def perform(id)
    question = UserQuestion.includes(:run).find(id)
    Orchestrator::RunPublication.publish_question!(question)
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
