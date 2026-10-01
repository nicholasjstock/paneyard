require "rails_helper"

RSpec.describe Orchestrator::WorkspaceLayout do
  describe ".parse" do
    it "reads tabs of panes, each after a tab's root split off an earlier pane" do
      tabs = described_class.parse(<<~YAML)
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
                command: tail -f "log/test.log" && echo $PANEYARD_RUN_ID
                split: { of: dev-log }
      YAML

      expect(tabs.map(&:name)).to eq(%w[main logs])
      expect(tabs.first.panes.map(&:name)).to eq(%w[agent editor shell])
      expect(tabs.first.panes.first).to be_agent
      expect(tabs.first.panes[1]).to have_attributes(
        command: "nvim .", split_of: "agent", direction: "right", ratio: 0.6
      )
      # No command: a plain shell.
      expect(tabs.first.panes[2]).to have_attributes(command: nil, split_of: "editor", direction: "down", ratio: nil)
      expect(tabs.last.panes.first).to have_attributes(name: "dev-log", split_of: nil)
      # Shell text is kept verbatim, and direction defaults to right.
      expect(tabs.last.panes.last).to have_attributes(
        command: 'tail -f "log/test.log" && echo $PANEYARD_RUN_ID', direction: "right"
      )
    end

    it "accepts an agent-only layout" do
      tabs = described_class.parse("tabs:\n  - panes: [agent]\n")

      expect(tabs.size).to eq(1)
      expect(tabs.first.panes.map(&:name)).to eq(%w[agent])
    end

    {
      "invalid YAML" => [ "tabs: [", /not valid YAML/ ],
      "no tabs" => [ "panes: []", /non-empty `tabs:`/ ],
      "an empty tab" => [ "tabs:\n  - panes: [agent]\n  - panes: []\n", /tab 2 must have a non-empty `panes:`/ ],
      "no agent" => [ "tabs:\n  - panes: [{ name: logs }]\n", /`agent` must be the first pane of the first tab/ ],
      "the agent as a split" => [
        "tabs:\n  - panes:\n    - { name: logs }\n    - { name: agent, split: { of: logs } }\n",
        /`agent` must be the first pane of the first tab/
      ],
      "the agent outside the first tab" => [
        "tabs:\n  - panes: [agent]\n  - panes: [agent]\n", /duplicate pane name `agent`/
      ],
      "a command on the agent" => [ "tabs:\n  - panes: [{ name: agent, command: ls }]\n", /agent pane takes no command/ ],
      "a split on a tab's root" => [
        "tabs:\n  - panes: [agent]\n  - panes: [{ name: logs, split: { of: agent } }]\n",
        /first pane of a tab is its root/
      ],
      "a later pane without a split" => [ "tabs:\n  - panes: [agent, { name: logs }]\n", /needs `split: { of: <pane> }`/ ],
      "a split of a pane in another tab" => [
        "tabs:\n  - panes: [agent]\n  - panes: [{ name: a }, { name: b, split: { of: agent } }]\n",
        /must name an earlier pane in the same tab/
      ],
      "a split of a later pane" => [
        "tabs:\n  - panes: [agent, { name: a, split: { of: b } }, { name: b, split: { of: agent } }]\n",
        /must name an earlier pane in the same tab \(got "b"\)/
      ],
      "a duplicate name" => [
        "tabs:\n  - panes: [agent, { name: a, split: { of: agent } }]\n  - panes: [{ name: a }]\n",
        /duplicate pane name `a`/
      ],
      "a bad name" => [ "tabs:\n  - panes: [agent, { name: 'Dev Log', split: { of: agent } }]\n", /name must match/ ],
      "a bad direction" => [
        "tabs:\n  - panes: [agent, { name: a, split: { of: agent, direction: left } }]\n", /direction must be one of/
      ],
      "a bad ratio" => [ "tabs:\n  - panes: [agent, { name: a, split: { of: agent, ratio: 2 } }]\n", /ratio must be/ ],
      "an unknown key" => [ "tabs:\n  - panes: [agent, { name: a, focus: true, split: { of: agent } }]\n", /unknown key\(s\): focus/ ]
    }.each do |description, (yaml, message)|
      it "rejects #{description}" do
        expect { described_class.parse(yaml) }.to raise_error(described_class::Invalid, message)
      end
    end

    it "rejects a command that is too long" do
      yaml = "tabs:\n  - panes: [agent]\n  - panes: [{ name: a, command: '#{'x' * 1025}' }]\n"

      expect { described_class.parse(yaml) }.to raise_error(described_class::Invalid, /longer than 1024 bytes/)
    end

    it "caps the total number of panes" do
      extra = (1..described_class::MAX_PANES).map { |i| "{ name: p#{i}, split: { of: agent } }" }.join(", ")

      expect { described_class.parse("tabs:\n  - panes: [agent, #{extra}]\n") }
        .to raise_error(described_class::Invalid, /at most #{described_class::MAX_PANES} panes/)
    end
  end

  describe ".for" do
    let(:workspace) { Workspace.new(name: "layout-for", repository_path: "/tmp/layout-for") }

    def pane_names(tabs)
      tabs.map { |tab| tab["panes"].map { |pane| pane["name"] } }
    end

    it "gives a workspace with no layout the agent with nvim split beside it, the editor only where nvim is" do
      tabs = described_class.for(workspace)

      expect(pane_names(tabs)).to eq([ %w[agent editor] ])
      expect(tabs.first["panes"].last).to include(
        "command" => "nvim .", "split_of" => "agent", "direction" => "right", "requires" => "nvim"
      )
      expect(tabs.first["panes"].first["requires"]).to be_nil
    end

    it "uses the workspace's own layout when it has one, requiring nothing of the runner's machine" do
      workspace.layout = "tabs:\n  - panes: [agent, { name: ed, command: nvim ., split: { of: agent } }]\n" \
                         "  - panes: [{ name: logs, command: tail -f x }]\n"

      tabs = described_class.for(workspace)

      expect(pane_names(tabs)).to eq([ %w[agent ed], %w[logs] ])
      expect(tabs.flat_map { |tab| tab["panes"] }.pluck("requires")).to all(be_nil)
    end

    it "falls back to the default rather than stopping runs when a stored layout no longer validates" do
      workspace.layout = "tabs:\n  - panes: [{ name: logs }]\n"

      expect(pane_names(described_class.for(workspace))).to eq([ %w[agent editor] ])
    end
  end

  describe ".dump" do
    it "writes canonical YAML that parses back to the same layout, from JSON as the form's editor sends it" do
      json = '{"tabs":[{"name":"main","panes":["agent",{"name":"editor","command":"nvim .",' \
             '"split":{"of":"agent","direction":"right","ratio":0.6}}]},{"panes":[{"name":"logs"}]}]}'
      tabs = described_class.parse(json)

      yaml = described_class.dump(tabs)

      expect(yaml).to start_with("tabs:\n- name: main\n")
      expect(yaml).not_to include("command: \n")
      expect(described_class.parse(yaml)).to eq(tabs)
    end
  end

  describe ".editor_data" do
    it "gives the editor the default layout when there is none" do
      expect(described_class.editor_data(nil)).to eq([
        { "name" => nil, "panes" => [ { "name" => "agent" },
                                       { "name" => "editor", "command" => "nvim .",
                                         "split" => { "of" => "agent", "direction" => "right" } } ] }
      ])
    end

    # A submitted layout with a mistake must come back as the operator left
    # it, beside its error, not be reset.
    it "hands back an invalid but tab-shaped layout unvalidated" do
      data = described_class.editor_data("tabs:\n  - panes: [agent, { name: agent }]\n")

      expect(data).to eq([ { "name" => nil, "panes" => [ { "name" => "agent" }, { "name" => "agent" } ] } ])
    end

    it "starts over from the default for something that is not a layout at all" do
      expect(described_class.editor_data("just words")).to eq(described_class.editor_data(nil))
    end
  end
end
