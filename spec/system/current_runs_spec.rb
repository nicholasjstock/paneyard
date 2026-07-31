require "rails_helper"

RSpec.describe "current runs panel", type: :system do
  def create_active_run(workspace, run_id)
    Run.create!(
      run_id:, task: run_id, workspace:, target_root: workspace.source_root,
      launcher_variant: "claude", status: "running", launched_by: "operator", started_at: Time.current
    )
  end

  it "shows a badge counting the number of active runs" do
    workspace = Workspace.create!(name: "panel-ws-#{SecureRandom.hex(4)}", root_path: "/tmp/panel-ws-#{SecureRandom.hex(4)}")
    create_active_run(workspace, "panel-run-one")
    create_active_run(workspace, "panel-run-two")

    visit workspaces_path

    expect(page).to have_css("button[aria-label='Open current runs']")
    expect(page).to have_css("span[aria-label='2 current runs']", text: "2")
  end

  it "opens and closes the panel like the notification drawer", js: true do
    workspace = Workspace.create!(name: "panel-ws-#{SecureRandom.hex(4)}", root_path: "/tmp/panel-ws-#{SecureRandom.hex(4)}")
    run = create_active_run(workspace, "panel-run-one")

    visit workspaces_path

    click_button "Open current runs"

    expect(page).to have_css("aside[aria-label='Current runs'][aria-hidden='false']")
    expect(page).to have_css("body.runs-open .runs-drawer")
    expect(page).to have_css("button[aria-label='Open current runs'][aria-expanded='true']")
    within("aside[aria-label='Current runs']") do
      expect(page).to have_text(/in progress/i)
      expect(page).to have_link(run.run_id, href: workspace_run_path(workspace, run))
    end

    click_button "Close current runs"

    expect(page).to have_css("aside[aria-label='Current runs'][aria-hidden='true']")
  end
end
