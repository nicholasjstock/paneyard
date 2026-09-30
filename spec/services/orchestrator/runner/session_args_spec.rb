require "rails_helper"

RSpec.describe Orchestrator::Runner::SessionArgs do
  let(:mcp_url) { "http://127.0.0.1:3001/mcp" }

  describe ".build" do
    it "rejects an unknown driver" do
      expect do
        described_class.build(driver: "cursor", root_dir: "/tmp", mcp_config_path: "/tmp/x.json", capability_token: "t", mcp_url:, model: "a-model")
      end.to raise_error(ArgumentError, /unsupported driver/)
    end
  end

  describe "per-run model" do
    it "uses the model the operator picked over the driver default, for every driver" do
      { "claude" => "--model", "codex" => "--model", "opencode" => "-m" }.each do |driver, flag|
        _command, args, _env = described_class.build(
          driver:, root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json", capability_token: "tok", mcp_url:,
          model: "picked-model"
        )

        expect(args.each_cons(2)).to include([ flag, "picked-model" ]), "#{driver} args: #{args.inspect}"
      end
    end

    it "leaves the model flag out when there is no model, so the CLI uses its own configured one" do
      %w[claude codex opencode].each do |driver|
        [ nil, "codex-7" ].each do |resume_session_id|
          _command, args, _env = described_class.build(
            driver:, root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json", capability_token: "tok", mcp_url:,
            model: nil, resume_session_id:
          )

          expect(args).not_to include("--model", "-m"), "#{driver} args: #{args.inspect}"
          expect(args).not_to include(nil)
        end
      end
    end

    it "keeps the picked model when codex resumes a session" do
      _command, args, _env = described_class.build(
        driver: "codex", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json",
        capability_token: "tok", mcp_url:, resume_session_id: "codex-7", model: "gpt-5.5"
      )

      expect(args.each_cons(2)).to include([ "--model", "gpt-5.5" ])
    end
  end

  describe "claude" do
    it "builds an interactive command line with no headless or planner-era flags" do
      command, args, env = described_class.build(
        driver: "claude", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json", capability_token: "tok", mcp_url:, model: "a-model"
      )

      expect(command).to eq("claude")
      # The operator's own per-repo auto-memory is not a run's business.
      expect(env).to eq("CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1")
      expect(args).to include("--permission-mode", "bypassPermissions")
      expect(args).to include("--add-dir", "/repos/app-1")
      expect(args).to include("--mcp-config", "/tmp/mcp.json")
      expect(args).to include("--strict-mcp-config")
      # The prompt is submitted via agent.prompt, never as argv, and there is
      # no stream-json log for an interactive session to produce.
      expect(args).not_to include("-p", "--print", "--output-format", "--verbose")
      # The planner's per-step sandbox is gone: a session owns its worktree.
      expect(args).not_to include("--tools", "--settings", "--setting-sources")
    end

    it "resumes an existing CLI session when one is known" do
      _command, args, _env = described_class.build(
        driver: "claude", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json",
        capability_token: "tok", mcp_url:, model: "a-model", resume_session_id: "sess-42"
      )

      expect(args).to include("--resume", "sess-42")
    end

    it "writes a 0600 MCP config pointing at the run endpoint" do
      path = Rails.root.join("tmp", "session-args-spec-#{SecureRandom.hex(4)}.json").to_s
      described_class.write_claude_mcp_config(path, "tok", mcp_url:)

      config = JSON.parse(File.read(path))
      expect(config.dig("mcpServers", "paneyard", "url")).to eq("http://127.0.0.1:3001/mcp/run")
      expect(config.dig("mcpServers", "paneyard", "headers", "Authorization")).to eq("Bearer tok")
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    ensure
      File.delete(path) if path && File.exist?(path)
    end
  end

  describe "codex" do
    it "uses the bare interactive command with -s danger-full-access, never the broken bypass flag" do
      command, args, _env = described_class.build(
        driver: "codex", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json", capability_token: "tok", mcp_url:, model: "a-model"
      )

      expect(command).to eq("codex")
      expect(args.first).not_to eq("exec")
      expect(args).to include("-s", "danger-full-access")
      # Confirmed live to break bare/interactive codex 0.147.0 outright.
      expect(args).not_to include("--dangerously-bypass-approvals-and-sandbox")
      expect(args).not_to include("-a")
      expect(args).to include("-C", "/repos/app-1")
      expect(args).to include(%(mcp_servers.paneyard.bearer_token_env_var="PANEYARD_RUN_TOKEN"))
      expect(args).to include(%(mcp_servers.paneyard.url="http://127.0.0.1:3001/mcp/run"))
    end

    it "drops -C when resuming, which codex rejects on a resumed session" do
      _command, args, _env = described_class.build(
        driver: "codex", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json",
        capability_token: "tok", mcp_url:, model: "a-model", resume_session_id: "codex-7"
      )

      expect(args.first(2)).to eq([ "resume", "codex-7" ])
      expect(args).not_to include("-C")
    end

    # With an update pending, codex otherwise opens on an update picker whose
    # default is "Update now", which the submitted prompt's Enter selects.
    it "turns off codex's startup update check, fresh and resumed" do
      [ nil, "codex-7" ].each do |resume_session_id|
        _command, args, _env = described_class.build(
          driver: "codex", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json",
          capability_token: "tok", mcp_url:, model: "a-model", resume_session_id:
        )

        expect(args.each_cons(2)).to include([ "-c", "check_for_update_on_startup=false" ]), "resume=#{resume_session_id.inspect}: #{args.inspect}"
      end
    end
  end

  describe "opencode" do
    it "passes cwd positionally and always includes --auto and --mini" do
      command, args, env = described_class.build(
        driver: "opencode", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json", capability_token: "tok", mcp_url:, model: "a-model"
      )

      expect(command).to eq("opencode")
      expect(args).to include("--auto")
      # Without --mini, agent.prompt text never reaches opencode's input at all.
      expect(args).to include("--mini")
      expect(args.last).to eq("/repos/app-1")
      # run-subcommand-only flags that do not exist on the bare command.
      expect(args).not_to include("--dir", "--variant", "run")

      config = JSON.parse(env.fetch("OPENCODE_CONFIG_CONTENT"))
      expect(config.dig("mcp", "paneyard", "url")).to eq("http://127.0.0.1:3001/mcp/run")
      expect(config.dig("mcp", "paneyard", "headers", "Authorization")).to eq("Bearer tok")
    end

    it "resumes with -s" do
      _command, args, _env = described_class.build(
        driver: "opencode", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json",
        capability_token: "tok", mcp_url:, model: "a-model", resume_session_id: "oc-3"
      )

      expect(args).to include("-s", "oc-3")
    end
  end
end
