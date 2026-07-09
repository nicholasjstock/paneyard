class QuestionsController < ApplicationController
  def index
    @questions = UserQuestion.order(asked_at: :desc).map { |question| JSON.parse(question.to_json) }
  end

  def answer
    question = UserQuestion.find_by!(question_id: params[:id])
    question.update!(status: "answered", answered_by: current_operator, answered_at: Time.current, answer_text: params.require(:answer_text))
    redirect_to questions_path, notice: "Answer recorded."
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid => e
    redirect_to questions_path, alert: "Failed to record answer: #{e.message}"
  end
end
