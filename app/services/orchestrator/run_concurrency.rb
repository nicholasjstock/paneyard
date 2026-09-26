module Orchestrator
  # How many runs may have a live session at once, across every workspace.
  #
  # The cap is global rather than per-workspace because the thing it protects
  # is global: one operator, one machine, one set of provider quotas, and one
  # pair of eyes to watch the panes. Two runs in different workspaces compete
  # for exactly the same resources as two runs in the same one.
  module RunConcurrency
    module_function

    DEFAULT_LIMIT = 2

    def limit
      raw = ENV["WORKFLOW_MAX_CONCURRENT_RUNS"]
      return DEFAULT_LIMIT if raw.blank?

      parsed = Integer(raw, exception: false)
      parsed && parsed.positive? ? parsed : DEFAULT_LIMIT
    end

    # Runs currently occupying a slot. Counted as a union of run ids rather
    # than by summing the two states, because a run that has been claimed
    # ("launching") may already have created its session before flipping to
    # "running" -- summing would count that run twice and under-fill the
    # machine.
    def occupied_run_ids
      Run.where(status: "launching").pluck(:id) | RunSession.live.pluck(:run_id)
    end

    def in_flight
      occupied_run_ids.size
    end

    def available_slots
      [ limit - in_flight, 0 ].max
    end
  end
end
