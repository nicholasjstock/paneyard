require "open3"
require "tempfile"

module Orchestrator
  # Runs the bounded planner CLI invocation for one PlannerDecision. Unlike
  # the pre-refactor version, this does not parse a final structured JSON
  # blob from stdout -- the model's only way to submit its decision is by
  # calling submit_planner_decision (see McpTools::SubmitPlannerDecisionTool
  # / Orchestrator::PlannerDecisionSubmission), which persists directly from
  # inside that live tool call. By the time this call returns, the decision
  # record already reflects whatever happened; the caller (PlannerDecisionJob)
  # just checks its resulting status. What this still returns is aggregate
  # usage/cost/model metadata from the process's own final envelope, applied
  # once to the decision record -- that's a property of the whole invocation,
  # not of any individual tool call within it.
  module PlannerDecisionRunner
    class Error < StandardError
      attr_reader :output

      def initialize(message, output: nil)
        @output = output
        super(message)
      end
    end

    module_function

    MODEL_TIERS = %i[small strong].freeze
    CLAUDE_MODELS = { small: "haiku", strong: "sonnet" }.freeze
    CODEX_SMALL_MODEL = WorkerSpawner::CODEX_SMALL_MODEL
    CODEX_PROMOTED_MODEL = WorkerSpawner::CODEX_PROMOTED_MODEL
    OPENCODE_SMALL_MODEL = WorkerSpawner::OPENCODE_SMALL_MODEL
    OPENCODE_PROMOTED_MODEL = WorkerSpawner::OPENCODE_PROMOTED_MODEL
    OUTPUT_LIMIT = 50_000

    # High by default -- the planner's own decision quality gates everything
    # downstream (which worker gets dispatched, whether a stall recovers),
    # so it gets the same "spend more to think it through" treatment as the
    # chaperone rather than defaulting to whatever each CLI's own baseline
    # effort happens to be. Still a real, independent knob from model_tier
    # (see WorkerSpawner#claude_args/codex_args): a caller can override it.
    DEFAULT_EFFORT = "high".freeze

    def call(run:, request:, decision:, model_tier: :small, effort: DEFAULT_EFFORT, command_runner: Open3.method(:capture3))
      raise ArgumentError, "Unknown planner model tier: #{model_tier}" unless MODEL_TIERS.include?(model_tier)

      prompt = PlannerBrief.build(run:, request:, model_tier:)
      case run.launcher_variant
      when "claude"
        run_claude(run:, decision:, prompt:, model_tier:, effort:, command_runner:)
      when "codex"
        run_codex(run:, decision:, prompt:, model_tier:, effort:, command_runner:)
      else
        run_opencode(run:, decision:, prompt:, model_tier:, effort:, command_runner:)
      end
    end

    def run_claude(run:, decision:, prompt:, model_tier:, effort:, command_runner:)
      selected_model = CLAUDE_MODELS.fetch(model_tier)
      token = PlannerDecisionCapability.issue(decision)
      Tempfile.create([ "planner-decision-mcp", ".json" ]) do |mcp_file|
        mcp_file.chmod(0o600)
        mcp_file.write(JSON.generate({
          mcpServers: { planner_decision: {
            type: "http", url: "#{WorkerSpawner.rails_mcp_url}/planner-decision",
            headers: { Authorization: "Bearer #{token}" }
          } }
        }))
        mcp_file.flush
        args = [
          "claude", "--model", selected_model,
          *(effort ? [ "--effort", effort ] : []),
          "--print", "--output-format", "json",
          "--mcp-config", mcp_file.path, "--strict-mcp-config",
          "--allowedTools", "mcp__planner_decision__submit_planner_decision",
          "--disable-slash-commands", "--no-session-persistence", "--max-budget-usd", "0.25", "--", prompt
        ]
        stdout, stderr, status = command_runner.call(WorkerSpawner.build_worker_env, *args, chdir: run.target_root)
        raise Error.new("Planner model failed with exit #{status.exitstatus}: #{stderr.presence || stdout}", output: bounded_output("#{stdout}\n#{stderr}")) unless status.success?

        envelope = JSON.parse(stdout)
        {
          usage: usage_from_claude(envelope), model: envelope.dig("modelUsage")&.keys&.last || selected_model,
          cli_output: bounded_output(stdout)
        }
      end
    rescue JSON::ParserError => e
      raise Error.new("Planner model returned invalid JSON: #{e.message}", output: bounded_output(stdout))
    end

    def run_codex(run:, decision:, prompt:, model_tier:, effort:, command_runner:)
      token = PlannerDecisionCapability.issue(decision)
      env = WorkerSpawner.build_worker_env.merge("PLANNER_DECISION_TOKEN" => token)
      Tempfile.create([ "planner-decision", ".txt" ]) do |output_file|
        selected_model = model_tier == :strong ? CODEX_PROMOTED_MODEL : CODEX_SMALL_MODEL
        args = [
          "codex", "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only",
          "--skip-git-repo-check",
          "--model", selected_model,
          *(effort ? [ "-c", %(model_reasoning_effort="#{effort}") ] : []),
          "-c", %(mcp_servers.planner_decision.url=#{"#{WorkerSpawner.rails_mcp_url}/planner-decision".to_json}),
          "-c", 'mcp_servers.planner_decision.bearer_token_env_var="PLANNER_DECISION_TOKEN"',
          "-c", 'mcp_servers.planner_decision.default_tools_approval_mode="approve"',
          "--output-last-message", output_file.path, "--cd", run.target_root, "-"
        ]
        # Prompt goes over stdin, not argv -- matches
        # WorkerSpawner's own codex path, and keeps this bounded-decision
        # prompt out of `ps` output the same way. Nothing forced this to
        # differ; it only ever did because this call site and the worker
        # path were ported from the original TS scripts independently.
        stdout, stderr, status = command_runner.call(env, *args, chdir: run.target_root, stdin_data: prompt)
        raise Error.new("Planner model failed with exit #{status.exitstatus}: #{stderr.presence || stdout}", output: bounded_output("#{stdout}\n#{stderr}")) unless status.success?

        { usage: {}, model: selected_model, cli_output: bounded_output(stdout) }
      end
    end

    def run_opencode(run:, decision:, prompt:, model_tier:, effort:, command_runner:)
      token = PlannerDecisionCapability.issue(decision)
      selected_model = model_tier == :strong ? OPENCODE_PROMOTED_MODEL : OPENCODE_SMALL_MODEL
      mcp_config_content = JSON.generate({
        mcpServers: { planner_decision: {
          type: "http", url: "#{WorkerSpawner.rails_mcp_url}/planner-decision",
          headers: { Authorization: "Bearer #{token}" }
        } }
      })
      env = WorkerSpawner.build_worker_env.merge("OPENCODE_CONFIG_CONTENT" => mcp_config_content)
      args = [
        "opencode", "run", "--format", "json", "--auto",
        "-m", selected_model,
        *(effort ? [ "--variant", effort ] : []),
        "--dir", run.target_root, "--agent", "build", prompt
      ]
      stdout, stderr, status = command_runner.call(env, *args, chdir: run.target_root)
      raise Error.new("Planner model failed with exit #{status.exitstatus}: #{stderr.presence || stdout}", output: bounded_output("#{stdout}\n#{stderr}")) unless status.success?

      { usage: {}, model: selected_model, cli_output: bounded_output(stdout) }
    rescue JSON::ParserError => e
      raise Error.new("Planner model returned invalid JSON: #{e.message}", output: bounded_output(stdout))
    end

    def usage_from_claude(envelope)
      usage = envelope["usage"] || {}
      {
        input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"],
        cache_read_input_tokens: usage["cache_read_input_tokens"], total_cost_usd: envelope["total_cost_usd"]
      }.compact
    end
    private_class_method :usage_from_claude

    def bounded_output(output)
      output.to_s.last(OUTPUT_LIMIT)
    end
    private_class_method :bounded_output
  end
end
