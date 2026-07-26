require "rails_helper"

RSpec.describe Orchestrator::WorkspaceAdminChatDriver::CodexProvider do
  def run(session_id: nil, model: nil, hang: false, **cli_opts)
    args_capture = Dir::Tmpname.create("codex-args") { }
    events = []
    result = nil
    pid = nil
    with_fake_admin_chat_cli(name: "codex", capture_args_to: args_capture, hang:, **cli_opts) do
      thread = Thread.new do
        described_class.run_turn(
          workspace_path: Dir.pwd, prompt: "hello", session_id:, model:, on_spawn: ->(spawned_pid) { pid = spawned_pid }
        ) { |event| events << event }
      end
      if hang
        sleep(0.3) until pid
        Orchestrator::WorkspaceAdminChatDriver::ProcessStream.kill_process_group(pid)
      end
      result = thread.value
    end
    captured_args = JSON.parse(File.read(args_capture)) if File.exist?(args_capture)
    [ result, events, captured_args ]
  end

  it "builds a fresh-turn command with --sandbox and no resume subcommand" do
    _, _, args = run(lines: [ { type: "thread.started", thread_id: "th-1" }.to_json ])

    expect(args).to include("exec", "--json", "--sandbox", "workspace-write")
    expect(args).not_to include("resume")
  end

  it "uses `exec resume <id>` and drops --sandbox when resuming (codex exec resume rejects it)" do
    _, _, args = run(session_id: "th-prior", lines: [ { type: "thread.started", thread_id: "th-prior" }.to_json ])

    expect(args[0..1]).to eq(%w[exec resume])
    expect(args).to include("th-prior")
    expect(args).not_to include("--sandbox")
  end

  it "parses thread/item/turn events into normalized events, including shell and file-change tool events" do
    result, events, = run(
      lines: [
        { type: "thread.started", thread_id: "th-9" }.to_json,
        { type: "turn.started" }.to_json,
        { type: "item.started", item: { id: "i1", type: "command_execution", command: "ls" } }.to_json,
        { type: "item.completed", item: { id: "i1", type: "command_execution", command: "ls", exit_code: 0, aggregated_output: "a.txt\n" } }.to_json,
        { type: "item.started", item: { id: "i2", type: "file_change", changes: [ { path: "/tmp/a.txt", kind: "update" } ] } }.to_json,
        { type: "item.completed", item: { id: "i2", type: "file_change", changes: [ { path: "/tmp/a.txt", kind: "update" } ] } }.to_json,
        { type: "item.completed", item: { id: "i3", type: "agent_message", text: "done" } }.to_json,
        { type: "turn.completed", usage: { input_tokens: 5 } }.to_json
      ]
    )

    types = events.map { |e| e[:type] }
    expect(types).to eq(%w[
      session_started tool_started tool_completed tool_started tool_completed file_changed assistant_completed turn_completed
    ])
    expect(events.find { |e| e[:type] == "file_changed" }[:path]).to eq("/tmp/a.txt")
    expect(result[:session_id]).to eq("th-9")
    expect(result[:error]).to be(false)
  end

  it "emits an error event for a malformed JSON line but keeps processing later valid lines" do
    result, events, = run(
      lines: [
        "{not valid json",
        { type: "thread.started", thread_id: "th-88" }.to_json,
        { type: "turn.completed", usage: {} }.to_json
      ]
    )

    expect(events.select { |e| e[:type] == "error" }).not_to be_empty
    expect(result[:session_id]).to eq("th-88")
    expect(result[:error]).to be(false)
  end

  it "reports a non-zero exit as an error without discarding a session id already observed" do
    result, events, = run(
      lines: [ { type: "thread.started", thread_id: "th-77" }.to_json ],
      exit_status: 1
    )

    expect(result[:error]).to be(true)
    expect(result[:session_id]).to eq("th-77")
    expect(events.last[:type]).to eq("error")
  end

  it "cancels a hung turn: kills the process and reports cancelled without an error" do
    result, = run(hang: true)

    expect(result[:cancelled]).to be(true)
    expect(result[:error]).to be(false)
  end

  it "recognizes codex's exact stderr line for a resume id it no longer has on disk" do
    # Confirmed verbatim against the real CLI: `codex exec resume <made-up-uuid> ...`.
    real_stderr = "Error: thread/resume: thread/resume failed: no rollout found for thread id 00000000-0000-0000-0000-000000000000 (code -32600)\n"

    expect(described_class.session_missing?(real_stderr)).to be(true)
    expect(described_class.session_missing?("some other failure")).to be(false)
    expect(described_class.session_missing?(nil)).to be(false)
  end

  it "surfaces stderr on a failed exit so Runner can classify it" do
    result, = run(exit_status: 1, lines: [], stderr_lines: [ "Error: thread/resume: thread/resume failed: no rollout found for thread id made-up (code -32600)" ])

    expect(result[:stderr]).to include("no rollout found for thread id")
    expect(described_class.session_missing?(result[:stderr])).to be(true)
  end
end
