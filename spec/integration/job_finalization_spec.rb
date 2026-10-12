require "rails_helper"
require "open3"

RSpec.describe "explicit job finalization", type: :request do
  include_context "launched runs"

  # No network access in tests. Push examples opt in with a disposable bare origin.
  before { allow(Orchestrator::Runner::Worktrees).to receive(:remote_refs).and_return("") }

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise out unless status.success?

    out.strip
  end

  def commit(run)
    File.write(File.join(run.target_root, "fix.txt"), "fix\n")
    git(run.target_root, "add", "fix.txt")
    git(run.target_root, "-c", "user.name=Agent", "-c", "user.email=agent@example.test", "commit", "-qm", "Fix")
  end

  def merged_run
    run = queue_and_launch("Merge explicitly requested")
    commit(run)
    git(workspace.repository_path, "merge", "--ff-only", run.branch_name)
    run
  end

  def finish(run, meta: nil)
    mcp_call("/mcp/run", "job_finished", token: session_token(run), meta:, summary: "Authorized merge verified")
  end

  it "acknowledges first, repeats safely, closes and removes only its worktree while preserving history", :fake_herdr do
    run = merged_run
    session = run.live_session
    token = session_token(run)
    report(run, "done", "Ready for merge")
    operator_file = File.join(workspace.repository_path, "operator-notes.txt")
    File.write(operator_file, "keep me")

    expect(finish(run, meta: { progressToken: "finalization" })).to include("finalization" => "accepted")
    expect(session.reload).to be_live
    expect(session.finalization_ready_at).to be_present
    expect(File.directory?(run.target_root)).to be(true)
    expect(Orchestrator::RunConcurrency.in_flight).to eq(1)
    expect(enqueued_jobs.select { |job| job[:job] == JobFinalizationJob }.last[:at]).to be > Time.current.to_f
    finish(run)
    expect(run.checkpoints.count).to eq(2)

    expect { JobFinalizationJob.perform_now(session.id) }.to have_enqueued_job(RunDispatchJob)
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload).to be_ended
    expect(session.finalization_completed_at).to be_present
    expect(run.reload.status).to eq("completed")
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
    expect(File.directory?(run.target_root)).to be(false)
    expect(fake_herdr.workspace_ids).to be_empty
    expect(fake_herdr.requests_for("worktree.remove").size).to eq(1)
    expect(File.read(operator_file)).to eq("keep me")
    expect(git(workspace.repository_path, "branch", "--show-current")).to eq("main")
    expect(git(workspace.repository_path, "branch", "--list", run.branch_name)).to include(run.branch_name)
    expect(run.checkpoints.map(&:summary)).to eq([ "Ready for merge", "Authorized merge verified" ])
    post "/mcp/run", headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(response.status).to eq(401)
  end

  it "does not arm shutdown before Rack closes the acknowledgment body", :fake_herdr do
    run = merged_run
    session = run.live_session
    env = Rack::MockRequest.env_for("/", method: "POST", "HTTP_HOST" => "127.0.0.1",
      "HTTP_AUTHORIZATION" => "Bearer #{session_token(run)}", "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      input: JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/call",
        params: { name: "job_finished", arguments: { summary: "Merged" }, _meta: { progressToken: 42 } }))
    status, _headers, body = Orchestrator::RunMcpEndpoint.new.call(env)
    chunks = []
    body.each { |chunk| chunks << chunk }
    expect(status).to eq(200)
    expect(chunks.join).to include("accepted")
    expect(session.reload.finalization_ready_at).to be_nil
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload).to be_live
    # Another concurrent response must not arm this still-open response.
    mcp_call("/mcp/run", "get_run", token: session_token(run), runId: run.run_id)
    expect(session.reload.finalization_ready_at).to be_nil
    body.close
    expect(session.reload.finalization_ready_at).to be_present
  end

  it "waits for a still-launching agent to be recorded before closing its pane", :fake_herdr do
    run = merged_run
    session = run.live_session
    pid = session.pid
    session.update!(started_at: nil, pid: nil)
    finish(run, meta: { progressToken: "quick-agent" })
    expect(session.reload.status).to eq("done")

    expect { JobFinalizationJob.perform_now(session.id) }
      .to have_enqueued_job(JobFinalizationJob).with(session.id).at(a_value_within(1).of(5.seconds.from_now))
    expect(session.reload).to be_live
    expect(session.finalization_completed_at).to be_nil
    expect(fake_herdr.workspace_ids).to include(session.herdr_workspace_id)
    expect(fake_herdr.requests_for("worktree.remove")).to be_empty

    session.update!(started_at: Time.current, pid:)
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload.finalization_completed_at).to be_present
    expect(run.reload.status).to eq("completed")
    expect(File.directory?(run.target_root)).to be(false)
  end

  it "refuses unmerged branches, dirty worktrees, and another caller's run or path", :fake_herdr do
    run = queue_and_launch("Not merged")
    session = run.live_session
    commit(run)
    context = { run_session_id: session.id }
    result = McpTools::JobFinishedTool.call(summary: "Merged", server_context: context)
    expect(result).to be_error
    expect(result.content.first[:text]).to include("must be merged")
    git(workspace.repository_path, "merge", "--ff-only", run.branch_name)
    File.write(File.join(run.target_root, "unsaved.txt"), "keep")
    expect(McpTools::JobFinishedTool.call(summary: "Merged", server_context: context)).to be_error
    expect(session.reload.finalization_requested_at).to be_nil
    expect(session).to be_live
    expect(run.checkpoints.count).to eq(0)
    expect { McpTools::JobFinishedTool.call(summary: "Merged", server_context: context, runId: "other") }.to raise_error(ArgumentError)
    expect(McpTools::JobFinishedTool.call(summary: "Merged", server_context: {})).to be_error
    expect(fake_herdr.requests_for("worktree.remove")).to be_empty
  end

  it "checks the actual branch tip even when the worktree HEAD is already saved", :fake_herdr do
    run = merged_run
    git(run.target_root, "checkout", "--detach")
    git(workspace.repository_path, "update-ref", "refs/heads/#{run.branch_name}", git(workspace.repository_path, "rev-parse", "main"))
    # Make the branch advance independently of the detached worktree.
    tree = git(run.target_root, "rev-parse", "HEAD^{tree}")
    out, status = Open3.capture2e("git", "-C", run.target_root, "-c", "user.name=Agent", "-c", "user.email=agent@example.test",
      "commit-tree", tree, "-p", "HEAD", "-m", "Unmerged tip")
    raise out unless status.success?
    git(workspace.repository_path, "update-ref", "refs/heads/#{run.branch_name}", out.strip)
    expect(McpTools::JobFinishedTool.call(summary: "Merged", server_context: { run_session_id: run.live_session.id })).to be_error
  end

  it "durably retries a failed removal after revoking the capability and releasing the slot", :fake_herdr do
    run = merged_run
    session = run.live_session
    finish(run)
    allow(Orchestrator::Runner::Herdr).to receive(:worktree_remove).and_raise(Orchestrator::Runner::Herdr::Unreachable, "temporarily unavailable")
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload).to be_ended
    expect(session.finalization_error).to include("temporarily unavailable")
    expect(session.finalization_completed_at).to be_nil
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
    expect(File.directory?(run.target_root)).to be(true)
    allow(Orchestrator::Runner::Herdr).to receive(:worktree_remove).and_call_original
    session.update!(finalization_ready_at: 1.minute.ago)
    expect { Orchestrator::JobFinalization.recover }.to have_enqueued_job(JobFinalizationJob).with(session.id)
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload.finalization_completed_at).to be_present
    expect(session.finalization_error).to be_nil
    expect(File.directory?(run.target_root)).to be(false)
  end

  it "revalidates later edits and keeps the session and worktree until corrected", :fake_herdr do
    run = merged_run
    session = run.live_session
    finish(run)
    file = File.join(run.target_root, "late.txt")
    File.write(file, "late edit")
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload).to be_live
    expect(session.finalization_error).to include("uncommitted")
    expect(File.read(file)).to eq("late edit")
    File.delete(file)
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload.finalization_completed_at).to be_present
  end

  it "only finalizes the run authenticated by its capability", :fake_herdr do
    first = merged_run
    second = queue_and_launch("Sibling awaiting review")
    other = second.live_session
    finish(first)
    JobFinalizationJob.perform_now(first.latest_session.id)
    expect(other.reload).to be_live
    expect(second.reload.status).to eq("running")
    expect(File.directory?(second.target_root)).to be(true)
    expect(fake_herdr.workspace_ids).to include(other.herdr_workspace_id)
  end

  it "records workspace-close failures and retries them without reclaiming dirty work", :fake_herdr do
    run = merged_run
    session = run.live_session
    finish(run)
    allow(Orchestrator::WorktreeJanitor).to receive(:release!).and_return(false)
    allow(Orchestrator::Runner::Herdr).to receive(:workspace_close!).and_raise(Orchestrator::Runner::Herdr::Unreachable, "close unavailable")
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload).to be_ended
    expect(session.finalization_error).to include("close unavailable")
    expect(session.finalization_completed_at).to be_nil
    File.write(File.join(run.target_root, "keep.txt"), "keep")
    allow(Orchestrator::WorktreeJanitor).to receive(:release!).and_call_original
    allow(Orchestrator::Runner::Herdr).to receive(:workspace_close!).and_call_original
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload.finalization_completed_at).to be_nil
    expect(session.finalization_error).to include("uncommitted")
    expect(File.read(File.join(run.target_root, "keep.txt"))).to eq("keep")
    expect(fake_herdr.workspace_ids).to be_empty
    File.delete(File.join(run.target_root, "keep.txt"))
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload.finalization_completed_at).to be_present
  end

  it "uses the run's base branch even when main contains its commits", :fake_herdr do
    git(workspace.repository_path, "branch", "feature/base")
    run_id = nil
    perform_enqueued_jobs(only: [ RunDispatchJob, StartRunSessionJob ]) do
      run_id = mcp_call("/mcp/admin", "queue_run", workspace: workspace.name, task: "Feature fix", baseBranch: "feature/base").fetch("runId")
    end
    run = Run.find_by!(run_id: run_id)
    commit(run)
    git(workspace.repository_path, "merge", "--ff-only", run.branch_name)
    expect(McpTools::JobFinishedTool.call(summary: "Merged to main", server_context: { run_session_id: run.live_session.id })).to be_error
    git(workspace.repository_path, "fetch", ".", "#{run.branch_name}:feature/base")
    session = run.live_session
    finish(run)
    JobFinalizationJob.perform_now(session.id)
    expect(run.reload.status).to eq("completed")
  end

  it "refuses ignored files that removal would discard", :fake_herdr do
    run = merged_run
    git(run.target_root, "config", "core.excludesFile", File.join(run.target_root, ".ignored-patterns"))
    File.write(File.join(run.target_root, ".ignored-patterns"), ".ignored-patterns\nsecret.tmp\n")
    File.write(File.join(run.target_root, "secret.tmp"), "keep")
    expect(McpTools::JobFinishedTool.call(summary: "Merged", server_context: { run_session_id: run.live_session.id })).to be_error
    expect(File.read(File.join(run.target_root, "secret.tmp"))).to eq("keep")
  end

  it "never lets an old retry reclaim a reopened run even while queued", :fake_herdr do
    run = merged_run
    session = run.live_session
    finish(run)
    allow(Orchestrator::Runner::Herdr).to receive(:worktree_remove).and_raise(Orchestrator::Runner::Herdr::Unreachable, "unavailable")
    JobFinalizationJob.perform_now(session.id)
    Orchestrator::SessionReopen.call(run.reload)
    allow(Orchestrator::Runner::Herdr).to receive(:worktree_remove).and_call_original
    JobFinalizationJob.perform_now(session.id)
    expect(run.reload.status).to eq("queued")
    expect(File.directory?(run.target_root)).to be(true)
    expect(session.reload.finalization_error).to include("Superseded")
  end

  def pushed_run(upstream: true)
    repository = workspace.repository_path
    origin = File.join(File.dirname(repository), "origin.git")
    git(repository, "init", "--bare", origin)
    git(repository, "remote", "set-url", "origin", origin)
    run = queue_and_launch("Push and create PR, then explicitly end")
    commit(run)
    args = [ "push", *(upstream ? [ "-u" ] : []), "origin", run.branch_name ]
    git(run.target_root, *args)
    allow(Orchestrator::Runner::Worktrees).to receive(:remote_refs).and_call_original
    [ run, origin ]
  end

  it "ends a clean pushed branch with an open PR, without merging or altering the operator checkout", :fake_herdr do
    run, origin = pushed_run
    session = run.live_session
    base = git(workspace.repository_path, "rev-parse", "main")
    tip = git(run.target_root, "rev-parse", "HEAD")
    report(run, "done", "Pushed; PR opened; awaiting explicit end request")
    expect(session.reload).to be_live
    expect(File.directory?(run.target_root)).to be(true)
    expect(session.finalization_requested_at).to be_nil
    summary = "Push and PR succeeded; operator requested end. PR: https://example.test/pull/1"
    mcp_call("/mcp/run", "job_finished", token: session_token(run), summary:)
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload.finalization_completed_at).to be_present
    expect(run.reload.status).to eq("completed")
    expect(File.directory?(run.target_root)).to be(false)
    expect(git(workspace.repository_path, "rev-parse", "main")).to eq(base)
    expect(git(origin, "rev-parse", "refs/heads/#{run.branch_name}")).to eq(tip)
    expect(run.checkpoints.last.summary).to eq(summary)
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
  end

  it "verifies a push without an upstream or cached remote ref and still reclaims the worktree", :fake_herdr do
    run, = pushed_run(upstream: false)
    session = run.live_session
    git(workspace.repository_path, "update-ref", "-d", "refs/remotes/origin/#{run.branch_name}")
    mcp_call("/mcp/run", "job_finished", token: session_token(run), summary: "Pushed and explicitly told to end")
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload.finalization_completed_at).to be_present
    expect(File.directory?(run.target_root)).to be(false)
  end

  it "refuses a deleted remote branch despite a stale remote-tracking ref", :fake_herdr do
    run, origin = pushed_run
    session = run.live_session
    git(origin, "update-ref", "-d", "refs/heads/#{run.branch_name}")
    expect(git(run.target_root, "branch", "--remotes", "--contains", "HEAD")).to include(run.branch_name)
    result = McpTools::JobFinishedTool.call(summary: "End requested", server_context: { run_session_id: session.id })
    expect(result).to be_error
    expect(session.reload).to be_live
    expect(session.finalization_requested_at).to be_nil
    expect(File.directory?(run.target_root)).to be(true)
  end

  it "refuses clean local commits beyond the actual pushed tip", :fake_herdr do
    run, = pushed_run
    File.write(File.join(run.target_root, "later.txt"), "not pushed")
    git(run.target_root, "add", "later.txt")
    git(run.target_root, "commit", "-qm", "Unpushed follow-up")
    result = McpTools::JobFinishedTool.call(summary: "End requested", server_context: { run_session_id: run.live_session.id })
    expect(result).to be_error
    expect(result.content.first[:text]).to include("fully pushed")
    expect(run.live_session).to be_live
  end

  it "rechecks remote preservation after acknowledgment and retries without closing on remote failure", :fake_herdr do
    run, origin = pushed_run
    session = run.live_session
    mcp_call("/mcp/run", "job_finished", token: session_token(run), summary: "Pushed; end requested")
    git(origin, "update-ref", "-d", "refs/heads/#{run.branch_name}")
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload).to be_live
    expect(session.finalization_error).to include("verify the pushed branch")
    expect(File.directory?(run.target_root)).to be(true)
    git(run.target_root, "push", "origin", run.branch_name)
    JobFinalizationJob.perform_now(session.id)
    expect(session.reload.finalization_completed_at).to be_present
  end

  it "releases a pushed run's slot but leaves dependencies waiting for an actual base-branch merge", :fake_herdr do
    run, = pushed_run
    dependent_id = mcp_call("/mcp/admin", "queue_run", workspace: workspace.name, task: "Needs merged work", after: [ run.run_id ]).fetch("runId")
    session = run.live_session
    mcp_call("/mcp/run", "job_finished", token: session_token(run), summary: "Pushed; end requested")
    perform_enqueued_jobs(only: [ RunDispatchJob, StartRunSessionJob ]) { JobFinalizationJob.perform_now(session.id) }
    dependent = Run.find_by!(run_id: dependent_id)
    expect(dependent.status).to eq("queued")
    expect(dependent.branch_name).to be_nil
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
  end

  it "frees the slot for a dependent run starting from the verified merge", :fake_herdr do
    run = merged_run
    second_id = mcp_call("/mcp/admin", "queue_run", workspace: workspace.name, task: "Build on fix", after: [ run.run_id ]).fetch("runId")
    session = run.live_session
    finish(run)
    perform_enqueued_jobs(only: [ RunDispatchJob, StartRunSessionJob ]) { JobFinalizationJob.perform_now(session.id) }
    second = Run.find_by!(run_id: second_id)
    expect(second.status).to eq("running")
    expect(File.read(File.join(second.target_root, "fix.txt"))).to eq("fix\n")
    expect(Orchestrator::RunConcurrency.occupied_run_ids).to eq([ second.id ])
  end
end
