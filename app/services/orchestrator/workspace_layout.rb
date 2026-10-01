require "yaml"

module Orchestrator
  # The herdr panes a run's workspace opens with, configured per Workspace
  # (workspaces.layout, YAML text edited on the workspace form). Parsing and
  # validation only -- the runner's Runner::SessionLayout is what builds it,
  # from the plain data #for hands it.
  #
  # A layout is a list of tabs; each tab is a list of panes, built as a split
  # tree in list order. The agent pane is the one obligatory pane and is always
  # the first pane of the first tab: every tab's active pane is its first one,
  # so that is what puts the run's first view on the agent. (Making any other
  # pane active is not possible without focusing the whole herdr workspace --
  # confirmed live that pane.split's focus flag pulls the workspace into the
  # operator's view -- and a run must never take over their screen.)
  #
  #   tabs:
  #     - name: main
  #       panes:
  #         - agent
  #         - name: editor
  #           command: nvim .
  #           split: { of: agent, direction: right, ratio: 0.5 }
  #     - name: logs
  #       panes:
  #         - name: dev-log
  #           command: tail -f log/development.log
  #
  # A command is shell text typed into the pane's own shell, so it gets the
  # operator's PATH and rc files, and falls back to a prompt if it dies.
  module WorkspaceLayout
    module_function

    class Invalid < StandardError; end

    Tab = Data.define(:name, :panes)
    Pane = Data.define(:name, :command, :split_of, :direction, :ratio) do
      def agent?
        name == AGENT
      end
    end

    AGENT = "agent".freeze
    DIRECTIONS = %w[right down].freeze
    NAME_PATTERN = /\A[a-z0-9_-]{1,32}\z/
    MAX_PANES = 32
    MAX_COMMAND_BYTES = 1024
    TAB_KEYS = %w[name panes].freeze
    PANE_KEYS = %w[name command split].freeze
    SPLIT_KEYS = %w[of direction ratio].freeze

    # What a workspace with no layout of its own gets: the agent alone. The
    # layout builder starts from it.
    DEFAULT_YAML = <<~YAML.freeze
      tabs:
        - panes:
            - agent
    YAML

    # The layout a run of this workspace opens with, as the plain data the
    # runner takes:
    #
    #   [{ "name", "panes" => [{ "name", "command", "split_of", "direction",
    #                            "ratio" }] }]
    #
    # A missing command just shows up as "command not found" in its own pane.
    #
    # A stored layout is validated when it is saved, so an invalid one here
    # means the rules changed underneath it. That must not stop runs from
    # starting, so it falls back to the default.
    def for(workspace)
      tabs = custom(workspace) || parse(DEFAULT_YAML)

      tabs.map do |tab|
        panes = tab.panes.map do |pane|
          {
            "name" => pane.name, "command" => pane.command, "split_of" => pane.split_of,
            "direction" => pane.direction, "ratio" => pane.ratio
          }
        end
        { "name" => tab.name, "panes" => panes }
      end
    end

    def custom(workspace)
      text = workspace&.layout
      return if text.blank?

      parse(text)
    rescue Invalid => error
      Rails.logger.warn("[WorkspaceLayout] #{workspace.name}: invalid layout, using the default: #{error.message}")
      nil
    end

    # Returns an array of Tab, or raises Invalid with every problem found.
    def parse(text)
      data = load_yaml(text)
      errors = []
      tabs = build_tabs(data, errors)
      raise Invalid, errors.join("; ") if errors.any?

      tabs
    end

    def errors_for(text)
      parse(text)
      []
    rescue Invalid => error
      error.message.split("; ")
    end

    # The layout as the workspace form's editor works on it: plain hashes, the
    # agent as {"name" => "agent"}. Structure only, not validated -- a layout
    # the operator just submitted with a mistake in it comes back as they
    # left it, next to its errors, rather than reset to the default. Anything
    # that is not even tab-shaped starts over from the default.
    def editor_data(text)
      data = text.present? ? (load_yaml(text) rescue nil) : nil
      data = load_yaml(DEFAULT_YAML) unless data.is_a?(Hash) && data["tabs"].is_a?(Array)

      data["tabs"].filter_map do |tab|
        next unless tab.is_a?(Hash)

        panes = Array(tab["panes"]).filter_map do |pane|
          pane = { "name" => AGENT } if pane == AGENT
          pane.slice("name", "command", "split") if pane.is_a?(Hash)
        end
        { "name" => tab["name"], "panes" => panes }
      end
    end

    # Canonical YAML for a valid layout, which is what Workspace stores
    # whichever way it arrived (the form's editor submits JSON, which is also
    # YAML). The agent is written as a bare `agent`, and unset keys are left
    # out.
    def dump(tabs)
      data = tabs.map do |tab|
        panes = tab.panes.map do |pane|
          next AGENT if pane.agent?

          entry = { "name" => pane.name }
          entry["command"] = pane.command if pane.command
          if pane.split_of
            split = { "of" => pane.split_of, "direction" => pane.direction }
            split["ratio"] = pane.ratio if pane.ratio
            entry["split"] = split
          end
          entry
        end
        (tab.name ? { "name" => tab.name } : {}).merge("panes" => panes)
      end
      YAML.dump("tabs" => data).delete_prefix("---\n")
    end

    def load_yaml(text)
      YAML.safe_load(text.to_s)
    rescue Psych::Exception => error
      raise Invalid, "layout is not valid YAML: #{error.message}"
    end

    def build_tabs(data, errors)
      unless data.is_a?(Hash) && data["tabs"].is_a?(Array) && data["tabs"].any?
        errors << "layout must have a non-empty `tabs:` list"
        return []
      end
      unknown = data.keys - [ "tabs" ]
      errors << "unknown top-level key(s): #{unknown.join(', ')}" if unknown.any?

      names = []
      tabs = data["tabs"].each_with_index.map do |tab, index|
        build_tab(tab, index, names, errors)
      end.compact

      errors << "`agent` must be the first pane of the first tab" unless tabs.first&.panes&.first&.agent?
      agents = tabs.sum { |tab| tab.panes.count(&:agent?) }
      errors << "`agent` must appear exactly once (found #{agents})" if agents > 1
      errors << "at most #{MAX_PANES} panes in total" if names.size > MAX_PANES
      tabs
    end

    def build_tab(tab, index, names, errors)
      label = "tab #{index + 1}"
      unless tab.is_a?(Hash) && tab["panes"].is_a?(Array) && tab["panes"].any?
        errors << "#{label} must have a non-empty `panes:` list"
        return nil
      end
      unknown = tab.keys - TAB_KEYS
      errors << "#{label}: unknown key(s): #{unknown.join(', ')}" if unknown.any?
      name = tab["name"]
      errors << "#{label}: name must be a string" if !name.nil? && !name.is_a?(String)

      tab_panes = []
      tab["panes"].each_with_index do |pane, position|
        built = build_pane(pane, "#{label}, pane #{position + 1}", position.zero?, tab_panes, names, errors)
        tab_panes << built if built
      end
      Tab.new(name: name.presence, panes: tab_panes)
    end

    def build_pane(pane, label, root, tab_panes, names, errors)
      pane = { "name" => AGENT } if pane == AGENT
      unless pane.is_a?(Hash)
        errors << "#{label} must be `agent` or a mapping with a name"
        return nil
      end
      unknown = pane.keys - PANE_KEYS
      errors << "#{label}: unknown key(s): #{unknown.join(', ')}" if unknown.any?

      name = pane["name"]
      unless name.is_a?(String) && name.match?(NAME_PATTERN)
        errors << "#{label}: name must match #{NAME_PATTERN.source}"
        return nil
      end
      errors << "#{label}: duplicate pane name `#{name}`" if names.include?(name)
      names << name
      label = "pane `#{name}`"

      command = pane["command"]
      if name == AGENT
        errors << "#{label}: the agent pane takes no command" unless command.nil?
        command = nil
      elsif !command.nil? && !command.is_a?(String)
        errors << "#{label}: command must be a string"
        command = nil
      elsif command.to_s.bytesize > MAX_COMMAND_BYTES
        errors << "#{label}: command is longer than #{MAX_COMMAND_BYTES} bytes"
      end

      split = pane["split"]
      if root
        errors << "#{label}: the first pane of a tab is its root and takes no `split`" unless split.nil?
        return Pane.new(name:, command: command.presence, split_of: nil, direction: nil, ratio: nil)
      end

      of, direction, ratio = build_split(split, label, tab_panes, errors)
      Pane.new(name:, command: command.presence, split_of: of, direction:, ratio:)
    end

    def build_split(split, label, tab_panes, errors)
      unless split.is_a?(Hash)
        errors << "#{label}: every pane after a tab's first needs `split: { of: <pane> }`"
        return [ nil, nil, nil ]
      end
      unknown = split.keys - SPLIT_KEYS
      errors << "#{label}: unknown split key(s): #{unknown.join(', ')}" if unknown.any?

      of = split["of"]
      unless tab_panes.any? { |pane| pane.name == of }
        errors << "#{label}: `split.of` must name an earlier pane in the same tab (got #{of.inspect})"
      end

      direction = split.fetch("direction", "right")
      errors << "#{label}: direction must be one of #{DIRECTIONS.join(', ')}" unless DIRECTIONS.include?(direction)

      ratio = split["ratio"]
      if !ratio.nil? && !(ratio.is_a?(Numeric) && ratio >= 0.1 && ratio <= 0.9)
        errors << "#{label}: ratio must be a number between 0.1 and 0.9"
        ratio = nil
      end
      [ of, direction, ratio&.to_f ]
    end
  end
end
