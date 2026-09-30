require "json"
require_relative "stage"

# The demo's story, beat by beat (docs/demo-recording-plan.md §5): the operator
# asks their own Claude Code to queue two jobs over /mcp/admin, two herdr
# workspaces appear and work, we look at their Hunk diffs, tell each to merge
# to main, close both in herdr, and ask how they went.
#
# The director only does what the operator would -- types into the focused
# pane, switches herdr's view, closes workspaces -- and otherwise waits on real
# state (herdr agent status, the runs over /mcp/admin, git), never on fixed
# times beyond short holds for the viewer. Each beat's start and end go into
# timings.json for demo/lib/cut.rb to speed up and cut.
class Director
  WORKSPACE = "todo".freeze
  ASK = "Queue two paneyard jobs on the todo workspace: one that adds optional due dates to todos " \
        "and shows them in todo list, and one that adds a todo clear command that removes finished todos.".freeze
  MERGE = "Looks good - go ahead and merge to main.".freeze
  CHECK = "How did those two jobs go?".freeze
  # Live agents take their time; a stand-in takes seconds.
  WORK_TIMEOUT = 15 * 60

  Job = Struct.new(:run_id, :worktree_name, :branch, :pane, :workspace_id, :agent_tab, :hunk_tab, keyword_init: true)

  attr_reader :timings, :failures

  def initialize(instance:, model:, video:, timings_path:)
    @instance = instance
    @admin = Stage.admin(instance)
    @model = model
    @video = video
    @timings_path = timings_path
    @timings = {}
    @failures = []
  end

  def call
    @base = Stage.sh!("git", "rev-parse", "main", chdir: Stage::TODO_MAIN).strip
    open_operator!
    @recorder = Stage.start_recording!(@video)
    @started = now

    beat(:idle) { sleep 2 }
    beat(:ask) do
      ask(ASK)
      Stage.wait_until("two runs queued", timeout: 300) { runs.size >= 2 }
    end
    beat(:spawn) do
      @jobs = Stage.wait_until("both runs' herdr workspaces", timeout: 180) { jobs_in_herdr }
      focus(@jobs.first.workspace_id)
      Stage.wait_until("the first agent working", timeout: 120) { agent_status(@jobs.first) == "working" }
    end
    beat(:work) do
      Stage.wait_until("a few seconds of work", timeout: 20) { checkpoints(@jobs.first).any? || elapsed_in_beat > 6 }
    end
    beat(:hunk) do
      @jobs.each do |job|
        focus(job.workspace_id, tab: job.hunk_tab)
        sleep 5
      end
      @jobs.each { |job| Stage.wait_until("#{job.run_id} to report", timeout: WORK_TIMEOUT) { checkpoints(job).any? } }
      focus(@jobs.first.workspace_id, tab: @jobs.first.hunk_tab)
      sleep 3
    end
    beat(:merge) do
      @jobs.each do |job|
        focus(job.workspace_id, tab: job.agent_tab)
        reported = checkpoints(job).size
        ask(MERGE)
        Stage.wait_until("#{job.run_id} merged into main", timeout: WORK_TIMEOUT) { merged?(job) && checkpoints(job).size > reported }
        sleep 2
      end
    end
    beat(:close) do
      @jobs.each do |job|
        Stage.herdr("workspace", "close", job.workspace_id)
        sleep 1.5
      end
      focus(@operator_workspace)
      @jobs.each { |job| Stage.wait_until("#{job.run_id} completed", timeout: 120) { run(job)["status"] == "completed" } }
    end
    beat(:confirm) do
      ask(CHECK)
      Stage.wait_until("the operator's Claude to start answering", timeout: 60) { operator_status != "idle" }
      Stage.wait_until("the operator's Claude to answer", timeout: 300) { %w[idle done].include?(operator_status) }
      sleep 4
    end
    beat(:end) { sleep 3 }
    check!
    self
  ensure
    Stage.stop_recording(@recorder) if @recorder
    File.write(@timings_path, JSON.pretty_generate(@timings))
  end

  private

  # The operator's own Claude Code, in the todo repo's main checkout, with
  # Paneyard's /mcp/admin as an MCP server and its tools pre-approved.
  def open_operator!
    mcp_config = File.join(Stage::DEMO_ROOT, "operator-mcp.json")
    File.write(mcp_config, JSON.generate(
      "mcpServers" => { "paneyard" => { "type" => "http", "url" => "#{@instance.url}/mcp/admin" } }
    ))
    env_args = Stage.pane_env.flat_map { |name, value| [ "--env", "#{name}=#{value}" ] }
    created = Stage.herdr_json("workspace", "create", "--cwd", Stage::TODO_MAIN, "--label", "todo", *env_args, "--no-focus")
    @operator_workspace = created.dig("workspace", "workspace_id")
    @operator_pane = created.dig("root_pane", "pane_id")
    Stage.herdr("tab", "rename", created.dig("tab", "tab_id"), "Claude")
    Stage.wait_until("the operator pane's shell", timeout: 20) { shell_ready?(@operator_pane) }
    Stage.herdr("agent", "start", "operator", "--kind", "claude", "--pane", @operator_pane, "--",
                "--model", @model, "--mcp-config", mcp_config, "--allowedTools", "mcp__paneyard")
    Stage.wait_until("the operator's Claude to be ready", timeout: 90) { Stage.agent(@operator_pane)&.dig("interactive_ready") }
    focus(@operator_workspace)
    # The client opens a workspace of its own ("~") when it first attaches;
    # the story starts with only the operator's.
    Stage.workspaces.each do |workspace|
      Stage.herdr("workspace", "close", workspace["workspace_id"]) unless workspace["workspace_id"] == @operator_workspace
    end
    sleep 1
  end

  def shell_ready?(pane)
    info = Stage.herdr_json("pane", "process-info", "--pane", pane)
    info = info["process_info"] || info
    info["foreground_process_group_id"] == info["shell_pid"]
  rescue RuntimeError
    false
  end

  def ask(text)
    Stage.type(text)
    sleep 0.4
    Stage.press("Return")
  end

  def focus(workspace_id, tab: nil)
    Stage.herdr("workspace", "focus", workspace_id)
    Stage.herdr("tab", "focus", tab) if tab
  end

  def runs
    list = @admin.call_tool("list_runs", workspace: WORKSPACE)
    list = list["runs"] if list.is_a?(Hash)
    Array(list).sort_by { _1["runId"] }
  end

  def run(job)
    @admin.call_tool("get_run", runId: job.run_id, workspace: WORKSPACE)
  end

  def checkpoints(job)
    Array(run(job)["checkpoints"])
  end

  def agent_status(job)
    Stage.agent(job.pane)&.dig("agent_status")
  end

  def operator_status
    Stage.agent(@operator_pane)&.dig("agent_status")
  end

  # Both runs, once herdr has a workspace for each with its Agent and Hunk tabs.
  def jobs_in_herdr
    details = runs.first(2).map { |summary| @admin.call_tool("get_run", runId: summary["runId"], workspace: WORKSPACE) }
    jobs = details.map do |detail|
      workspace = Stage.workspaces.find { |candidate| candidate["label"].to_s.include?(detail["worktreeName"].to_s) }
      pane = detail.dig("session", "pane")
      next unless workspace && pane

      tabs = Stage.tabs(workspace["workspace_id"])
      hunk = tabs.find { _1["label"] == "Hunk" }
      next unless hunk

      Job.new(run_id: detail["runId"], worktree_name: detail["worktreeName"], branch: detail["branch"], pane:,
              workspace_id: workspace["workspace_id"], agent_tab: tabs.first["tab_id"], hunk_tab: hunk["tab_id"])
    end
    jobs.size == 2 && jobs.all? ? jobs : nil
  end

# The job's branch has commits of its own and all of them are on main.
def merged?(job)
  ahead = Stage.sh!("git", "rev-list", "--count", "#{@base}..#{job.branch}", chdir: Stage::TODO_MAIN).to_i
  ahead.positive? && system("git", "-C", Stage::TODO_MAIN, "merge-base", "--is-ancestor", job.branch, "main")
rescue RuntimeError
  false
end

  # What makes a take usable: both jobs' work is on main, main's tests pass,
  # and both runs ended with their worktrees cleaned up.
  def check!
    @jobs.each do |job|
      detail = run(job)
      @failures << "#{job.run_id} is #{detail['status']}, not completed" unless detail["status"] == "completed"
      @failures << "#{job.run_id}'s worktree #{detail['worktree']} is still there" if File.directory?(detail["worktree"].to_s)
      @failures << "#{job.branch} is not merged into main" unless merged?(job)
    end
    _output, status = Open3.capture2e("ruby", "bin/test", chdir: Stage::TODO_MAIN)
    @failures << "bin/test fails on main" unless status.success?
  end

  def beat(name)
    @beat_started = now
    yield
  rescue StandardError => error
    @failures << "#{name}: #{error.message}"
    raise
  ensure
    @timings[name] = { "start" => (@beat_started - @started).round(2), "end" => (now - @started).round(2) } if @started
  end

  def elapsed_in_beat
    now - @beat_started
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
