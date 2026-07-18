module Orchestrator
  module RunUsage
    module_function

    def build(run, now: Time.current)
      workers = run.workers
      decisions = run.planner_decisions
      started_at = run.started_at || run.created_at
      ended_at = run.stopped_at || now
      {
        worker_count: workers.count,
        reported_worker_count: workers.where.not(agent_turn_count: nil).count,
        planner_decision_count: decisions.count,
        agent_turn_count: workers.sum(:agent_turn_count) + decisions.sum(:model_calls),
        input_tokens: workers.sum(:input_tokens) + decisions.sum(:input_tokens),
        output_tokens: workers.sum(:output_tokens) + decisions.sum(:output_tokens),
        cache_read_input_tokens: workers.sum(:cache_read_input_tokens) + decisions.sum(:cache_read_input_tokens),
        total_cost_usd: (workers.sum(:total_cost_usd) + decisions.sum(:total_cost_usd)).to_f,
        models: workers.where.not(model: nil).group(:model).count.merge(decisions.where.not(model: nil).group(:model).count) do |_model, worker_count, decision_count|
          worker_count + decision_count
        end,
        started_at: started_at&.iso8601,
        elapsed_seconds: started_at ? [ ended_at - started_at, 0 ].max.round : nil
      }
    end
  end
end
