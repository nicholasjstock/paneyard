require "rails_helper"

RSpec.describe Orchestrator::Runner::Transcripts, :transcripts do
  let(:root) { Dir.mktmpdir("transcripts-spec") }
  let(:runtime_root) { File.join(root, "run_sessions") }
  let(:claude_dir) { File.join(root, "claude") }
  let(:codex_home) { File.join(root, "codex") }
  let(:worktree) { File.join(root, ".herdr", "worktrees", "app", "paneyard-fix-a1b2").tap { |path| FileUtils.mkdir_p(path) } }

  before do
    allow(described_class).to receive(:claude_config_dir).and_return(claude_dir)
    allow(described_class).to receive(:codex_home).and_return(codex_home)
  end

  after { FileUtils.rm_rf(root) }

  def save(driver, since: Time.now.utc.iso8601)
    described_class.save(runtime_root:, run_id: "run-1", driver:, cwd: worktree, since:)
  end

  def write(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  describe "claude" do
    # claude names a project's directory after its cwd, with every character
    # but letters and digits turned into "-" (observed: ".herdr" -> "-herdr").
    def project_dir(path) = File.join(claude_dir, "projects", path.gsub(/[^A-Za-z0-9]/, "-"))

    it "copies the worktree's project directory beside the run's runtime files, and returns the conversations" do
      project = project_dir(File.realpath(worktree))
      write(File.join(project, "abc.jsonl"), %({"type":"user"}\n))
      write(File.join(project, "def.jsonl"))
      write(File.join(project, "abc", "subagents", "agent-1.jsonl"), "sub\n")

      saved = save("claude")

      target = File.join(runtime_root, "run-1", "transcripts", "claude")
      expect(saved).to eq([ File.join(target, "abc.jsonl"), File.join(target, "def.jsonl") ])
      expect(File.read(saved.first)).to eq(%({"type":"user"}\n))
      expect(File.read(File.join(target, "abc", "subagents", "agent-1.jsonl"))).to eq("sub\n")
    end

    it "replaces an older copy with the conversation as it is now" do
      transcript = File.join(project_dir(File.realpath(worktree)), "abc.jsonl")
      write(transcript, "one\n")
      save("claude")
      write(transcript, "one\ntwo\n")

      expect(File.read(save("claude").sole)).to eq("one\ntwo\n")
    end

    it "finds the project under the cwd as given when the filesystem resolves it differently" do
      allow(File).to receive(:realpath).and_call_original
      allow(File).to receive(:realpath).with(worktree).and_return("/private#{worktree}")
      write(File.join(project_dir(worktree), "abc.jsonl"))

      expect(save("claude").map { File.basename(it) }).to eq([ "abc.jsonl" ])
    end

    # run-20261012-174300-3933: claude never began a conversation.
    it "saves nothing, and says so, when claude kept no conversation there" do
      write(File.join(project_dir("/somewhere/else"), "abc.jsonl"))

      expect(save("claude")).to eq([])
      expect(Dir.exist?(File.join(runtime_root, "run-1", "transcripts"))).to be(false)
    end
  end

  describe "codex" do
    def rollout(day, name, cwd)
      path = File.join(codex_home, "sessions", day.strftime("%Y/%m/%d"), "rollout-#{name}.jsonl")
      write(path, "#{JSON.generate(type: 'session_meta', payload: { id: name, cwd: })}\n{\"type\":\"turn\"}\n")
      path
    end

    it "copies the rollouts whose session ran in the worktree, from the days since the session started" do
      today = Date.today
      rollout(today, "mine", File.realpath(worktree))
      rollout(today, "other", "/somewhere/else")
      rollout(today - 10, "old", File.realpath(worktree))

      saved = save("codex", since: (Time.now.utc - 3600).iso8601)

      expect(saved).to eq([ File.join(runtime_root, "run-1", "transcripts", "codex", "rollout-mine.jsonl") ])
      expect(File.read(saved.sole)).to include("session_meta", "turn")
    end

    it "skips a rollout it cannot read" do
      write(File.join(codex_home, "sessions", Date.today.strftime("%Y/%m/%d"), "rollout-broken.jsonl"), "not json\n")

      expect(save("codex")).to eq([])
    end
  end

  it "saves nothing for a driver it does not know" do
    expect(save("opencode")).to eq([])
  end
end
