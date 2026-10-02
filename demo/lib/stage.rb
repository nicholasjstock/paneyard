require "fileutils"
require "json"
require "shellwords"
require "open3"
require "yaml"
require_relative "../../lib/paneyard_sandbox/instance"
require_relative "../../lib/paneyard_sandbox/mcp_client"

# Everything the demo container sets up around a take (see
# docs/demo-recording-plan.md): herdr, the X display and the terminal filmed on
# it, ffmpeg, a Paneyard instance, and the todo repo the story works on. Plain
# Ruby, run inside the paneyard-demo image by demo/bin/in-container.
module Stage
  DEMO_ROOT = "/work/demo".freeze
  APP_ROOT = File.expand_path("../..", __dir__)
  OUTPUT_DIR = ENV.fetch("DEMO_OUTPUT", File.join(APP_ROOT, "tmp", "demo-output"))
  HERDR_SOCKET = File.expand_path("~/.config/herdr/herdr.sock")
  # demo/bin/claude runs the rehearsal stand-in instead of the real CLI while
  # this file exists.
  REHEARSAL_FLAG = File.join(DEMO_ROOT, "rehearsal")
  X_DISPLAY = ":99".freeze
  # The recording's size and the terminal's font, in points. 1920x1080 at 15pt
  # stays legible scaled down to a README GIF; a talk recording can go bigger
  # (DEMO_CANVAS=2560x1440 DEMO_FONT_SIZE=20).
  CANVAS = ENV.fetch("DEMO_CANVAS", "1920x1080").split("x").map { Integer(_1) }.freeze
  FONT_SIZE = Float(ENV.fetch("DEMO_FONT_SIZE", "15"))
  FPS = 30
  # The todo repo: its checkout, which is what the workspace registers, and a
  # bare origin beside it. herdr puts the runs' worktrees under ~/.herdr.
  TODO_ROOT = File.join(DEMO_ROOT, "todo")
  TODO_MAIN = File.join(TODO_ROOT, "main")
  SCENARIO = File.join(APP_ROOT, "demo", "scenario", "todo")
  # Pinned, so the todo repo's first commit has the same SHA on every take.
  GIT_IDENTITY = {
    "GIT_AUTHOR_NAME" => "Paneyard Demo", "GIT_AUTHOR_EMAIL" => "demo@example.test",
    "GIT_COMMITTER_NAME" => "Paneyard Demo", "GIT_COMMITTER_EMAIL" => "demo@example.test",
    "GIT_AUTHOR_DATE" => "2026-09-01T09:00:00Z", "GIT_COMMITTER_DATE" => "2026-09-01T09:00:00Z"
  }.freeze
  # The operator's own layout: the agent, and Hunk following the worktree's diff.
  LAYOUT = <<~YAML.freeze
    tabs:
      - name: Agent
        panes:
          - agent
      - name: Hunk
        panes:
          - name: hunk
            command: hunk diff --watch
  YAML

  module_function

  def sh!(*command, env: {}, chdir: DEMO_ROOT)
    output, status = Open3.capture2e(env, *command, chdir:)
    raise "#{command.join(' ')} failed: #{output}" unless status.success?

    output
  end

  def herdr(*args)
    output, status = Open3.capture2e("herdr", *args)
    raise "herdr #{args.join(' ')} failed: #{output}" unless status.success?

    output
  end

  def herdr_json(*args)
    JSON.parse(herdr(*args)).fetch("result")
  end

  def wait_until(what, timeout:, interval: 0.5)
    deadline = Time.now + timeout
    until (value = yield)
      raise "timed out after #{timeout}s waiting for #{what}" if Time.now > deadline

      sleep interval
    end
    value
  end

  def prepare!(rehearsal:)
    FileUtils.mkdir_p([ DEMO_ROOT, OUTPUT_DIR ])
    rehearsal ? FileUtils.touch(REHEARSAL_FLAG) : FileUtils.rm_f(REHEARSAL_FLAG)
  end

  # --- herdr ------------------------------------------------------------------

  def start_herdr!(log_name)
    log = File.open(File.join(OUTPUT_DIR, log_name), "w")
    pid = Process.spawn("herdr", "server", out: log, err: log, in: File::NULL, pgroup: true)
    wait_until("herdr server", timeout: 20) { system("herdr", "status", "server", out: File::NULL, err: File::NULL) }
    pid
  end

  def stop_herdr(pid)
    system("herdr", "server", "stop", out: File::NULL, err: File::NULL)
    stop_group(pid)
  end

  def workspaces
    herdr_json("workspace", "list").fetch("workspaces")
  end

  def tabs(workspace_id)
    herdr_json("tab", "list", "--workspace", workspace_id).fetch("tabs")
  end

  def agent(pane_id)
    herdr_json("agent", "get", pane_id).fetch("agent")
  rescue RuntimeError
    nil
  end

  # --- the display, the terminal and the recording ------------------------------

  def start_display!
    FileUtils.rm_f("/tmp/.X#{X_DISPLAY.delete(':')}-lock")
    pid = Process.spawn("Xvfb", X_DISPLAY, "-screen", "0", "#{CANVAS.join('x')}x24", "-nolisten", "tcp",
                        out: File::NULL, err: File::NULL, pgroup: true)
    ENV["DISPLAY"] = X_DISPLAY
    wait_until("Xvfb", timeout: 10) { system("xdpyinfo", out: File::NULL, err: File::NULL) }
    pid
  end

  # The herdr client, full-screen in kitty (demo/Dockerfile says why kitty).
  # Sized once, before anything runs in herdr: resizing it later would reflow
  # every pane. There is no window manager, so size and position are kitty's
  # own initial window settings.
  def start_terminal!(font_size: FONT_SIZE)
    options = {
      "font_family" => "JetBrains Mono", "font_size" => font_size.to_s,
      "background" => "#1e1e2e", "foreground" => "#cdd6f4", "window_padding_width" => "10",
      "hide_window_decorations" => "yes", "remember_window_size" => "no",
      "initial_window_width" => CANVAS[0].to_s, "initial_window_height" => CANVAS[1].to_s,
      "cursor_blink_interval" => "0", "linux_display_server" => "x11", "update_check_interval" => "0"
    }
    pid = Process.spawn(
      { "LIBGL_ALWAYS_SOFTWARE" => "1" },
      "kitty", "--config", "NONE", *options.flat_map { |key, value| [ "-o", "#{key}=#{value}" ] }, "herdr",
      out: File.join(OUTPUT_DIR, "kitty.log"), err: [ :child, :out ], pgroup: true
    )
    wait_until("the kitty window", timeout: 20) { system("xdotool", "search", "--class", "kitty", out: File::NULL) }
    # Park the pointer out of the way; nothing in the story is clicked.
    system("xdotool", "mousemove", CANVAS[0].to_s, CANVAS[1].to_s)
    pid
  end

  # Lossless and full-chroma, so terminal text stays sharp through later crops
  # and scaling. -nostdin: ffmpeg otherwise reads (and eats) this process's
  # stdin. Stop it with stop_recording, which lets it finish the file.
  def start_recording!(path, seconds: nil)
    Process.spawn(
      "ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "0",
      "-video_size", CANVAS.join("x"), "-framerate", FPS.to_s, "-i", "#{X_DISPLAY}.0",
      *(seconds ? [ "-t", seconds.to_s ] : []),
      "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0", "-pix_fmt", "yuv444p", path,
      out: File::NULL, err: File.join(OUTPUT_DIR, "ffmpeg.log")
    )
  end

  def stop_recording(pid)
    Process.kill("INT", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # Types into whatever the herdr client has focused, a key at a time, the way
  # a person would.
  def type(text, delay_ms: 45)
    sh!("xdotool", "type", "--delay", delay_ms.to_s, "--", text)
  end

  def press(key)
    sh!("xdotool", "key", key)
  end

  def stop_group(pid)
    Process.kill("TERM", -pid) if pid
  rescue Errno::ESRCH
    nil
  end

  # --- Paneyard ------------------------------------------------------------------

  # This checkout's bin/production. Not a sandbox: the container is the
  # isolation (its own herdr, filesystem and database, no GitHub
  # credentials, and the source mounted read-only), and a sandbox would label
  # every run "[sandbox]" in herdr's sidebar.
  def start_app!(model:)
    instance = PaneyardSandbox::Instance.new(
      app_root: APP_ROOT, root: File.join(DEMO_ROOT, "app"), fake_herdr: false,
      env: {
        "PANEYARD_SANDBOX" => nil, "PANEYARD_SANDBOX_ROOT" => nil,
        "HERDR_SOCKET_PATH" => HERDR_SOCKET, "PANEYARD_CLAUDE_MODEL" => model
      }
    )
    instance.start!
    instance
  end

  def admin(instance)
    PaneyardSandbox::McpClient.new("#{instance.url}/mcp/admin")
  end

  # The todo repo, the same on every take: its main checkout with one pinned
  # commit, pushed to a bare origin (Paneyard requires an origin remote).
  def materialize_todo!
    FileUtils.rm_rf(TODO_ROOT)
    FileUtils.mkdir_p(TODO_MAIN)
    FileUtils.cp_r("#{SCENARIO}/.", TODO_MAIN)
    origin = File.join(TODO_ROOT, "origin.git")
    sh!("git", "init", "--quiet", "--bare", "-b", "main", origin)
    sh!("git", "init", "--quiet", "-b", "main", chdir: TODO_MAIN)
    sh!("git", "add", "-A", chdir: TODO_MAIN)
    sh!("git", "commit", "--quiet", "-m", "A tiny todo CLI", env: GIT_IDENTITY, chdir: TODO_MAIN)
    sh!("git", "remote", "add", "origin", origin, chdir: TODO_MAIN)
    sh!("git", "push", "--quiet", "-u", "origin", "main", chdir: TODO_MAIN)
    sh!("git", "rev-parse", "HEAD", chdir: TODO_MAIN).strip
  end

  # git identity for the agents' own commits, what the real claude would
  # otherwise stop at on its first start (onboarding, trusting the todo repo
  # -- a worktree counts as its repository -- and the bypass-permissions
  # warning Paneyard's --permission-mode brings up), and the pane env in the
  # shell's own startup files: Paneyard sets no env in a run's panes, which
  # are the user's login shell, as on any machine.
  def configure_user!
    sh!("git", "config", "--global", "user.name", "Paneyard Demo")
    sh!("git", "config", "--global", "user.email", "demo@example.test")
    exports = pane_env.map { |name, value| "export #{name}=#{Shellwords.escape(value)}\n" }.join
    File.write(File.expand_path("~/.paneyard-demo-env"), exports)
    %w[~/.bashrc ~/.bash_profile].each do |rc|
      path = File.expand_path(rc)
      line = "[ -f ~/.paneyard-demo-env ] && . ~/.paneyard-demo-env\n"
      File.write(path, line, mode: "a") unless File.exist?(path) && File.read(path).include?(line)
    end
    claude_json = File.expand_path("~/.claude.json")
    config = File.exist?(claude_json) ? JSON.parse(File.read(claude_json)) : {}
    config.merge!(
      "hasCompletedOnboarding" => true, "theme" => "dark", "bypassPermissionsModeAccepted" => true,
      "autoUpdates" => false
    )
    config["projects"] = (config["projects"] || {}).merge(
      TODO_MAIN => { "hasTrustDialogAccepted" => true, "hasCompletedProjectOnboarding" => true }
    )
    File.write(claude_json, JSON.pretty_generate(config))
  end

  # The env every pane in the story needs: herdr panes inherit nothing from
  # the image, so configure_user! puts it in the shell's startup files.
  def pane_env
    env = { "DISABLE_AUTOUPDATER" => "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1" }
    token = ENV["CLAUDE_CODE_OAUTH_TOKEN"].to_s.strip
    env["CLAUDE_CODE_OAUTH_TOKEN"] = token unless token.empty?
    env
  end

  # Registers the todo repo as a workspace, with the operator's layout.
  def register_todo!(instance)
    script = <<~RUBY
      workspace = Workspace.create!(name: "todo", repository_path: ENV.fetch("DEMO_TODO_REPOSITORY"),
        default_base_branch: "main", layout: ENV.fetch("DEMO_LAYOUT"))
      puts workspace.id
    RUBY
    output, ok = Open3.capture2e(
      instance.env.merge("DEMO_TODO_REPOSITORY" => TODO_MAIN, "DEMO_LAYOUT" => LAYOUT),
      "bin/rails", "runner", script, chdir: APP_ROOT
    )
    raise "registering the todo workspace failed:\n#{output}" unless ok.success?

    output.lines.last.strip
  end
end
