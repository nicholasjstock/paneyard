require "rails_helper"

RSpec.describe McpTools::SendSessionMessageTool do
  let(:runner) { instance_double(Orchestrator::Runner::Local, send_prompt: nil, process_alive?: true) }
  let(:workspace) { create_workspace(prefix: "message") }
  let(:target) { create_run_and_session(run: create_run(workspace:, prefix: "message-target")) }
  let(:target_run) { target.first }
  let(:target_session) { target.last }

  before do
    allow(Orchestrator::Runner).to receive(:for).and_return(runner)
    allow(runner).to receive(:agent_state).and_return("agent_status" => "idle", "cli_session_id" => "cli-1")
  end

  def admin_call(**arguments)
    described_class.call(server_context: {}, **{ runId: target_run.run_id, message: "Look at foo.rb", workspace: workspace.name }.merge(arguments))
  end

  def error_text(response)
    expect(response.error?).to be(true)
    response.content.first[:text]
  end

  describe "from /mcp/admin" do
    it "types the message, after a line naming the operator, into the run's agent pane" do
      allow(runner).to receive(:agent_state).and_return("agent_status" => "working")

      response = admin_call(message: "  Look at foo.rb\nline 3  ")

      expect(response.error?).to be_falsey
      expect(response.structured_content).to include(submitted: true, runId: target_run.run_id, agentStatus: "working",
        note: include("not confirmation"))
      expect(runner).to have_received(:send_prompt)
        .with("w1:p1", "[Paneyard: message relayed from the operator's session]\n\nLook at foo.rb\nline 3")
      expect(target_session.reload.agent_status).to eq("working")
    end

    it "sends to an idle agent that has reported done" do
      target_session.update!(status: "done", outcome: "done")
      allow(runner).to receive(:agent_state).and_return("agent_status" => "done")

      expect(admin_call.structured_content).to include(submitted: true, agentStatus: "done")
      expect(runner).to have_received(:send_prompt)
    end

    it "requires the workspace" do
      response = described_class.call(runId: target_run.run_id, message: "hi", server_context: {})

      expect(error_text(response)).to include("workspace is required")
      expect(runner).not_to have_received(:send_prompt)
    end

    it "refuses a run that does not exist" do
      expect(error_text(admin_call(runId: "run-nope"))).to include("no run run-nope")
    end

    it "refuses an empty or oversized message" do
      expect(error_text(admin_call(message: "  \n "))).to include("message is empty")
      expect(error_text(admin_call(message: "x" * (Orchestrator::SessionMessage::MAX_LENGTH + 1)))).to include("the limit is")
      expect(runner).not_to have_received(:send_prompt)
    end

    it "refuses a run with no live session, pointing at Reopen session" do
      target_session.update!(status: "done", outcome: "done", ended_at: Time.current)
      target_run.update!(status: "completed")

      expect(error_text(admin_call)).to include("no live session", "completed", "Reopen session")
      expect(runner).not_to have_received(:send_prompt)
    end

    it "refuses a session still starting, without asking herdr" do
      target_session.update!(status: "starting")

      expect(error_text(admin_call)).to include("still starting")
      expect(runner).not_to have_received(:agent_state)
    end

    it "refuses, ending the session, when its pane is gone" do
      allow(runner).to receive(:agent_state).and_return(nil)
      allow(runner).to receive(:close_workspace)
      allow(runner).to receive(:terminate)
      allow(runner).to receive(:save_transcripts).and_return([])

      expect(error_text(admin_call)).to include("session has ended", "no longer exists", "Reopen session")
      expect(target_session.reload).to be_ended
      expect(runner).not_to have_received(:send_prompt)
    end

    it "refuses an agent waiting at a permission prompt, which the message would answer" do
      allow(runner).to receive(:agent_state).and_return("agent_status" => "blocked")

      expect(error_text(admin_call)).to include("permission or approval prompt", "nothing was sent")
      expect(runner).not_to have_received(:send_prompt)
    end

    it "refuses when herdr does not answer, leaving the session live" do
      allow(runner).to receive(:agent_state).and_raise(Orchestrator::Runner::Unreachable, "connection refused")

      expect(error_text(admin_call)).to include("herdr did not answer", "nothing was sent", "not presumed dead")
      expect(target_session.reload).to be_live
      expect(runner).not_to have_received(:send_prompt)
    end

    it "says the message may have arrived when herdr stops answering mid-send" do
      allow(runner).to receive(:send_prompt).and_raise(Orchestrator::Runner::Unreachable, "timed out")

      expect(error_text(admin_call)).to include("may still have arrived", "before sending it again")
    end

    it "passes on herdr refusing the input" do
      allow(runner).to receive(:send_prompt).and_raise(Orchestrator::Runner::Error, "agent_not_running")

      expect(error_text(admin_call)).to include("would not deliver", "agent_not_running")
    end
  end

  describe "from /mcp/run" do
    let(:sender) { create_run_and_session(run: create_run(workspace:, prefix: "message-sender"), herdr_pane_id: "w2:p1") }
    let(:context) { { run_session_id: sender.last.id } }

    it "defaults to the calling run's workspace and names the sending run" do
      response = described_class.call(runId: target_run.run_id, message: "Found it", server_context: context)

      expect(response.structured_content).to include(submitted: true, runId: target_run.run_id)
      expect(runner).to have_received(:send_prompt)
        .with("w1:p1", "[Paneyard: message relayed from run #{sender.first.run_id}]\n\nFound it")
    end

    it "refuses its own run" do
      response = described_class.call(runId: sender.first.run_id, message: "Hi me", server_context: context)

      expect(error_text(response)).to include("your own run")
      expect(runner).not_to have_received(:send_prompt)
    end

    it "refuses a run in another workspace, named or not" do
      other = create_run_and_session(prefix: "message-elsewhere").first

      named = described_class.call(runId: other.run_id, workspace: other.workspace.name, message: "x", server_context: context)
      unnamed = described_class.call(runId: other.run_id, message: "x", server_context: context)

      expect(error_text(named)).to include("only message runs in its own workspace")
      expect(error_text(unnamed)).to include("no run #{other.run_id} in workspace", workspace.name)
      expect(runner).not_to have_received(:send_prompt)
    end

    it "accepts its own workspace named explicitly" do
      response = described_class.call(runId: target_run.run_id, workspace: workspace.name, message: "x", server_context: context)

      expect(response.error?).to be_falsey
    end
  end
end
