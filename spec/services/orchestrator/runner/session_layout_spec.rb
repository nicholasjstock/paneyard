require "rails_helper"

RSpec.describe Orchestrator::Runner::SessionLayout do
  let(:env) { { "PANEYARD_RUN_ID" => "run-1", "PANEYARD_RUN_TOKEN" => "secret", "GH_TOKEN" => "gh" } }
  let(:cwd) { "/tmp/run-1" }

  # The layout as the orchestrator hands it over (WorkspaceLayout.for).
  def layout(yaml)
    Orchestrator::WorkspaceLayout.for(Workspace.new(name: "layout", root_path: "/tmp/layout", layout: yaml))
  end

  before do
    allow(Orchestrator::Runner::Herdr).to receive(:workspace_create)
      .and_return("root_pane" => { "pane_id" => "w1:p1", "tab_id" => "w1:t1", "workspace_id" => "w1" })
    tab_ids = Enumerator.new { |y| (2..).each { |n| y << n } }
    allow(Orchestrator::Runner::Herdr).to receive(:tab_create) do
      n = tab_ids.next
      { "tab" => { "tab_id" => "w1:t#{n}" }, "root_pane" => { "pane_id" => "w1:t#{n}root" } }
    end
    allow(Orchestrator::Runner::Herdr).to receive(:pane_split) { |target_pane_id:, **| { "pane_id" => "#{target_pane_id}>" } }
    allow(Orchestrator::Runner::Herdr).to receive(:pane_rename)
    allow(Orchestrator::Runner::Herdr).to receive(:tab_rename)
    allow(Orchestrator::Runner::Herdr).to receive(:pane_send_input)
  end

  it "opens the workspace unfocused with the agent as the first tab's root, and returns that pane" do
    pane = described_class.open!(label: "run-1", cwd:, env:, tabs: layout("tabs:\n  - panes: [agent]\n"))

    expect(pane).to include("pane_id" => "w1:p1", "tab_id" => "w1:t1", "workspace_id" => "w1")
    expect(Orchestrator::Runner::Herdr).to have_received(:workspace_create).with(label: "run-1", cwd:, env:, focus: false)
    # The agent is started by SessionLauncher, never typed into here.
    expect(Orchestrator::Runner::Herdr).not_to have_received(:pane_send_input)
    expect(Orchestrator::Runner::Herdr).not_to have_received(:tab_rename)
  end

  it "builds every tab and split in order, each pane with the full session env, none of them focused" do
    described_class.open!(label: "run-1", cwd:, env:, tabs: layout(<<~YAML))
      tabs:
        - name: main
          panes:
            - agent
            - name: editor
              command: nvim .
              split: { of: agent, direction: right, ratio: 0.6 }
            - name: shell
              split: { of: editor, direction: down }
        - name: logs
          panes:
            - name: dev-log
              command: tail -f log/development.log
            - name: test-log
              command: tail -f log/test.log
              split: { of: dev-log, direction: down }
        - name: specs
          panes:
            - name: guard
              command: bundle exec guard
    YAML

    expect(Orchestrator::Runner::Herdr).to have_received(:tab_rename).with("w1:t1", "main")
    expect(Orchestrator::Runner::Herdr).to have_received(:pane_split)
      .with(target_pane_id: "w1:p1", direction: "right", ratio: 0.6, cwd:, env:, focus: false)
    expect(Orchestrator::Runner::Herdr).to have_received(:pane_split)
      .with(target_pane_id: "w1:p1>", direction: "down", ratio: nil, cwd:, env:, focus: false)
    expect(Orchestrator::Runner::Herdr).to have_received(:tab_create)
      .with(workspace_id: "w1", label: "logs", cwd:, env:, focus: false)
    expect(Orchestrator::Runner::Herdr).to have_received(:tab_create)
      .with(workspace_id: "w1", label: "specs", cwd:, env:, focus: false)
    expect(Orchestrator::Runner::Herdr).to have_received(:pane_split)
      .with(target_pane_id: "w1:t2root", direction: "down", ratio: nil, cwd:, env:, focus: false)

    expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input).with("w1:p1>", text: "nvim .", keys: [ "Enter" ])
    expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input)
      .with("w1:t2root", text: "tail -f log/development.log", keys: [ "Enter" ])
    expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input)
      .with("w1:t2root>", text: "tail -f log/test.log", keys: [ "Enter" ])
    expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input)
      .with("w1:t3root", text: "bundle exec guard", keys: [ "Enter" ])
    # A pane with no command is left as a plain shell.
    expect(Orchestrator::Runner::Herdr).not_to have_received(:pane_send_input).with("w1:p1>>", anything)

    %w[editor shell dev-log test-log guard].each do |name|
      expect(Orchestrator::Runner::Herdr).to have_received(:pane_rename).with(anything, name)
    end
    expect(Orchestrator::Runner::Herdr).not_to have_received(:pane_rename).with(anything, "agent")
  end

  it "skips a pane that cannot be created along with the panes split from it, and carries on" do
    allow(Orchestrator::Runner::Herdr).to receive(:pane_split).with(hash_including(target_pane_id: "w1:p1"))
      .and_raise(Orchestrator::Runner::Herdr::Error, "no room")

    described_class.open!(label: "run-1", cwd:, env:, tabs: layout(<<~YAML))
      tabs:
        - panes:
            - agent
            - { name: editor, command: nvim ., split: { of: agent } }
            - { name: shell, split: { of: editor } }
        - panes:
            - { name: logs, command: tail -f x }
    YAML

    expect(Orchestrator::Runner::Herdr).to have_received(:pane_split).once
    expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input).with("w1:t2root", text: "tail -f x", keys: [ "Enter" ])
  end

  it "skips a whole tab that cannot be opened, and carries on with the next" do
    allow(Orchestrator::Runner::Herdr).to receive(:tab_create).with(hash_including(label: "broken"))
      .and_raise(Orchestrator::Runner::Herdr::Error, "boom")
    allow(Orchestrator::Runner::Herdr).to receive(:tab_create).with(hash_including(label: "fine"))
      .and_return("tab" => { "tab_id" => "w1:t3" }, "root_pane" => { "pane_id" => "w1:t3root" })

    described_class.open!(label: "run-1", cwd:, env:, tabs: layout(<<~YAML))
      tabs:
        - panes: [agent]
        - name: broken
          panes: [{ name: a, command: echo a }, { name: b, command: echo b, split: { of: a } }]
        - name: fine
          panes: [{ name: c, command: echo c }]
    YAML

    expect(Orchestrator::Runner::Herdr).not_to have_received(:pane_split)
    expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input).once
    expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input).with("w1:t3root", text: "echo c", keys: [ "Enter" ])
  end

  it "keeps a pane it could not label, and still starts its command" do
    allow(Orchestrator::Runner::Herdr).to receive(:pane_rename).and_raise(Orchestrator::Runner::Herdr::Error, "nope")

    described_class.open!(label: "run-1", cwd:, env:,
                          tabs: layout("tabs:\n  - panes: [agent, { name: e, command: nvim ., split: { of: agent } }]\n"))

    expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input).with("w1:p1>", text: "nvim .", keys: [ "Enter" ])
  end

  it "fails when the agent's workspace itself cannot be created" do
    allow(Orchestrator::Runner::Herdr).to receive(:workspace_create).and_raise(Orchestrator::Runner::Herdr::Unreachable, "down")

    expect { described_class.open!(label: "run-1", cwd:, env:, tabs: layout("tabs:\n  - panes: [agent]\n")) }
      .to raise_error(Orchestrator::Runner::Herdr::Unreachable)
  end

  it "leaves out a pane whose required command this machine does not have" do
    allow(described_class).to receive(:executable_on_path?).with("nvim").and_return(false)
    tabs = [ { "name" => nil, "panes" => [
      { "name" => "agent" },
      { "name" => "editor", "command" => "nvim .", "split_of" => "agent", "direction" => "right", "requires" => "nvim" }
    ] } ]

    described_class.open!(label: "run-1", cwd:, env:, tabs:)

    expect(Orchestrator::Runner::Herdr).not_to have_received(:pane_split)
    expect(Orchestrator::Runner::Herdr).not_to have_received(:pane_send_input)
  end
end
