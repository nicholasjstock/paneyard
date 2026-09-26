require "rails_helper"

RSpec.describe "runs", type: :request do
  it "blocks queueing a new run while the workspace is not yet initialized" do
    workspace = create_workspace(prefix: "runs-controller")

    get new_workspace_run_path(workspace)
    expect(response).to redirect_to(workspace_runs_path(workspace))
    follow_redirect!
    expect(response.body).to include("still initializing")

    expect do
      post workspace_runs_path(workspace), params: { run: { task: "Do something", launcher_variant: "claude" } }
    end.not_to change(Run, :count)
    expect(response).to redirect_to(workspace_runs_path(workspace))
  end

  # Creating a run starts nothing by itself -- it queues, and the dispatcher
  # decides when it runs. That separation is the whole scheduler.
  it "queues a run rather than starting one, and asks the dispatcher to look" do
    workspace = create_workspace(prefix: "runs-controller", protected_path_patterns: [ "app/**/*.rb" ])

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

  it "stores uploaded files in the run's artifact store so the session can read them" do
    workspace = create_workspace(prefix: "runs-controller-upload", protected_path_patterns: [ "app/**/*.rb" ])
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
end
