require "rails_helper"

RSpec.describe Orchestrator::Runner::SessionArgs do
  let(:mcp_url) { "http://127.0.0.1:7263/mcp" }

  describe ".build" do
    it "rejects opencode, which it no longer launches" do
      expect do
        described_class.build(driver: "opencode", root_dir: "/tmp", mcp_config_path: "/tmp/x.json", capability_token: "t", mcp_url:, model: nil)
      end.to raise_error(ArgumentError, /unsupported driver/)
    end

    it "rejects an unknown driver" do
      expect do
        described_class.build(driver: "cursor", root_dir: "/tmp", mcp_config_path: "/tmp/x.json", capability_token: "t", mcp_url:, model: "a-model")
      end.to raise_error(ArgumentError, /unsupported driver/)
    end
  end

  describe "per-run model" do
    it "uses the model the operator picked over the driver default, for every driver" do
      { "claude" => "--model", "codex" => "--model" }.each do |driver, flag|
        _command, args = described_class.build(
          driver:, root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json", capability_token: "tok", mcp_url:,
          model: "picked-model"
        )

        expect(args.each_cons(2)).to include([ flag, "picked-model" ]), "#{driver} args: #{args.inspect}"
      end
    end

    it "leaves the model flag out when there is no model, so the CLI uses its own configured one" do
      %w[claude codex].each do |driver|
        [ nil, "codex-7" ].each do |resume_session_id|
          _command, args = described_class.build(
            driver:, root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json", capability_token: "tok", mcp_url:,
            model: nil, resume_session_id:
          )

          expect(args).not_to include("--model", "-m"), "#{driver} args: #{args.inspect}"
          expect(args).not_to include(nil)
        end
      end
    end

    it "keeps the picked model when codex resumes a session" do
      _command, args = described_class.build(
        driver: "codex", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json",
        capability_token: "tok", mcp_url:, resume_session_id: "codex-7", model: "gpt-5.5"
      )

      expect(args.each_cons(2)).to include([ "--model", "gpt-5.5" ])
    end
  end

  describe "claude" do
    it "builds an interactive command line with no headless or planner-era flags" do
      built = described_class.build(
        driver: "claude", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json", capability_token: "tok", mcp_url:, model: "a-model"
      )
      command, args = built

      expect(command).to eq("claude")
      # Only a command and its args: a session's pane gets no environment.
      expect(built.size).to eq(2)
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
      _command, args = described_class.build(
        driver: "claude", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json",
        capability_token: "tok", mcp_url:, model: "a-model", resume_session_id: "sess-42"
      )

      expect(args).to include("--resume", "sess-42")
    end

    it "writes a 0600 MCP config pointing at the run endpoint" do
      path = Rails.root.join("tmp", "session-args-spec-#{SecureRandom.hex(4)}.json").to_s
      described_class.write_claude_mcp_config(path, "tok", mcp_url:)

      config = JSON.parse(File.read(path))
      expect(config.dig("mcpServers", "paneyard", "url")).to eq("http://127.0.0.1:7263/mcp/run")
      expect(config.dig("mcpServers", "paneyard", "headers", "Authorization")).to eq("Bearer tok")
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    ensure
      File.delete(path) if path && File.exist?(path)
    end
  end

  describe "codex" do
    it "uses the bare interactive command with -s danger-full-access, never the broken bypass flag" do
      command, args = described_class.build(
        driver: "codex", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json", capability_token: "tok", mcp_url:, model: "a-model"
      )

      expect(command).to eq("codex")
      expect(args.first).not_to eq("exec")
      expect(args).to include("-s", "danger-full-access")
      # Confirmed live to break bare/interactive codex 0.147.0 outright.
      expect(args).not_to include("--dangerously-bypass-approvals-and-sandbox")
      expect(args).not_to include("-a")
      expect(args).to include("-C", "/repos/app-1")
      # The capability travels as a header override, not through the pane's env
      # (confirmed live on codex 0.159.3).
      expect(args.each_cons(2)).to include([ "-c", %(mcp_servers.paneyard.http_headers={Authorization="Bearer tok"}) ])
      expect(args.join(" ")).not_to include("bearer_token_env_var")
      expect(args).to include(%(mcp_servers.paneyard.url="http://127.0.0.1:7263/mcp/run"))
    end

    it "drops -C when resuming, which codex rejects on a resumed session" do
      _command, args = described_class.build(
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
        _command, args = described_class.build(
          driver: "codex", root_dir: "/repos/app-1", mcp_config_path: "/tmp/mcp.json",
          capability_token: "tok", mcp_url:, model: "a-model", resume_session_id:
        )

        expect(args.each_cons(2)).to include([ "-c", "check_for_update_on_startup=false" ]), "resume=#{resume_session_id.inspect}: #{args.inspect}"
      end
    end
  end
end
