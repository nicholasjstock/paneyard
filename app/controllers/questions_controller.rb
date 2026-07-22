class QuestionsController < ApplicationController
  before_action :require_workspace

  def index
    @questions = workspace_questions.order(asked_at: :desc).map { |question| JSON.parse(question.to_json) }
  end

  private

  def workspace_questions
    UserQuestion.joins(:run).where(runs: { workspace_id: current_workspace.id })
  end
end
