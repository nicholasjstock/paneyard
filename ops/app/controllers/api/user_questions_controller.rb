module Api
  class UserQuestionsController < Api::BaseController
    def index
      scope = UserQuestion.all
      scope = scope.where(run_id: params[:runId]) if params[:runId].present?
      scope = scope.open_only if params[:status] == "open"
      render json: scope.map(&:as_json)
    end

    def create
      run = Run.find_or_create_for_bus!(question_params[:runId])
      question = UserQuestion.create!(
        run_id: run.run_id,
        asked_by: question_params[:askedBy],
        scope: question_params[:scope],
        text: question_params[:text],
        context: question_params[:context],
        priority: question_params[:priority].presence || "advisory",
        tags: question_params[:tags] || []
      )
      render json: question
    end

    def answer
      question = UserQuestion.find_by!(question_id: params[:id])
      question.update!(
        status: "answered",
        answered_by: params[:answeredBy],
        answered_at: Time.current,
        answer_text: params[:answerText]
      )
      render json: question
    end

    private

    def question_params
      params.permit(:runId, :askedBy, :scope, :text, :context, :priority, tags: [])
    end
  end
end
