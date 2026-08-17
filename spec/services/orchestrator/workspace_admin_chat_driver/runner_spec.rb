require "rails_helper"

RSpec.describe Orchestrator::WorkspaceAdminChatDriver::Runner do
  # A fully in-process stand-in for ClaudeProvider/CodexProvider -- the real
  # process-spawning behavior (argv, JSON parsing, cancellation, exit
  # handling) is covered directly in claude_provider_spec/codex_provider_spec.
  # This double lets Runner-level concerns (session persistence, concurrent-
  # turn prevention, cancellation bookkeeping) be tested without spawning a
  # process at all.
  class FakeProvider
    class << self
      attr_accessor :events, :result, :results, :spawn_real_process, :session_missing
      attr_reader :run_turn_calls

      # spawn_real_process gives cancel_turn! (which signals by real pid --
      # see Runner#cancel_turn!) something genuine to kill, without actually
      # spawning claude/codex: a plain `sleep` stands in for the CLI child.
      #
      # `results` is a one-shot queue so a spec can script the reconstruction
      # retry: the first call (a stale --resume) pops an error result, the
      # second (Runner's fresh-session retry) pops a success -- `result`
      # stays as the simple single-call case older specs already use.
      def run_turn(workspace_path:, prompt:, session_id:, model:, on_spawn: nil)
        (@run_turn_calls ||= []) << { workspace_path:, prompt:, session_id: }
        Array(events).each { |event| yield event }
        return spawn_and_wait(session_id, on_spawn) if spawn_real_process

        (results.presence || []).shift || result || { session_id:, cancelled: false, error: false }
      end

      def session_missing?(_stderr)
        !!session_missing
      end

      def spawn_and_wait(session_id, on_spawn)
        pid = Process.spawn("sleep", "5", pgroup: true)
        on_spawn&.call(pid)
        _pid, status = Process.wait2(pid)
        { session_id:, cancelled: status.signaled?, error: false }
      end
    end
  end

  before do
    stub_const("Orchestrator::WorkspaceAdminChatDriver::Runner::PROVIDERS", { "claude" => FakeProvider, "codex" => FakeProvider })
    FakeProvider.events = []
    FakeProvider.result = nil
    FakeProvider.results = []
    FakeProvider.spawn_real_process = false
    FakeProvider.session_missing = false
    FakeProvider.instance_variable_set(:@run_turn_calls, [])
  end

  def create_chat
    workspace = Workspace.create!(name: "admin-chat-runner-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("admin-chat-runner"))
    FileUtils.mkdir_p(File.join(workspace.root_path, "main"))
    workspace.create_workspace_admin_chat!
  end

  it "creates the user/assistant message pair and marks the chat active before enqueueing the turn job" do
    chat = create_chat

    assistant_message = nil
    expect { assistant_message = described_class.start_turn!(chat:, content: "hello") }
      .to have_enqueued_job(WorkspaceAdminChatTurnJob)

    expect(chat.reload.active?).to be(true)
    expect(chat.messages.pluck(:role)).to eq(%w[user assistant])
    expect(chat.messages.find_by(role: "user").content).to eq("hello")
    expect(assistant_message.status).to eq("running")
  end

  it "raises ConcurrentTurnError instead of starting a second turn while one is active" do
    chat = create_chat
    described_class.start_turn!(chat:, content: "first")

    expect { described_class.start_turn!(chat:, content: "second") }
      .to raise_error(described_class::ConcurrentTurnError)
    expect(chat.reload.messages.count).to eq(2)
  end

  it "persists the new session id and idles the chat on a successful turn" do
    chat = create_chat
    FakeProvider.result = { session_id: "sess-1", cancelled: false, error: false }
    assistant_message = described_class.start_turn!(chat:, content: "hi")

    described_class.perform_turn(assistant_message)

    chat.reload
    expect(chat.claude_session_id).to eq("sess-1")
    expect(chat.active_turn_id).to be_nil
    expect(chat.status).to eq("idle")
    expect(assistant_message.reload.status).to eq("completed")
  end

  it "runs the admin chat from the workspace root so sibling run worktrees are in scope" do
    chat = create_chat
    FakeProvider.result = { session_id: "sess-1", cancelled: false, error: false }
    assistant_message = described_class.start_turn!(chat:, content: "inspect every worktree")

    described_class.perform_turn(assistant_message)

    expect(FakeProvider.run_turn_calls.first[:workspace_path]).to eq(chat.workspace.root_path)
    expect(FakeProvider.run_turn_calls.first[:workspace_path]).not_to eq(chat.workspace.source_root)
  end

  # Confirmed empirically (2026-07-28): a bare `claude -p`/`codex exec` run
  # from a workspace root -- the exact cwd this driver uses -- does not
  # auto-discover CLAUDE.md/AGENTS.md the way it would from inside the
  # source checkout, since that root has no .git of its own and the
  # instructions live one level down in Workspace#source_root. A fresh
  # session must be told explicitly where to look.
  it "tells a fresh Claude session to read CLAUDE.md, not AGENTS.md" do
    chat = create_chat
    FakeProvider.result = { session_id: "sess-1", cancelled: false, error: false }
    assistant_message = described_class.start_turn!(chat:, content: "hello")

    described_class.perform_turn(assistant_message)

    sent_prompt = FakeProvider.run_turn_calls.first[:prompt]
    expect(sent_prompt).to include("#{chat.workspace.source_root}/CLAUDE.md")
    expect(sent_prompt).not_to include("AGENTS.md")
    expect(sent_prompt).to end_with("hello")
  end

  it "tells a fresh Codex session to read AGENTS.md, not CLAUDE.md" do
    chat = create_chat
    chat.update!(active_provider: "codex")
    FakeProvider.result = { session_id: "sess-1", cancelled: false, error: false }
    assistant_message = described_class.start_turn!(chat:, content: "hello")

    described_class.perform_turn(assistant_message)

    sent_prompt = FakeProvider.run_turn_calls.first[:prompt]
    expect(sent_prompt).to include("#{chat.workspace.source_root}/AGENTS.md")
    expect(sent_prompt).not_to include("CLAUDE.md")
    expect(sent_prompt).to end_with("hello")
  end

  it "does not repeat the orientation note on a session that's already resuming" do
    chat = create_chat
    chat.set_session_id!("claude", "existing-session")
    FakeProvider.result = { session_id: "existing-session", cancelled: false, error: false }
    assistant_message = described_class.start_turn!(chat:, content: "hello again")

    described_class.perform_turn(assistant_message)

    expect(FakeProvider.run_turn_calls.first[:prompt]).to eq("hello again")
  end

  it "resumes with the chat's persisted session id on the next turn" do
    chat = create_chat
    chat.set_session_id!("claude", "existing-session")
    FakeProvider.result = { session_id: "existing-session", cancelled: false, error: false }

    seen_session_id = nil
    allow(FakeProvider).to receive(:run_turn).and_wrap_original do |original, **kwargs, &block|
      seen_session_id = kwargs[:session_id]
      original.call(**kwargs, &block)
    end

    assistant_message = described_class.start_turn!(chat:, content: "again")
    described_class.perform_turn(assistant_message)

    expect(seen_session_id).to eq("existing-session")
  end

  it "does not corrupt the stored session id when a turn errors" do
    chat = create_chat
    chat.set_session_id!("claude", "existing-session")
    FakeProvider.result = { session_id: nil, cancelled: false, error: true }
    FakeProvider.events = [ { type: "error", message: "boom" } ]
    assistant_message = described_class.start_turn!(chat:, content: "hi")

    described_class.perform_turn(assistant_message)

    chat.reload
    expect(chat.claude_session_id).to eq("existing-session")
    expect(chat.status).to eq("failed")
    expect(chat.active_turn_id).to be_nil
    expect(assistant_message.reload.status).to eq("failed")
  end

  it "clears active_turn_id even when the provider raises unexpectedly" do
    chat = create_chat
    allow(FakeProvider).to receive(:run_turn).and_raise(StandardError, "unexpected")
    assistant_message = described_class.start_turn!(chat:, content: "hi")

    expect { described_class.perform_turn(assistant_message) }.to raise_error(StandardError, "unexpected")

    chat.reload
    expect(chat.active_turn_id).to be_nil
    expect(chat.status).to eq("failed")
    expect(assistant_message.reload.status).to eq("failed")
  end

  it "signals the turn's real pid on cancel and marks it cancelled once its process dies" do
    chat = create_chat
    FakeProvider.spawn_real_process = true
    assistant_message = described_class.start_turn!(chat:, content: "hi")

    turn_thread = Thread.new { described_class.perform_turn(assistant_message) }
    sleep(0.05) until assistant_message.reload.pid.present?

    expect(described_class.cancel_turn!(chat)).to be(true)
    turn_thread.join(2)

    expect(assistant_message.reload.status).to eq("cancelled")
    expect(chat.reload.active_turn_id).to be_nil
  end

  it "clears a stuck active_turn_id directly when no pid was ever recorded for it" do
    chat = create_chat
    chat.update!(active_turn_id: "orphaned-turn")

    expect(described_class.cancel_turn!(chat)).to be(false)
    expect(chat.reload.active_turn_id).to be_nil
    expect(chat.status).to eq("idle")
  end

  it "reconstructs and retries once as a fresh session when the provider reports the resumed session as gone" do
    chat = create_chat
    chat.set_session_id!("claude", "stale-session")
    FakeProvider.session_missing = true
    FakeProvider.results = [
      { session_id: nil, cancelled: false, error: true, stderr: "No conversation found with session ID: stale-session" },
      { session_id: "fresh-session", cancelled: false, error: false }
    ]

    assistant_message = described_class.start_turn!(chat:, content: "hi")
    described_class.perform_turn(assistant_message)

    expect(FakeProvider.run_turn_calls.length).to eq(2)
    expect(FakeProvider.run_turn_calls.first[:session_id]).to eq("stale-session")
    expect(FakeProvider.run_turn_calls.last[:session_id]).to be_nil

    chat.reload
    expect(chat.claude_session_id).to eq("fresh-session")
    expect(chat.status).to eq("idle")
    assistant_message.reload
    expect(assistant_message.status).to eq("completed")
    expect(assistant_message.events.map { |e| e["type"] }).to include("session_reconstructed")
  end

  it "does not reconstruct an ordinary failure that isn't a missing-session error" do
    chat = create_chat
    chat.set_session_id!("claude", "stale-session")
    FakeProvider.session_missing = false
    FakeProvider.results = [ { session_id: nil, cancelled: false, error: true, stderr: "rate limited" } ]

    assistant_message = described_class.start_turn!(chat:, content: "hi")
    described_class.perform_turn(assistant_message)

    expect(FakeProvider.run_turn_calls.length).to eq(1)
    expect(chat.reload.claude_session_id).to eq("stale-session")
    expect(assistant_message.reload.status).to eq("failed")
  end

  it "does not attempt reconstruction on a first-ever turn (nothing was being resumed)" do
    chat = create_chat
    FakeProvider.session_missing = true
    FakeProvider.results = [ { session_id: nil, cancelled: false, error: true, stderr: "gone" } ]

    assistant_message = described_class.start_turn!(chat:, content: "hi")
    described_class.perform_turn(assistant_message)

    expect(FakeProvider.run_turn_calls.length).to eq(1)
  end

  it "folds prior same-provider messages into the reconstruction prompt, each labeled by speaker" do
    chat = create_chat
    chat.set_session_id!("claude", "stale-session")
    chat.messages.create!(role: "user", provider: "claude", status: "completed", content: "earlier claude question", turn_id: SecureRandom.uuid)
    chat.messages.create!(role: "assistant", provider: "claude", status: "completed", content: "earlier claude answer", turn_id: SecureRandom.uuid)
    chat.messages.create!(role: "user", provider: "codex", status: "completed", content: "an unrelated codex message", turn_id: SecureRandom.uuid)
    FakeProvider.session_missing = true
    FakeProvider.results = [
      { session_id: nil, cancelled: false, error: true, stderr: "gone" },
      { session_id: "fresh-session", cancelled: false, error: false }
    ]

    assistant_message = described_class.start_turn!(chat:, content: "new question")
    described_class.perform_turn(assistant_message)

    reconstructed_prompt = FakeProvider.run_turn_calls.last[:prompt]
    expect(reconstructed_prompt).to include("User: earlier claude question")
    expect(reconstructed_prompt).to include("Claude: earlier claude answer")
    expect(reconstructed_prompt).to include("new question")
    expect(reconstructed_prompt).not_to include("an unrelated codex message")
  end

  it "clears a stuck active_turn_id when its recorded pid is no longer alive" do
    chat = create_chat
    dead_pid = Process.spawn("true")
    Process.wait(dead_pid)
    assistant_message = chat.messages.create!(
      role: "assistant", provider: "claude", status: "running", turn_id: SecureRandom.uuid, pid: dead_pid
    )
    chat.update!(active_turn_id: assistant_message.turn_id)

    expect(described_class.cancel_turn!(chat)).to be(false)
    expect(chat.reload.active_turn_id).to be_nil
  end
end
