require "json"
require "net/http"
require_relative "instance"
require_relative "mcp_client"

module PaneyardSandbox
  # `bin/sandbox verify`: a run's whole lifecycle against a running sandbox
  # instance, from outside it, the way the operator and a session reach the
  # real one -- /mcp/admin to queue and inspect, the fake agent reporting
  # through /mcp/run, /mcp/admin closing the session, and Solid Queue's real recurring
  # schedule to notice a crash. Each scenario is one fake-agent directive.
  class Verify
    class Failure < StandardError; end

    Scenario = Struct.new(:name, :directive, :run_id, keyword_init: true)

    ADMIN_TOOLS = %w[queue_run list_runs get_run list_workspaces close_session].freeze

    def initialize(instance, workspace:, workspace_id:, out: $stdout, timeout: 90)
      @instance = instance
      @workspace = workspace
      @workspace_id = workspace_id
      @out = out
      @timeout = timeout
      @admin = McpClient.new("#{instance.url}/mcp/admin")
      @failures = []
    end

    def call
      step("the health endpoint answers") { expect(get("/up").code == "200", "GET /up returned #{get('/up').code}") }
      step("/mcp/admin lists its tools") do
        missing = ADMIN_TOOLS - @admin.tool_names
        expect(missing.empty?, "missing #{missing.join(', ')}")
      end

      done = queue("done: report, close, worktree reclaimed", "done")
      dirty = queue("dirty: close keeps a worktree with uncommitted work", "dirty")
      crash = queue("crash: reconcile fails a run whose CLI died", "crash")

      step(done.name) { verify_done(done) }
      step(dirty.name) { verify_dirty(dirty) }
      step(crash.name) { verify_crash(crash) }

      @out.puts(@failures.empty? ? "sandbox verify: all green" : "sandbox verify: #{@failures.size} failed")
      @failures.empty?
    end

    private

    def queue(name, directive)
      result = @admin.call_tool(
        "queue_run", task: "Sandbox verify (#{name}) [fake-agent: #{directive}]", workspace: @workspace
      )
      Scenario.new(name:, directive:, run_id: result.fetch("runId"))
    end

    def verify_done(scenario)
      run = wait_for_run(scenario) { |detail| detail["checkpoints"]&.any? }
      expect(run["status"] == "awaiting_review", "status #{run['status']} after reporting")
      expect(run["checkpoints"].last["outcome"] == "done", "checkpoint #{run['checkpoints'].last}")
      expect(File.directory?(run["worktree"]), "worktree #{run['worktree']} missing while live")

      close(scenario)
      run = wait_for_run(scenario) { |detail| detail["status"] == "completed" }
      expect(run.dig("session", "live") == false, "session still live after Close session")
      expect(!File.directory?(run["worktree"]), "clean worktree #{run['worktree']} was not reclaimed")
    end

    def verify_dirty(scenario)
      run = wait_for_run(scenario) { |detail| detail["checkpoints"]&.any? }
      close(scenario)
      run = wait_for_run(scenario) { |detail| detail["status"] == "completed" }
      expect(File.exist?(File.join(run["worktree"], "FAKE_AGENT_CHANGES.md")), "dirty worktree #{run['worktree']} was removed")
    end

    # RunSessionReconcileJob runs every 30 seconds, so this waits on the real
    # recurring schedule rather than calling the job.
    def verify_crash(scenario)
      run = wait_for_run(scenario, timeout: @timeout + 45) { |detail| detail["status"] == "failed" }
      expect(run.dig("session", "outcome") == "failed", "session #{run['session']}")
      expect(run.dig("session", "live") == false, "crashed session still holds its slot")
    end

    def wait_for_run(scenario, timeout: @timeout)
      deadline = Time.now + timeout
      loop do
        detail = @admin.call_tool("get_run", runId: scenario.run_id, workspace: @workspace)
        return detail if yield(detail)
        raise Failure, "timed out after #{timeout}s; last state: #{JSON.generate(detail)[0, 800]}" if Time.now > deadline

        sleep 0.5
      end
    end

    def close(scenario)
      result = @admin.call_tool("close_session", runId: scenario.run_id, workspace: @workspace)
      @out.puts("    close_session: #{result.fetch('status')}; worktree #{result.fetch('worktree')}")
    end

    def get(path)
      request(Net::HTTP::Get.new(path))
    end

    def request(http_request)
      uri = URI(@instance.url)
      Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |http| http.request(http_request) }
    end

    def step(name)
      started = Time.now
      yield
      @out.puts("  ok   #{name} (#{(Time.now - started).round(1)}s)")
    rescue Failure, McpClient::Error, KeyError, SystemCallError => error
      @failures << name
      @out.puts("  FAIL #{name}: #{error.message}")
    end

    def expect(condition, message)
      raise Failure, message unless condition
    end
  end
end
