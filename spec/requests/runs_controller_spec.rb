require "rails_helper"

RSpec.describe "runs", type: :request do
  # Creating a run starts nothing by itself -- it queues, and the dispatcher
  # decides when it runs. That separation is the whole scheduler.
  it "queues a run rather than starting one, and asks the dispatcher to look" do
    workspace = create_workspace(prefix: "runs-controller")

    get new_workspace_run_path(workspace)
    expect(response).to have_http_status(:ok)

    expect do
      post workspace_runs_path(workspace), params: { run: { task: "Do something", launcher_variant: "claude" } }
    end.to change(Run, :count).by(1)
      .and have_enqueued_job(RunDispatchJob)

    run = workspace.runs.order(:created_at).last
    expect(run.status).to eq("queued")
    expect(run.worktree_name).to start_with("do-something-")
    expect(run.target_root).to eq(workspace.source_root)
    expect(run.run_sessions).to be_empty
  end

  describe "model choice" do
    let(:workspace) { create_workspace(prefix: "runs-controller-model") }

    before do
      allow(Orchestrator::ModelCatalog).to receive(:all).and_return(
        "claude" => [ { "id" => "claude-sonnet-5", "label" => "Sonnet 5 — claude-sonnet-5" } ],
        "codex" => [ { "id" => "gpt-5.5", "label" => "gpt-5.5" } ],
        "opencode" => []
      )
    end

    it "offers the selected agent's models, with every agent's list available to switch to" do
      get new_workspace_run_path(workspace)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Default (#{Orchestrator::SessionArgs.claude_model})")
      expect(response.body).to include(%(<option value="claude-sonnet-5">Sonnet 5 — claude-sonnet-5</option>))
      expect(response.body).not_to include(%(<option value="gpt-5.5">))
      expect(response.body).to include("gpt-5.5") # in the Stimulus catalog value
    end

    it "stores a model the chosen agent offers" do
      post workspace_runs_path(workspace),
        params: { run: { task: "Do something", launcher_variant: "codex", model: "gpt-5.5" } }

      expect(workspace.runs.sole.model).to eq("gpt-5.5")
    end

    it "treats a blank model as the agent's default" do
      post workspace_runs_path(workspace),
        params: { run: { task: "Do something", launcher_variant: "claude", model: "" } }

      expect(workspace.runs.sole.model).to be_nil
    end

    it "refuses a model the chosen agent does not offer" do
      expect do
        post workspace_runs_path(workspace),
          params: { run: { task: "Do something", launcher_variant: "claude", model: "gpt-5.5" } }
      end.not_to change(Run, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("is not a model claude offers")
    end
  end

  it "stores uploaded files in the run's artifact store so the session can read them" do
    workspace = create_workspace(prefix: "runs-controller-upload")
    first = Tempfile.new([ "first", ".db" ])
    second = Tempfile.new([ "second", ".log" ])
    first.write("first artifact")
    first.rewind
    second.write("second artifact")
    second.rewind

    expect do
      post workspace_runs_path(workspace), params: {
        run: {
          task: "Inspect uploaded artifacts", launcher_variant: "claude",
          launch_files: [
            Rack::Test::UploadedFile.new(first.path, "application/octet-stream", original_filename: "first.db"),
            Rack::Test::UploadedFile.new(second.path, "text/plain", original_filename: "second.log")
          ]
        }
      }
    end.to change(Run, :count).by(1)

    expect(response).to have_http_status(:redirect)
    run = workspace.runs.order(:created_at).last
    expect(run.launch_artifacts).to contain_exactly(
      { "name" => "first.db", "source_path" => "first.db" },
      { "name" => "second.log", "source_path" => "second.log" }
    )
    expect(File.read(Orchestrator::ArtifactStore.resolve_path(run.target_root, run.run_id, "first.db"))).to eq("first artifact")
    expect(File.read(Orchestrator::ArtifactStore.resolve_path(run.target_root, run.run_id, "second.log"))).to eq("second artifact")
  ensure
    first&.close!
    second&.close!
  end

  it "sends an operator message into the run's live session" do
    run, session = create_run_and_session(prefix: "runs-controller-message")
    allow(Orchestrator::RunSessionRunner).to receive(:prompt!)

    post send_message_workspace_run_path(run.workspace, run), params: { message: "Use the other migration." }

    expect(Orchestrator::RunSessionRunner).to have_received(:prompt!).with(session, "Use the other migration.")
    expect(response).to redirect_to(workspace_run_path(run.workspace, run))
  end

  it "explains itself rather than erroring when a run has no live session to message" do
    run = create_run(prefix: "runs-controller-message")

    post send_message_workspace_run_path(run.workspace, run), params: { message: "Anyone there?" }

    follow_redirect!
    expect(response.body).to include("no live session")
  end

  # Nothing tears a pane down but the operator, so this is the only path that
  # kills the CLI and hands the concurrency slot back.
  describe "close_session" do
    it "ends the live session and frees the slot" do
      run, session = create_run_and_session(prefix: "close-session")
      session.update!(status: "done", outcome: "done", result: "Finished.")
      allow(Orchestrator::RunSessionRunner).to receive(:finish!) do |s, **|
        s.update!(status: "done", outcome: "done", ended_at: Time.current)
      end

      expect { post close_session_workspace_run_path(run.workspace, run) }
        .to have_enqueued_job(RunDispatchJob)

      expect(Orchestrator::RunSessionRunner).to have_received(:finish!)
      expect(session.reload).to be_ended
      expect(run.reload).to have_attributes(status: "completed")
    end

    it "removes the worktree when its work is already safe, and keeps it when it is not" do
      run, _session = create_run_and_session(prefix: "close-session-release")
      allow(Orchestrator::RunSessionRunner).to receive(:finish!)

      allow(Orchestrator::WorktreeJanitor).to receive(:release!).with(run).and_return(true)
      post close_session_workspace_run_path(run.workspace, run)
      follow_redirect!
      expect(response.body).to include("Closed the session and removed")

      run2, _session2 = create_run_and_session(prefix: "close-session-keep")
      allow(Orchestrator::WorktreeJanitor).to receive(:release!).with(run2).and_return(false)
      post close_session_workspace_run_path(run2.workspace, run2)
      follow_redirect!
      expect(response.body).to include("uncommitted or unpushed work")
    end

    it "says so when there is no live session to close" do
      run = create_run(prefix: "close-session-none", status: "awaiting_review")

      post close_session_workspace_run_path(run.workspace, run)

      expect(response).to redirect_to(workspace_run_path(run.workspace, run))
      follow_redirect!
      expect(response.body).to include("no live session")
    end
  end
end
