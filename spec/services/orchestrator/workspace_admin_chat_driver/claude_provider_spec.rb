require "rails_helper"

RSpec.describe Orchestrator::WorkspaceAdminChatDriver::ClaudeProvider do
  def run(session_id: nil, model: nil, hang: false, **cli_opts)
    args_capture = Dir::Tmpname.create("claude-args") { }
    events = []
    result = nil
    pid = nil
    with_fake_admin_chat_cli(name: "claude", capture_args_to: args_capture, hang:, **cli_opts) do
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

  it "builds a fresh-turn command with stream-json output and no --resume" do
    _, _, args = run(
      lines: [ { type: "system", subtype: "init", session_id: "sess-1" }.to_json ]
    )

    expect(args).to include("-p", "--output-format", "stream-json", "--include-partial-messages")
    expect(args).not_to include("--resume")
  end

  it "passes --resume with the prior session id when resuming" do
    _, _, args = run(
      session_id: "prior-session",
      lines: [ { type: "system", subtype: "init", session_id: "prior-session" }.to_json ]
    )

    expect(args).to include("--resume", "prior-session")
  end

  it "parses stream-json into normalized events and captures the new session id" do
    result, events, = run(
      lines: [
        { type: "system", subtype: "init", session_id: "sess-42" }.to_json,
        { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "Hi" } } }.to_json,
        { type: "result", result: "Hi there", usage: { input_tokens: 3, output_tokens: 2 } }.to_json
      ]
    )

    expect(events.map { |e| e[:type] }).to eq(%w[session_started assistant_delta assistant_completed turn_completed])
    expect(events.first[:session_id]).to eq("sess-42")
    expect(result[:session_id]).to eq("sess-42")
    expect(result[:error]).to be(false)
  end

  it "surfaces tool_use blocks as tool_started, and Edit/Write as file_changed" do
    _, events, = run(
      lines: [
        {
          type: "assistant",
          message: { content: [ { type: "tool_use", id: "t1", name: "Edit", input: { file_path: "/tmp/a.rb" } } ] }
        }.to_json
      ]
    )

    expect(events).to include(hash_including(type: "tool_started", id: "t1", name: "Edit"))
    expect(events).to include(hash_including(type: "file_changed", path: "/tmp/a.rb"))
  end

  it "emits an error event for a malformed JSON line but keeps processing later valid lines" do
    result, events, = run(
      lines: [
        "not json at all {{{",
        { type: "system", subtype: "init", session_id: "sess-99" }.to_json,
        { type: "result", result: "done" }.to_json
      ]
    )

    error_events = events.select { |e| e[:type] == "error" }
    expect(error_events).not_to be_empty
    expect(result[:session_id]).to eq("sess-99")
    expect(result[:error]).to be(false)
  end

  it "reports a non-zero exit as an error without discarding a session id already observed" do
    result, events, = run(
      lines: [ { type: "system", subtype: "init", session_id: "sess-7" }.to_json ],
      exit_status: 1
    )

    expect(result[:error]).to be(true)
    expect(result[:session_id]).to eq("sess-7")
    expect(events.last[:type]).to eq("error")
  end

  it "cancels a hung turn: kills the process and reports cancelled without an error" do
    result, = run(hang: true)

    expect(result[:cancelled]).to be(true)
    expect(result[:error]).to be(false)
  end

  it "recognizes claude's exact stderr line for a --resume id it no longer has on disk" do
    # Confirmed verbatim against the real CLI: `claude -p --resume <made-up-uuid> ...`.
    real_stderr = "No conversation found with session ID: 00000000-0000-0000-0000-000000000000\n"

    expect(described_class.session_missing?(real_stderr)).to be(true)
    expect(described_class.session_missing?("some other failure")).to be(false)
    expect(described_class.session_missing?(nil)).to be(false)
  end

  it "surfaces stderr on a failed exit so Runner can classify it" do
    result, = run(exit_status: 1, lines: [], stderr_lines: [ "No conversation found with session ID: made-up" ])

    expect(result[:stderr]).to include("No conversation found with session ID")
    expect(described_class.session_missing?(result[:stderr])).to be(true)
  end
end
