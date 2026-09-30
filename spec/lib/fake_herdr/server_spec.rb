require "rails_helper"

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

  it "opens a workspace with the agent pane as its root and supports the layout calls" do
    root = herdr.workspace_create(label: "run-1", cwd: Dir.pwd, env: { "A" => "1" }).fetch("root_pane")
    expect(root).to eq("pane_id" => "w1:p1", "tab_id" => "w1:t1", "workspace_id" => "w1")

    split = herdr.pane_split(target_pane_id: root["pane_id"], direction: "right", cwd: Dir.pwd, ratio: 0.6, env: {})
    tab = herdr.tab_create(workspace_id: "w1", cwd: Dir.pwd, label: "logs")
    herdr.pane_rename(split.fetch("pane_id"), "editor")
    herdr.tab_rename(tab.fetch("tab").fetch("tab_id"), "logs")
    herdr.pane_send_input(split.fetch("pane_id"), text: "nvim .", keys: [ "Enter" ])

    expect(split.fetch("pane_id")).to eq("w1:p2")
    expect(tab.fetch("root_pane").fetch("tab_id")).to eq("w1:t2")
    expect(herdr.pane_read(split.fetch("pane_id"))).to include("$ nvim .")
    expect { herdr.request!("workspace.get", workspace_id: "w1") }.not_to raise_error
    expect { herdr.request!("pane.get", pane_id: "w1:p2") }.not_to raise_error
  end

  it "reports an idle shell until an agent starts, then the agent's own process group" do
    pane_id = herdr.workspace_create(label: "run-1", cwd: Dir.pwd).dig("root_pane", "pane_id")
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
    pane_id = herdr.workspace_create(label: "run-1", cwd: Dir.pwd).dig("root_pane", "pane_id")
    herdr.agent_start(name: "run-1", kind: "claude", pane_id:, args: [])
    wait_for { herdr.agent_get(pane_id)["interactive_ready"] }

    herdr.agent_prompt(pane_id, "# Task\n\nDo the thing")

    expect(wait_for { herdr.pane_read(pane_id).then { |text| text if text.include?("received a") } })
      .to include("mode manual")
  end

  it "answers agent.get for a pane with no agent the way herdr does" do
    pane_id = herdr.workspace_create(label: "run-1", cwd: Dir.pwd).dig("root_pane", "pane_id")

    expect { herdr.agent_get(pane_id) }.to raise_error(Orchestrator::Runner::Herdr::Error, /agent target .* not found/)
  end

  it "kills every agent in a workspace when it is closed, after which the panes are gone" do
    pane_id = herdr.workspace_create(label: "run-1", cwd: Dir.pwd).dig("root_pane", "pane_id")
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
    herdr.workspace_create(label: "run-1", cwd: "/tmp", env: { "PANEYARD_RUN_ID" => "run-1" })
    herdr.notify(title: "hello")

    expect(fake_herdr.requests_for("workspace.create").first).to include("label" => "run-1", "focus" => false)
    expect(fake_herdr.requests_for("notification.show")).to eq([ { "title" => "hello", "body" => nil, "sound" => "done" } ])
  end

  it "rejects methods herdr does not have" do
    expect { herdr.request!("pane.explode", pane_id: "w1:p1") }.to raise_error(Orchestrator::Runner::Herdr::Error, /unknown method/)
  end
end
