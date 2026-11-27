require "rails_helper"

# A moved run's transcripts: exported from the runtime copies on the machine
# it leaves, and put where the CLI on the machine it goes to looks for its
# new worktree's conversations (Orchestrator::RunMove).
RSpec.describe Orchestrator::Runner::Transcripts, :transcripts do
  let(:root) { Dir.mktmpdir("transcripts-move-spec") }
  let(:here) { File.join(root, "here", "run_sessions") }
  let(:there) { File.join(root, "there", "run_sessions") }
  let(:claude_dir) { File.join(root, "there", "claude") }
  let(:codex_home) { File.join(root, "there", "codex") }
  let(:old_cwd) { "/home/me/.herdr/worktrees/app/paneyard-fix-a1b2" }
  let(:new_cwd) { File.join(root, "there", "worktrees", "app", "paneyard-fix-a1b2").tap { |path| FileUtils.mkdir_p(path) } }

  before do
    allow(described_class).to receive(:claude_config_dir).and_return(claude_dir)
    allow(described_class).to receive(:codex_home).and_return(codex_home)
  end

  after { FileUtils.rm_rf(root) }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def restore(transcripts)
    described_class.restore(runtime_root: there, run_id: "run-1", cwd: new_cwd, source_cwd: old_cwd, transcripts:)
  end

  it "exports every saved file, by driver and relative path, as binary" do
    saved = described_class.dir(here, "run-1")
    write(File.join(saved, "claude", "abc.jsonl"), %({"type":"user"}\n))
    write(File.join(saved, "claude", "abc", "subagents", "agent-1.jsonl"), "sub\n")
    write(File.join(saved, "codex", "rollout-2026-11-25T10-00-00-x.jsonl"), "{}\n")

    exported = described_class.export(runtime_root: here, run_id: "run-1")

    expect(exported.map { |item| [ item["driver"], item["path"] ] }).to eq([
      [ "claude", "abc.jsonl" ], [ "claude", "abc/subagents/agent-1.jsonl" ], [ "codex", "rollout-2026-11-25T10-00-00-x.jsonl" ]
    ])
    expect(exported.first["content"].encoding).to eq(Encoding::BINARY)
  end

  it "puts claude's in the project directory of the new worktree, with each line's cwd rewritten" do
    lines = [ { "type" => "user", "cwd" => old_cwd }, { "type" => "assistant", "cwd" => "#{old_cwd}/sub" }, { "type" => "x" } ]
    content = lines.map { |line| JSON.generate(line) }.join("\n") + "\nnot json\n"

    restored = restore([ { "driver" => "claude", "path" => "abc.jsonl", "content" => content.b },
                         { "driver" => "claude", "path" => "abc/subagents/agent-1.jsonl", "content" => "sub\n".b } ])

    project = File.join(claude_dir, "projects", File.realpath(new_cwd).gsub(/[^A-Za-z0-9]/, "-"))
    placed = File.read(File.join(project, "abc.jsonl")).lines
    expect(placed.first(3).map { |line| JSON.parse(line)["cwd"] }).to eq([ new_cwd, "#{new_cwd}/sub", nil ])
    expect(placed.last).to eq("not json\n")
    expect(File.read(File.join(project, "abc", "subagents", "agent-1.jsonl"))).to eq("sub\n")
    expect(restored["placed"]).to include(File.join(project, "abc.jsonl"))
    # The runtime copy is kept as it came.
    expect(File.read(File.join(described_class.dir(there, "run-1"), "claude", "abc.jsonl"))).to eq(content)
    expect(restored["skipped"]).to eq([])
  end

  it "puts codex's under the sessions day of its rollout, with session_meta's cwd rewritten" do
    meta = { "type" => "session_meta", "payload" => { "id" => "x", "cwd" => old_cwd } }
    turn = { "type" => "turn_context", "payload" => { "cwd" => old_cwd } }
    content = "#{JSON.generate(meta)}\n#{JSON.generate(turn)}\n"

    restore([ { "driver" => "codex", "path" => "rollout-2026-11-25T10-00-00-x.jsonl", "content" => content.b } ])

    placed = File.join(codex_home, "sessions", "2026", "11", "25", "rollout-2026-11-25T10-00-00-x.jsonl")
    expect(File.read(placed).lines.map { |line| JSON.parse(line).dig("payload", "cwd") }).to eq([ new_cwd, new_cwd ])
    # What save looks for on that machine from now on finds it.
    expect(described_class.codex_cwd(placed)).to eq(new_cwd)
  end

  it "skips anything that is not a plain relative path" do
    restored = restore([ { "driver" => "claude", "path" => "../../escape.jsonl", "content" => "x" },
                         { "driver" => "other", "path" => "a.jsonl", "content" => "x" } ])

    expect(restored["placed"]).to eq([])
    expect(restored["skipped"].size).to eq(2)
    expect(Dir.glob(File.join(root, "**", "escape.jsonl"))).to be_empty
  end

  it "keeps only the runtime copy in a sandbox whose root does not hold the CLI's config" do
    allow(Orchestrator::Sandbox).to receive(:enabled?).and_return(true)
    allow(PaneyardSandbox).to receive(:root).and_return(File.join(root, "there", "worktrees"))
    allow(described_class).to receive(:dir).and_return(File.join(root, "there", "worktrees", "runtime"))

    restored = restore([ { "driver" => "claude", "path" => "abc.jsonl", "content" => "{}\n" } ])

    expect(restored["placed"]).to eq([])
    expect(restored["saved"]).to eq([ File.join(root, "there", "worktrees", "runtime", "claude", "abc.jsonl") ])
    expect(restored["skipped"].join).to include("sandbox refuses")
    expect(Dir.exist?(claude_dir)).to be(false)
  end
end
