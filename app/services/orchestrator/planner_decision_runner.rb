require "open3"
require "tempfile"

module Orchestrator
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
    CODEX_SMALL_MODEL = WorkerSpawner::CODEX_WORKER_MODEL

    STEP_SCHEMA = {
      type: "object",
      additionalProperties: false,
      properties: {
        owner: { type: "string", enum: StepPolicy::PLANNER_STEP_OWNERS },
        artifact: { type: "string" },
        successCheck: { type: "string" },
        mode: { type: "string", enum: StepPolicy::MODES },
        writeScope: { type: "string", enum: StepPolicy::WRITE_SCOPES },
        allowedPaths: { type: "array", items: { type: "string" } },
        evidenceRefs: { type: "array", items: { type: "string" } },
        operatorApprovalQuestionId: { type: [ "string", "null" ] },
        lineageKey: { type: [ "string", "null" ] }
      },
      required: %w[owner artifact successCheck mode writeScope allowedPaths evidenceRefs]
    }.freeze

    SCHEMA = {
      type: "object",
      additionalProperties: false,
      properties: {
        outcome: { type: "string", enum: %w[decision needs_context needs_stronger_model] },
        summary: { type: "string" },
        nextStep: STEP_SCHEMA.merge(type: [ "object", "null" ]),
        followingSteps: { type: "array", maxItems: 5, items: STEP_SCHEMA },
        contextRequest: {
          type: [ "object", "null" ],
          additionalProperties: false,
          properties: {
            source: { type: "string", enum: PlannerContextResolver::SOURCES },
            reference: { type: "string" },
            question: { type: "string" },
            offset: { type: [ "integer", "null" ], minimum: 0 },
            maxChars: { type: "integer", minimum: 1 }
          },
          required: %w[source reference question offset maxChars]
        }
      },
      required: %w[outcome summary nextStep followingSteps contextRequest]
    }.freeze

    def call(run:, request:, additional_context: [], model_tier: :small, command_runner: Open3.method(:capture3))
      raise ArgumentError, "Unknown planner model tier: #{model_tier}" unless MODEL_TIERS.include?(model_tier)

      prompt = PlannerBrief.build(run:, request:, additional_context:, model_tier:)
      raw = if run.launcher_variant == "claude"
        run_claude(run:, prompt:, model_tier:, command_runner:)
      else
        run_codex(run:, prompt:, model_tier:, command_runner:)
      end
      normalize(raw, model_tier:)
    end

    def run_claude(run:, prompt:, model_tier:, command_runner:)
      selected_model = CLAUDE_MODELS.fetch(model_tier)
      args = [
        "claude", "--model", selected_model, "--print", "--output-format", "json",
        "--json-schema", JSON.generate(SCHEMA), "--tools", "", "--disable-slash-commands",
        "--no-session-persistence", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
        "--system-prompt", "Return one structured workflow decision from the supplied evidence. Do not use tools.",
        "--max-budget-usd", "0.25", "--", prompt
      ]
      stdout, stderr, status = command_runner.call(WorkerSpawner.build_worker_env, *args, chdir: run.target_root)
      raise Error.new("Planner model failed with exit #{status.exitstatus}: #{stderr.presence || stdout}", output: "#{stdout}\n#{stderr}") unless status.success?

      envelope = JSON.parse(stdout)
      decision = envelope["structured_output"] || parse_json_string(envelope["result"])
      raise Error.new("Planner model returned no structured decision", output: stdout) unless decision.is_a?(Hash)

      { decision: decision, usage: usage_from_claude(envelope), model: envelope.dig("modelUsage")&.keys&.last || selected_model }
    rescue JSON::ParserError => e
      raise Error.new("Planner model returned invalid JSON: #{e.message}", output: stdout)
    end

    def run_codex(run:, prompt:, model_tier:, command_runner:)
      Tempfile.create([ "planner-schema", ".json" ]) do |schema_file|
        Tempfile.create([ "planner-decision", ".json" ]) do |output_file|
          schema_file.write(JSON.generate(SCHEMA))
          schema_file.flush
          model_args = model_tier == :small ? [ "--model", CODEX_SMALL_MODEL ] : []
          args = [
            "codex", "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only",
            *model_args, "--output-schema", schema_file.path,
            "--output-last-message", output_file.path, "--cd", run.target_root, prompt
          ]
          stdout, stderr, status = command_runner.call(WorkerSpawner.build_worker_env, *args, chdir: run.target_root)
          raise Error.new("Planner model failed with exit #{status.exitstatus}: #{stderr.presence || stdout}", output: "#{stdout}\n#{stderr}") unless status.success?

          { decision: JSON.parse(File.read(output_file.path)), usage: {}, model: model_tier == :small ? CODEX_SMALL_MODEL : "default" }
        end
      end
    rescue JSON::ParserError => e
      raise Error.new("Planner model returned invalid JSON: #{e.message}")
    end

    def normalize(result, model_tier:)
      decision = result.fetch(:decision)
      {
        outcome: decision.fetch("outcome", "decision"),
        summary: decision.fetch("summary"),
        next_step: WireFormat.underscore_keys(decision["nextStep"]),
        following_steps: WireFormat.underscore_keys(decision.fetch("followingSteps")),
        context_request: WireFormat.underscore_keys(decision["contextRequest"]),
        usage: result[:usage],
        model: result[:model],
        model_tier: model_tier.to_s
      }
    end

    def parse_json_string(value)
      value.is_a?(String) ? JSON.parse(value) : value
    rescue JSON::ParserError
      nil
    end
    private_class_method :parse_json_string

    def usage_from_claude(envelope)
      usage = envelope["usage"] || {}
      {
        input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"],
        cache_read_input_tokens: usage["cache_read_input_tokens"], total_cost_usd: envelope["total_cost_usd"]
      }.compact
    end
    private_class_method :usage_from_claude
  end
end
