require "open3"
require "tempfile"

class ChaperoneReviewJob < ApplicationJob
  queue_as :default

  def perform(id, token)
    review = ChaperoneReview.find(id)
    return if review.status == "completed"

    review.update!(status: "running", model: "sonnet", started_at: Time.current, stdout: nil, stderr: nil, tool_calls: [])
    config = {
      mcpServers: {
        chaperone: {
          type: "http", url: "#{Orchestrator::WorkerSpawner.rails_mcp_url}/chaperone",
          headers: { Authorization: "Bearer #{token}" }
        }
      }
    }
    Tempfile.create([ "chaperone-mcp", ".json" ]) do |file|
      file.chmod(0o600)
      file.write(JSON.generate(config))
      file.flush
      prompt = if review.subject_type == "planner"
        "You must begin by calling get_chaperone_state. Review the bounded small-model planner attempt and its failure using only the chaperone MCP tools. " \
          "Choose continue_small when the failure can be corrected by a bounded retry with clearer context, including invalid verification evidence, an unverified service or endpoint, or an unnecessary protected-path proposal. " \
          "Choose promote only for a genuine reasoning-capability gap. Choose stop only when no safe in-scope retry exists and a real external decision is unavoidable; never stop merely because the planner proposed unauthorized work when an in-scope alternative remains. " \
          "Your summary must state the concrete next action. You must finish by calling submit_chaperone_decision exactly once; a text-only answer is a failure."
      else
        "You must begin by calling get_chaperone_state. Review repeated diagnosis attempts using only the chaperone MCP tools. Determine semantic similarity and progress. You must finish by calling submit_chaperone_decision exactly once with continue_small, promote, or stop; a text-only answer is a failure."
      end
      stdout, stderr, status = Open3.capture3(
        Orchestrator::WorkerSpawner.build_worker_env,
        "claude", "--model", "sonnet", "--print", "--mcp-config", file.path, "--strict-mcp-config",
        "--allowedTools", "mcp__chaperone__get_chaperone_state,mcp__chaperone__read_chaperone_artifact,mcp__chaperone__submit_chaperone_decision",
        "--no-session-persistence", "--", prompt, chdir: review.run.target_root
      )
      review.update!(stdout: bounded_output(stdout), stderr: bounded_output(stderr))
      raise "Chaperone exited #{status.exitstatus}: #{stderr}" unless status.success?
    end
    unless review.reload.status == "completed"
      detail = review.stdout.presence || review.stderr.presence
      raise "Chaperone exited without submitting a decision#{": #{detail.first(2_000)}" if detail}"
    end
  rescue => e
    review&.update!(status: "failed", summary: e.message, completed_at: Time.current)
    raise
  end

  private

  def bounded_output(output)
    output.to_s.last(50_000)
  end
end
