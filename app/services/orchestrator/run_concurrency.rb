module Orchestrator
  # How many runs may have a live session at once: across every workspace,
  # and on each runner.
  #
  # The global cap is global rather than per-workspace because the thing it
  # protects is global: one operator, one set of provider quotas, and one pair
  # of eyes to watch the panes. Two runs in different workspaces compete for
  # exactly the same resources as two runs in the same one.
  #
  # A runner may also cap its own machine (runners.max_concurrent_runs; nil
  # means only the global cap applies), since a laptop holds fewer sessions
  # than the always-on box. A run needs a free slot under both.
  module RunConcurrency
    module_function

    # Raised from 2 once a session started holding its slot until the operator
    # closes it: with a finished run occupying a slot while it waits to be
    # looked at, a low cap stalls the queue on review rather than on work.
    DEFAULT_LIMIT = 4

    def limit
      raw = ENV["PANEYARD_MAX_CONCURRENT_RUNS"]
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

    # { runner_id => runs occupying a slot on it }.
    def in_flight_by_runner
      Run.where(id: occupied_run_ids).group(:runner_id).count
    end

    def in_flight_on(runner)
      in_flight_by_runner.fetch(runner.id, 0)
    end

    # The slots a dispatch pass may fill: the global ones, each also needing
    # room on its run's runner. Taken one at a time as runs are claimed.
    def slots
      Slots.new(
        global: available_slots,
        caps: RegisteredRunner.where.not(max_concurrent_runs: nil).pluck(:id, :max_concurrent_runs).to_h,
        occupied: in_flight_by_runner
      )
    end

    class Slots
      def initialize(global:, caps:, occupied:)
        @global = global
        @caps = caps
        @occupied = occupied.dup
      end

      def any?
        @global.positive?
      end

      # Whether a run on this runner could take a slot now.
      def free_on?(runner_id)
        return false unless any?

        cap = @caps[runner_id]
        cap.nil? || @occupied.fetch(runner_id, 0) < cap
      end

      def take(runner_id)
        @global -= 1
        @occupied[runner_id] = @occupied.fetch(runner_id, 0) + 1
      end
    end
  end
end
