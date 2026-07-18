require "rails_helper"

RSpec.describe "chaperone MCP capability", type: :request do
  it "rejects requests without a chaperone capability" do
    post "/mcp/chaperone", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(:unauthorized)
    expect(response.body).to include("invalid chaperone capability")
  end

  it "issues a live capability for a server containing only curated tools" do
    root = Dir.mktmpdir("chaperone-mcp")
    workspace = Workspace.create!(name: "chaperone-mcp-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(run_id: SecureRandom.uuid, task: "Inspect a repeated failure", target_root: root, launcher_variant: "claude")
    review, token = ChaperoneReview.issue!(run:, lineage_key: "login", step_attempt_ids: [])

    expect(ChaperoneReview.authenticate(token)).to eq(review)
    expect(ChaperoneReview.authenticate("wrong-token")).to be_nil
    server = Orchestrator::ChaperoneMcpServer.build(server_context: { review_id: review.id })
    names = server.tools.keys
    expect(names).to contain_exactly("get_chaperone_state", "read_chaperone_artifact", "submit_chaperone_decision")
    context = MCP::ServerContext.new(
      { review_id: review.id }, progress: double(report: nil), notification_target: nil
    )
    expect { McpTools::ChaperoneStateTool.call(server_context: context) }
      .to change { review.reload.tool_calls.length }.from(0).to(1)
  end
end
