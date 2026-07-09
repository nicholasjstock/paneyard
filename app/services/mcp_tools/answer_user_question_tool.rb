module McpTools
  class AnswerUserQuestionTool < MCP::Tool
    tool_name "answer_user_question"
    description "Record a human's answer to a previously asked question."
    input_schema(
      properties: {
        questionId: { type: "string" },
        answeredBy: { type: "string" },
        answerText: { type: "string" }
      },
      required: %w[questionId answeredBy answerText]
    )

    def self.call(questionId:, answeredBy:, answerText:, server_context:)
      question = UserQuestion.find_by!(question_id: questionId)
      question.update!(status: "answered", answered_by: answeredBy, answered_at: Time.current, answer_text: answerText)
      ToolResponse.structured(question.as_json)
    end
  end
end
