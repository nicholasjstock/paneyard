require "rails_helper"
require "open3"

# The contract between Orchestrator::Runner::Herdr (the real client) and the fake.
# Every lifecycle spec and the sandbox instance trust the fake to answer the
# way herdr does, so the shapes the client parses are pinned here, over the
# real socket.
RSpec.describe FakeHerdr::Server, :fake_herdr do
  let(:herdr) { Orchestrator::Runner::Herdr }

  def wait_for(timeout: 5)
    deadline = Time.current + timeout
    until (value = yield)
      raise "timed out waiting" if Time.current > deadline

      sleep 0.05
    end
    value
  end

  it "is what specs reach instead of the operator's herdr" do
    expect(herdr.socket_path).to eq(fake_herdr.socket_path)
    expect(herdr.socket_path).not_to include(".config/herdr")
  end

  # A run's herdr workspace is the one worktree.create opens.
  def open_worktree(repository = create_source_checkout, branch: "paneyard/run-1", base: "main")
    herdr.worktree_create(cwd: repository, branch:, base:, label: "run-1")
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir.to_s, *args)
    raise out unless status.success?

    out.strip
  end

  it "creates a run's worktree from a base that is not checked out, wherever it likes, and opens it" do
    repository = create_source_checkout(branches: [ "feature/payments" ])
    git(repository, "switch", "-q", "-c", "unrelated")

    created = open_worktree(repository, branch: "paneyard/from-payments", base: "feature/payments")

    path = created.dig("worktree", "path")
    expect(created.dig("root_pane", "pane_id")).to eq("w1:p1")
    expect(created.dig("worktree", "branch")).to eq("paneyard/from-payments")
    expect(git(path, "rev-parse", "HEAD")).to eq(git(repository, "rev-parse", "feature/payments"))
    expect(git(repository, "branch", "--show-current")).to eq("unrelated")
    expect(File.realpath(path)).not_to start_with(File.realpath(repository) + "/")
    expect(fake_herdr.requests_for("worktree.create").last).not_to have_key("path")
  end

  it "supports the layout calls in a worktree's workspace" do
    root = open_worktree.fetch("root_pane")

    split = herdr.pane_split(target_pane_id: root["pane_id"], direction: "right", cwd: Dir.pwd, ratio: 0.6)
    tab = herdr.tab_create(workspace_id: "w1", cwd: Dir.pwd, label: "logs")
    herdr.pane_rename(split.fetch("pane_id"), "editor")
    herdr.tab_rename(tab.fetch("tab").fetch("tab_id"), "logs")
    herdr.pane_send_input(split.fetch("pane_id"), text: "nvim .", keys: [ "Enter" ])

    expect(split.fetch("pane_id")).to eq("w1:p2")
    expect(tab.fetch("root_pane").fetch("tab_id")).to eq("w1:t2")
    expect(herdr.pane_read(split.fetch("pane_id"))).to include("$ nvim .")
    expect(herdr.pane_list(workspace_id: "w1").map { |pane| pane["pane_id"] }).to eq(%w[w1:p1 w1:p2 w1:p3])
    herdr.tab_close(tab.dig("tab", "tab_id"))
    expect(herdr.pane_list(workspace_id: "w1").map { |pane| pane["pane_id"] }).to eq(%w[w1:p1 w1:p2])
  end

  it "removes a linked worktree only through its open workspace, keeping the branch" do
    repository = create_source_checkout
    created = open_worktree(repository)
    path = created.dig("worktree", "path")
    herdr.workspace_close("w1")

    expect { herdr.worktree_remove("w1") }.to raise_error(Orchestrator::Runner::Herdr::Error, /workspace w1 not found/)
    reopened = herdr.worktree_open(cwd: repository, path:)
    expect(reopened).to include("already_open" => false)
    expect(herdr.worktree_open(cwd: repository, path:)).to include("already_open" => true)

    removed = herdr.worktree_remove(reopened.dig("workspace", "workspace_id"))

    expect(removed).to include("type" => "worktree_removed", "forced" => false)
    expect(File.exist?(path)).to be(false)
    expect(git(repository, "branch", "--list", "paneyard/run-1")).to include("paneyard/run-1")
    expect(fake_herdr.workspace_ids).to be_empty
  end

  it "refuses to remove a dirty worktree unless forced, and never a primary checkout" do
    repository = create_source_checkout
    created = open_worktree(repository)
    File.write(File.join(created.dig("worktree", "path"), "scratch.txt"), "work")

    expect { herdr.worktree_remove("w1") }.to raise_error(Orchestrator::Runner::Herdr::Error, /modified or untracked/)
    expect { herdr.worktree_remove("w1", force: true) }.not_to raise_error

    primary = herdr.request!("workspace.create", label: "repo", cwd: repository, focus: false)
    expect { herdr.worktree_remove(primary.dig("workspace", "workspace_id")) }
      .to raise_error(Orchestrator::Runner::Herdr::Error, /not a linked worktree/)
    expect(File.exist?(File.join(repository, "README.md"))).to be(true)
  end

  it "reports an idle shell until an agent starts, then the agent's own process group" do
    pane_id = open_worktree.dig("root_pane", "pane_id")
    idle = herdr.pane_process_info(pane_id)
    expect(idle.fetch("foreground_process_group_id")).to eq(idle.fetch("shell_pid"))
    expect(idle.fetch("foreground_processes").map { |process| process["pid"] }).to eq([ idle.fetch("shell_pid") ])

    herdr.agent_start(name: "run-1", kind: "claude", pane_id:, args: [ "--model", "opus" ])
    agent = wait_for { herdr.agent_get(pane_id).then { |info| info if info["interactive_ready"] } }
    pid = herdr.pane_process_info(pane_id).fetch("foreground_process_group_id")

    expect(agent).to include("agent" => "claude", "agent_status" => "idle")
    expect(agent.dig("agent_session", "value")).to start_with("fake-")
    expect(Process.getpgid(pid)).to eq(pid)
    expect { herdr.agent_start(name: "again", kind: "claude", pane_id:, args: []) }
      .to raise_error(Orchestrator::Runner::Herdr::Error, /not an available shell/)
  end

  it "delivers a prompt to the agent and shows its output in pane.read" do
    pane_id = open_worktree.dig("root_pane", "pane_id")
    herdr.agent_start(name: "run-1", kind: "claude", pane_id:, args: [])
    wait_for { herdr.agent_get(pane_id)["interactive_ready"] }

    herdr.agent_prompt(pane_id, "# Task\n\nDo the thing")

    expect(wait_for { herdr.pane_read(pane_id).then { |text| text if text.include?("received a") } })
      .to include("mode manual")
  end

  # Confirmed live on herdr 0.7.5: an existing branch is checked out at its
  # own commit, with a base or without one, at the path herdr would give it.
  it "makes a worktree on an existing branch as it is, ignoring the base" do
    repository = create_source_checkout
    first = open_worktree(repository)
    path = first.dig("worktree", "path")
    commit = git(path, "-c", "user.email=a@example.test", "-c", "user.name=A", "commit", "-q", "--allow-empty", "-m", "Work").then do
      git(path, "rev-parse", "HEAD")
    end
    herdr.worktree_remove("w1")

    again = open_worktree(repository, base: nil)

    expect(again.dig("worktree", "path")).to eq(path)
    expect(again.dig("worktree", "branch")).to eq("paneyard/run-1")
    expect(git(path, "rev-parse", "HEAD")).to eq(commit)
  end

  it "resumes an agent's conversation in the directory it ran in, and exits at once on one it never had" do
    pane_id = open_worktree.dig("root_pane", "pane_id")
    herdr.agent_start(name: "run-1", kind: "claude", pane_id:, args: [])
    conversation = wait_for { herdr.agent_get(pane_id).dig("agent_session", "value") }
    Process.kill("TERM", -herdr.pane_process_info(pane_id).fetch("foreground_process_group_id"))
    wait_for { herdr.pane_process_info(pane_id).then { |info| info["foreground_process_group_id"] == info["shell_pid"] } }

    herdr.agent_start(name: "run-1", kind: "claude", pane_id:, args: [ "--resume", conversation ])
    expect(wait_for { herdr.agent_get(pane_id).then { |info| info if info["interactive_ready"] } }.dig("agent_session", "value"))
      .to eq(conversation)
    Process.kill("TERM", -herdr.pane_process_info(pane_id).fetch("foreground_process_group_id"))
    wait_for { herdr.pane_process_info(pane_id).then { |info| info["foreground_process_group_id"] == info["shell_pid"] } }

    herdr.agent_start(name: "run-1", kind: "codex", pane_id:, args: [ "resume", "fake-unknown" ])
    expect(wait_for { herdr.pane_read(pane_id).then { |text| text if text.scan("[fake agent exited]").size == 3 } })
      .to include("No conversation found with session ID: fake-unknown")
    expect(herdr.agent_get(pane_id)["agent"]).to be_nil
  end

  it "answers agent.get for a pane with no agent the way herdr does" do
    pane_id = open_worktree.dig("root_pane", "pane_id")

    expect { herdr.agent_get(pane_id) }.to raise_error(Orchestrator::Runner::Herdr::Error, /agent target .* not found/)
  end

  it "kills every agent in a workspace when it is closed, after which the panes are gone" do
    pane_id = open_worktree.dig("root_pane", "pane_id")
    herdr.agent_start(name: "run-1", kind: "claude", pane_id:, args: [])
    wait_for { herdr.agent_get(pane_id)["interactive_ready"] }
    pid = herdr.pane_process_info(pane_id).fetch("foreground_process_group_id")

    herdr.workspace_close("w1")

    wait_for { !(Process.kill(0, pid) rescue false) }
    expect { herdr.request!("workspace.get", workspace_id: "w1") }.to raise_error(Orchestrator::Runner::Herdr::Error)
    expect { herdr.request!("pane.get", pane_id:) }.to raise_error(Orchestrator::Runner::Herdr::Error)
    expect { herdr.agent_get(pane_id) }.to raise_error(Orchestrator::Runner::Herdr::Error, /not found/)
  end

  it "records every request so specs can assert on what Rails asked for" do
    open_worktree
    herdr.notify(title: "hello")

    expect(fake_herdr.requests_for("worktree.create").first).to include("label" => "run-1", "focus" => false, "base" => "main")
    expect(fake_herdr.requests_for("notification.show")).to eq([ { "title" => "hello", "body" => nil, "sound" => "done" } ])
  end

  it "rejects methods herdr does not have" do
    expect { herdr.request!("pane.explode", pane_id: "w1:p1") }.to raise_error(Orchestrator::Runner::Herdr::Error, /unknown method/)
  end
end
