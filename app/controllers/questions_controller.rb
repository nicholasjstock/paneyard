class QuestionsController < ApplicationController
  before_action :require_workspace

  def index
    @questions = workspace_questions.order(asked_at: :desc).map { |question| JSON.parse(question.to_json) }
  end

  def answer
    question = workspace_questions.find_by!(question_id: params[:id])
    question.update!(status: "answered", answered_by: current_operator, answered_at: Time.current, answer_text: params.require(:answer_text))
    TickRunJob.perform_later
    redirect_back fallback_location: workspace_questions_path(current_workspace), notice: "Answer recorded."
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: workspace_questions_path(current_workspace), alert: "Failed to record answer: #{e.message}"
  end

  private

  def workspace_questions
    UserQuestion.joins(:run).where(runs: { workspace_id: current_workspace.id })
  end
end
