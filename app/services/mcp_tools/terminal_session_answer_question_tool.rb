module McpTools
  class TerminalSessionAnswerQuestionTool < MCP::Tool
    tool_name "answer_workspace_question"
    description "Answer one open operator question belonging to this workspace."
    input_schema(
      properties: { questionId: { type: "string" }, answer: { type: "string" } },
      required: %w[questionId answer]
    )

    def self.call(questionId:, answer:, server_context:)
      session = server_context && TerminalSession.find_by(id: server_context[:terminal_session_id])
      workspace = session&.workspace or raise "Terminal session capability missing"
      question = UserQuestion.joins(:run).where(runs: { workspace_id: workspace.id }).find_by!(question_id: questionId, status: "open")
      question.update!(status: "answered", answer_text: answer, answered_by: "terminal_session", answered_at: Time.current)
      TickRunJob.perform_later
      ToolResponse.structured(questionId:, status: "answered")
    end
  end
end
