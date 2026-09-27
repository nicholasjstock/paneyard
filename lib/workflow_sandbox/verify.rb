require "cgi"
require "json"
require "net/http"
require_relative "instance"
require_relative "mcp_client"

module WorkflowSandbox
  # `bin/sandbox verify`: a run's whole lifecycle against a running sandbox
  # instance, from outside it, the way the operator and a session reach the
  # real one -- /mcp/admin to queue and inspect, the fake agent reporting
  # through /mcp/run, the run screen's own forms (CSRF token and all) to send
  # a message and close the session, and Solid Queue's real recurring
  # schedule to notice a crash. Each scenario is one fake-agent directive.
  class Verify
    class Failure < StandardError; end

    Scenario = Struct.new(:name, :directive, :run_id, keyword_init: true)

    ADMIN_TOOLS = %w[queue_run list_runs get_run list_workspaces].freeze

    def initialize(instance, workspace:, workspace_id:, out: $stdout, timeout: 90)
      @instance = instance
      @workspace = workspace
      @workspace_id = workspace_id
      @out = out
      @timeout = timeout
      @admin = McpClient.new("#{instance.url}/mcp/admin")
      @cookies = {}
      @failures = []
    end

    def call
      step("the home page renders") { expect(get("/").code == "200", "GET / returned #{get('/').code}") }
      step("/mcp/admin lists its tools") do
        missing = ADMIN_TOOLS - @admin.tool_names
        expect(missing.empty?, "missing #{missing.join(', ')}")
      end

      done = queue("done: report, take a message, close, worktree reclaimed", "done")
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

      # The message box reaches the live session (agent.prompt); the agent
      # takes it as more work and reports again, as a second checkpoint.
      submit_form(scenario, "send_message", "message" => "One more thing. [fake-agent: done]")
      run = wait_for_run(scenario) { |detail| detail["checkpoints"].size >= 2 }
      expect(run["checkpoints"].last["outcome"] == "done", "second checkpoint #{run['checkpoints'].last}")

      submit_form(scenario, "close_session")
      run = wait_for_run(scenario) { |detail| detail["status"] == "completed" }
      expect(run.dig("session", "live") == false, "session still live after Close session")
      expect(!File.directory?(run["worktree"]), "clean worktree #{run['worktree']} was not reclaimed")
    end

    def verify_dirty(scenario)
      run = wait_for_run(scenario) { |detail| detail["checkpoints"]&.any? }
      submit_form(scenario, "close_session")
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

    # Posts one of the run screen's own button_to/form_with forms, with the
    # per-form CSRF token Rails rendered into it.
    def submit_form(scenario, action, fields = {})
      page = get(run_path(scenario))
      path = "#{run_path(scenario)}/#{action}"
      form = page.body[%r{<form[^>]*action="#{Regexp.escape(path)}".*?</form>}m]
      raise Failure, "no #{action} form on #{run_path(scenario)}" unless form

      token = form[/name="authenticity_token" value="([^"]+)"/, 1]
      response = post(path, fields.merge("authenticity_token" => CGI.unescapeHTML(token.to_s)))
      raise Failure, "POST #{path} returned #{response.code}" unless response.code.start_with?("2", "3")

      flash = get(run_path(scenario)).body[/class="flash[^"]*"[^>]*>(.*?)</m, 1]
      @out.puts("    #{action}: #{flash.to_s.strip}") if flash
    end

    def run_path(scenario)
      "/workspaces/#{@workspace_id}/runs/#{scenario.run_id}"
    end

    def get(path)
      request(Net::HTTP::Get.new(path))
    end

    def post(path, fields)
      http_request = Net::HTTP::Post.new(path)
      http_request.set_form_data(fields)
      request(http_request)
    end

    def request(http_request)
      http_request["Cookie"] = @cookies.map { |key, value| "#{key}=#{value}" }.join("; ") if @cookies.any?
      http_request["Accept"] = "text/html"
      uri = URI(@instance.url)
      response = Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |http| http.request(http_request) }
      Array(response.get_fields("set-cookie")).each do |cookie|
        key, value = cookie.split(";").first.split("=", 2)
        @cookies[key] = value
      end
      response
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
