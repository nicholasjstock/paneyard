module Orchestrator
  module Runner
    # Builds a run's layout (Orchestrator::WorkspaceLayout.for, handed over as
    # plain data) in the herdr workspace herdr opened for the run's worktree,
    # and hands back the agent pane.
    #
    # This is pane setup at session start and nothing more. The runner creates each
    # pane, types its command into it, and forgets it: extra panes are never
    # recorded, watched, restarted or waited on. RunSession#herdr_pane_id stays
    # the agent's, so prompt!/refresh!/RunSessionReconcileJob only ever look at
    # the agent -- a crashed log tail cannot look like a dead session, and a live
    # dev server cannot mask a dead agent. Closing the workspace (Close session,
    # or RunSessionRunner losing the agent pane) takes every tab down with it.
    #
    # No pane gets an environment of its own: each is the operator's login
    # shell in the worktree, as any herdr pane is.
    #
    # The agent pane is the first tab's root, which is the worktree
    # workspace's own root pane. Everything else is best effort: a pane that
    # cannot be created is skipped along with the panes split from it, and the
    # run launches without them.
    module SessionLayout
      module_function

      Tab = Data.define(:name, :panes)
      Pane = Data.define(:name, :command, :split_of, :direction, :ratio)

      # `root_pane` is the worktree workspace's root pane ({"workspace_id",
      # "tab_id", "pane_id"}); it is returned, as the agent's.
      def open!(root_pane:, cwd:, tabs:)
        first_tab, *other_tabs = load(tabs)
        workspace_id = root_pane.fetch("workspace_id")

        rename_tab(root_pane.fetch("tab_id"), first_tab.name) if first_tab.name
        fill_tab(first_tab, root_pane_id: root_pane.fetch("pane_id"), cwd:)
        other_tabs.each { |tab| open_tab(tab, workspace_id:, cwd:) }
        root_pane
      end

      def load(tabs)
        tabs.map do |tab|
          panes = tab.fetch("panes").map do |pane|
            Pane.new(name: pane.fetch("name"), command: pane["command"], split_of: pane["split_of"],
                     direction: pane["direction"], ratio: pane["ratio"])
          end
          Tab.new(name: tab["name"], panes:)
        end
      end

      def open_tab(tab, workspace_id:, cwd:)
        created = Herdr.tab_create(workspace_id:, label: tab.name, cwd:, focus: false)
        root_pane_id = created.fetch("root_pane").fetch("pane_id")
        start_pane(root_pane_id, tab.panes.first)
        fill_tab(tab, root_pane_id:, cwd:)
      rescue Herdr::Error, KeyError => error
        warn("could not open tab #{tab.name || tab.panes.first.name}: #{error.message}")
      end

      # Splits every pane after the tab's root off the pane it names, in list
      # order. A pane whose `of` was never created is skipped.
      def fill_tab(tab, root_pane_id:, cwd:)
        pane_ids = { tab.panes.first.name => root_pane_id }
        tab.panes.drop(1).each do |pane|
          target = pane_ids[pane.split_of]
          next warn("skipping pane #{pane.name}: #{pane.split_of} was not created") unless target

          pane_id = split(pane, target:, cwd:)
          pane_ids[pane.name] = pane_id if pane_id
        end
      end

      def split(pane, target:, cwd:)
        created = Herdr.pane_split(target_pane_id: target, direction: pane.direction, ratio: pane.ratio, cwd:, focus: false)
        pane_id = created.fetch("pane_id")
        start_pane(pane_id, pane)
        pane_id
      rescue Herdr::Error, KeyError => error
        warn("could not open pane #{pane.name}: #{error.message}")
        nil
      end

      # Labels the pane and types its command. Neither is worth losing the pane
      # over, so a failure here keeps it, as a plain shell.
      def start_pane(pane_id, pane)
        begin
          Herdr.pane_rename(pane_id, pane.name)
        rescue Herdr::Error => error
          warn("could not label pane #{pane.name}: #{error.message}")
        end
        Herdr.pane_send_input(pane_id, text: pane.command, keys: [ "Enter" ]) if pane.command
      rescue Herdr::Error => error
        warn("could not start #{pane.name}: #{error.message}")
      end

      def rename_tab(tab_id, name)
        Herdr.tab_rename(tab_id, name)
      rescue Herdr::Error => error
        warn("could not label tab #{name}: #{error.message}")
      end

      def warn(message)
        Rails.logger.warn("[SessionLayout] #{message}")
        nil
      end
    end
  end
end
