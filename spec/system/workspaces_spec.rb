require "rails_helper"

RSpec.describe "workspaces", type: :system do
  it "lists current runs in the panel and switches to the selected run's workspace", js: true do
    first_workspace = Workspace.create!(name: "first-#{SecureRandom.hex(4)}", repository_path: "/tmp/first-#{SecureRandom.hex(4)}")
    second_workspace = Workspace.create!(name: "second-#{SecureRandom.hex(4)}", repository_path: "/tmp/second-#{SecureRandom.hex(4)}")
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
  it "adds an existing checkout as a workspace, named after it, and can queue a task in it immediately" do
    repository = File.realpath(create_source_checkout(name: "planner-app"))
    system("git", "-C", repository, "switch", "-q", "-c", "feature/elsewhere", exception: true)

    expect do
      visit workspaces_path
      click_link "Add workspace"
      fill_in "Repository", with: repository
      click_button "Add workspace"
    end.not_to change(Run, :count)

    expect(page).to have_text("Added workspace planner-app.")
    expect(Workspace.find_by!(name: "planner-app")).to have_attributes(repository_path: repository, default_base_branch: "main")
    expect(page).to have_current_path(%r{/workspaces/\d+/runs})
    expect(page).to have_link("Queue a task")
  end

  # The same checks as the register_workspace MCP tool, so a broken
  # repository is caught here rather than by the first run.
  it "refuses a default base branch the repository does not have, and says how to fix it" do
    repository = create_source_checkout

    visit new_workspace_path
    fill_in "Repository", with: repository
    fill_in "Name", with: "wrong-branch"
    fill_in "Default base branch", with: "develop"
    click_button "Add workspace"

    expect(page).to have_text("there is no local branch `develop`")
    expect(Workspace.find_by(name: "wrong-branch")).to be_nil
  end

  it "lets an operator move a workspace to another repository, and change its default base branch" do
    workspace = Workspace.create!(name: "planner-app-#{SecureRandom.hex(4)}", repository_path: Dir.mktmpdir)
    new_repository = File.realpath(create_source_checkout(branches: [ "develop" ]))

    visit workspaces_path
    within(find(".card", text: workspace.name, match: :first)) { click_link "Edit" }

    fill_in "Repository", with: new_repository
    fill_in "Default base branch", with: "develop"
    click_button "Save"

    expect(page).to have_text("Updated workspace #{workspace.name}.")
    expect(workspace.reload).to have_attributes(repository_path: new_repository, default_base_branch: "develop")
  end

  it "does not let an edit move a workspace somewhere runs cannot use" do
    workspace = Workspace.create!(name: "planner-app-#{SecureRandom.hex(4)}", repository_path: create_source_checkout)
    empty = Dir.mktmpdir

    visit edit_workspace_path(workspace)
    fill_in "Repository", with: empty
    click_button "Save"

    expect(page).to have_text("is not inside a git checkout")
    expect(workspace.reload.repository_path).not_to eq(empty)
  end

  it "shows the empty state when no workspaces exist" do
    visit workspaces_path

    expect(page).to have_text("No workspaces registered yet.")
  end

  it "refuses to delete a workspace that still owns runs" do
    suffix = SecureRandom.hex(4)
    workspace = Workspace.create!(name: "planner-app-#{suffix}", repository_path: "/tmp/planner-app-#{suffix}")
    Run.create!(
      run_id: "demo-workspace-delete",
      task: "Keep this workspace busy",
      workspace: workspace,
      target_root: workspace.repository_path,
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
    workspace = Workspace.create!(name: "planner-app-#{suffix}", repository_path: "/tmp/planner-app-#{suffix}")

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
      run_id:, task: run_id, workspace:, target_root: workspace.repository_path,
      launcher_variant: "claude", status: "running", launched_by: "operator", started_at: Time.current
    )
  end

  describe "the layout editor", js: true do
    let(:workspace) do
      Workspace.create!(name: "layout-#{SecureRandom.hex(4)}", repository_path: "/tmp/layout-#{SecureRandom.hex(4)}")
    end

    it "builds named tabs and splits without any YAML, and saves them as the workspace's layout" do
      visit edit_workspace_path(workspace)

      expect(page).to have_text("Using the default layout.")
      expect(page).to have_css(".layout-preview-pane.agent", text: "agent")
      expect(page).to have_css(".layout-preview-pane", text: "editor")

      fill_in "Tab 1 name", with: "main"
      click_button "Add tab"
      fill_in "Tab 2 name", with: "logs"
      fill_in "Pane shell name", with: "dev-log"
      fill_in "Pane shell command", with: "tail -f log/development.log"
      click_button "Add pane to tab 2"
      fill_in "Pane pane-1 name", with: "test-log"
      fill_in "Pane pane-1 command", with: "tail -f log/test.log"
      select "below", from: "Pane pane-1 direction"
      fill_in "Pane pane-1 share kept by the split pane", with: "0.7"

      expect(page).to have_text("This workspace's own layout.")
      expect(page).to have_css(".layout-preview-pane", text: "test-log")
      click_button "Save"

      expect(page).to have_text("Updated workspace #{workspace.name}.")
      expect(workspace.reload.layout).to eq(<<~YAML)
        tabs:
        - name: main
          panes:
          - agent
          - name: editor
            command: nvim .
            split:
              of: agent
              direction: right
        - name: logs
          panes:
          - name: dev-log
            command: tail -f log/development.log
          - name: test-log
            command: tail -f log/test.log
            split:
              of: dev-log
              direction: down
              ratio: 0.7
      YAML

      visit edit_workspace_path(workspace)
      expect(page).to have_field("Tab 2 name", with: "logs")
      expect(page).to have_field("Pane test-log command", with: "tail -f log/test.log")
    end

    it "keeps an invalid layout on screen beside its error" do
      visit edit_workspace_path(workspace)

      fill_in "Pane editor name", with: "agent"
      click_button "Save"

      expect(page).to have_text("duplicate pane name `agent`")
      expect(workspace.reload.layout).to be_nil
    end

    it "goes back to the default layout" do
      workspace.update!(layout: "tabs:\n  - panes: [agent]\n  - name: logs\n    panes: [{ name: dev-log }]\n")

      visit edit_workspace_path(workspace)
      expect(page).to have_field("Tab 2 name", with: "logs")
      click_button "Reset to default"
      expect(page).to have_text("Using the default layout.")
      expect(page).to have_no_field("Tab 2 name")
      click_button "Save"

      expect(page).to have_text("Updated workspace #{workspace.name}.")
      expect(workspace.reload.layout).to be_nil
    end
  end
end
