require "rails_helper"

RSpec.describe "workspaces", type: :system do
  it "lists current runs in the panel and switches to the selected run's workspace", js: true do
    first_workspace = Workspace.create!(name: "first-#{SecureRandom.hex(4)}", root_path: "/tmp/first-#{SecureRandom.hex(4)}")
    second_workspace = Workspace.create!(name: "second-#{SecureRandom.hex(4)}", root_path: "/tmp/second-#{SecureRandom.hex(4)}")
    first_run = create_active_run(first_workspace, "first-current")
    second_run = create_active_run(second_workspace, "second-current")

    visit workspace_run_path(first_workspace, first_run)

    expect(page).to have_css("button[aria-label='Open current runs']")
    expect(page).to have_css("span[aria-label='2 current runs']", text: "2")

    click_button "Open current runs"

    expect(page).to have_link(first_run.run_id, href: workspace_run_path(first_workspace, first_run))
    expect(page).to have_link(second_run.run_id, href: workspace_run_path(second_workspace, second_run))

    click_link second_run.run_id

    expect(page).to have_current_path(workspace_run_path(second_workspace, second_run))
    expect(page).to have_text(second_run.task)
  end

  # There is no bootstrap discovery run any more: a new workspace takes task
  # runs straight away, and sessions record what they learn as they go.
  it "creates a workspace from the index flow and can queue a task in it immediately" do
    suffix = SecureRandom.hex(4)

    expect do
      visit workspaces_path
      click_link "Add workspace"
      fill_in "Name", with: "planner-app-#{suffix}"
      fill_in "Workspace root", with: "/tmp/planner-app-#{suffix}"
      click_button "Add workspace"
    end.not_to change(Run, :count)

    expect(page).to have_text("Added workspace planner-app-#{suffix}.")
    expect(page).to have_current_path(%r{/workspaces/\d+/runs})
    expect(page).to have_text("planner-app-#{suffix} Runs")
    expect(page).to have_link("Queue a task")
    expect(page).to have_no_button("Re-run project setup")
  end

  it "lets an operator edit a workspace's root" do
    workspace = Workspace.create!(name: "planner-app-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    new_root = Dir.mktmpdir

    visit workspaces_path
    within(find(".card", text: workspace.name, match: :first)) { click_link "Edit" }

    fill_in "Workspace root", with: new_root
    click_button "Save"

    expect(page).to have_text("Updated workspace #{workspace.name}.")
    expect(workspace.reload.root_path).to eq(new_root)
  end

  it "shows the empty state when no workspaces exist" do
    visit workspaces_path

    expect(page).to have_text("No workspaces registered yet.")
  end

  it "refuses to delete a workspace that still owns runs" do
    suffix = SecureRandom.hex(4)
    workspace = Workspace.create!(name: "planner-app-#{suffix}", root_path: "/tmp/planner-app-#{suffix}")
    Run.create!(
      run_id: "demo-workspace-delete",
      task: "Keep this workspace busy",
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running",
      launched_by: "operator",
      started_at: Time.current
    )

    visit workspaces_path
    within(find(".card", text: workspace.name, match: :first)) do
      click_button "Remove"
    end

    expect(page).to have_current_path(workspaces_path)
    expect(page).to have_text("Cannot delete record because dependent runs exist")
    expect(Workspace.exists?(workspace.id)).to be(true)
  end

  it "deletes an empty workspace from the index" do
    suffix = SecureRandom.hex(4)
    workspace = Workspace.create!(name: "planner-app-#{suffix}", root_path: "/tmp/planner-app-#{suffix}")

    visit workspaces_path
    within(find(".card", text: workspace.name, match: :first)) do
      click_button "Remove"
    end

    expect(page).to have_text("Removed workspace planner-app-#{suffix}.")
    expect(page).to have_text("No workspaces registered yet.")
    expect(Workspace.exists?(workspace.id)).to be(false)
  end

  def create_active_run(workspace, run_id)
    Run.create!(
      run_id:, task: run_id, workspace:, target_root: workspace.source_root,
      launcher_variant: "claude", status: "running", launched_by: "operator", started_at: Time.current
    )
  end
end
