# Builds the workspace + run + live session trio most specs need, since
# almost everything now hangs off "a run with a session holding its
# capability".
module RunFixtures
  def create_workspace(prefix: "workspace", **attributes)
    Workspace.create!(
      name: "#{prefix}-#{SecureRandom.hex(4)}",
      root_path: Dir.mktmpdir(prefix),
      **attributes
    )
  end

  def create_run(workspace: nil, prefix: "run", **attributes)
    workspace ||= create_workspace(prefix:)
    workspace.runs.create!(
      run_id: "#{prefix}-#{SecureRandom.hex(4)}",
      task: attributes.delete(:task) || "Exercise #{prefix}",
      target_root: attributes.delete(:target_root) || workspace.source_root,
      launcher_variant: "claude",
      status: "running",
      **attributes
    )
  end

  # Returns [run, session]. The session is live and carries a real capability
  # digest, so SessionAuthorization resolves it exactly as the MCP transport
  # would.
  def create_run_and_session(run: nil, prefix: "run", status: "running", **attributes)
    run ||= create_run(prefix:)
    _token, digest = RunSession.issue_capability
    session = run.run_sessions.create!(
      driver: run.launcher_variant, status:, capability_token_digest: digest,
      herdr_workspace_id: "w1", herdr_tab_id: "w1:t1", herdr_pane_id: "w1:p1",
      pid: 99_997, started_at: Time.current, **attributes
    )
    [ run, session ]
  end
end

RSpec.configure do |config|
  config.include RunFixtures
end
