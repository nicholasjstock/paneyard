require "rails_helper"

RSpec.describe "workspace events", type: :system do
  it "lists only recent events for the selected workspace" do
    workspace, run = create_workspace_with_run("alpha")
    BusEvent.publish("run.status", run_id: run.run_id, payload: { runId: run.run_id, summary: "alpha event" })

    other_workspace, other_run = create_workspace_with_run("beta")
    BusEvent.publish("run.status", run_id: other_run.run_id, payload: { runId: other_run.run_id, summary: "beta event" })

    visit workspace_events_path(workspace)

    expect(page).to have_text("alpha event")
    expect(page).to have_no_text("beta event")
  end

  it "shows the empty state when a workspace has no recent events" do
    workspace, = create_workspace_with_run("alpha")

    visit workspace_events_path(workspace)

    expect(page).to have_text("No recent events.")
  end

  it "updates the events index live when a new event is published", :js do
    workspace, run = create_workspace_with_run("alpha")

    visit workspace_events_path(workspace)
    expect(page).to have_text("No recent events.")

    publisher = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sleep 0.5
        BusEvent.publish("run.status", run_id: run.run_id, payload: { runId: run.run_id, summary: "live event arrived" })
      end
    end

    expect(page).to have_text("run.status")
    expect(page).to have_text("live event arrived")

    publisher.join
  end

  def create_workspace_with_run(prefix)
    suffix = "#{prefix}-#{SecureRandom.hex(4)}"
    workspace = Workspace.create!(name: "planner-#{suffix}", root_path: "/tmp/planner-#{suffix}")
    run = Run.create!(
      run_id: "demo-event-#{suffix}",
      task: "Inspect events in #{prefix}",
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running",
      launched_by: "operator",
      started_at: Time.current
    )
    [ workspace, run ]
  end
end
