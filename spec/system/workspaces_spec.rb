require "rails_helper"

RSpec.describe "workspaces", type: :system do
  it "creates a workspace from the index flow, auto-launches its bootstrap run, and redirects into its runs" do
    suffix = SecureRandom.hex(4)

    expect do
      visit workspaces_path
      click_link "Add workspace"
      fill_in "Name", with: "planner-app-#{suffix}"
      fill_in "Root path", with: "/tmp/planner-app-#{suffix}"
      click_button "Add workspace"
    end.to change(Run, :count).by(1)

    expect(page).to have_text("Added workspace planner-app-#{suffix}. Discovering its dev environment and protected paths…")
    expect(page).to have_current_path(%r{/workspaces/\d+/runs})
    expect(page).to have_text("planner-app-#{suffix} Runs")
    expect(page).to have_no_link("Launch task")
    expect(page).to have_text("still initializing")

    workspace = Workspace.find_by!(name: "planner-app-#{suffix}")
    run = workspace.runs.sole
    expect(run.launched_by).to eq("workspace_init")
    expect(run.spawn_requests.find_by(requested_role: "project_init")).to be_present
    # No planner request either: a planner has no visibility into
    # project_init's workspace-level findings, so queuing one here re-plans
    # the same discovery as a redundant step instead of ever finishing --
    # see Orchestrator::WorkspaceInit's comment.
    expect(run.spawn_requests.find_by(requested_role: "planner")).to be_nil
  end

  it "lets an operator edit a workspace's protected path patterns" do
    workspace = Workspace.create!(
      name: "planner-app-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir,
      protected_path_patterns: [ "app/controllers/**/*.rb" ]
    )

    visit workspaces_path
    within(find(".card", text: workspace.name, match: :first)) { click_link "Edit" }

    expect(page).to have_field("Protected path patterns", with: "app/controllers/**/*.rb")

    fill_in "Protected path patterns", with: "app/controllers/**/*.rb\ndb/migrate/**"
    click_button "Save"

    expect(page).to have_text("Updated workspace #{workspace.name}.")
    expect(workspace.reload.protected_path_patterns).to eq(%w[app/controllers/**/*.rb db/migrate/**])
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
end
