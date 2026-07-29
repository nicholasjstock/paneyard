require "rails_helper"

RSpec.describe Orchestrator::LogReader do
  it "extracts recent unique worker status messages from Claude stream logs" do
    file = Tempfile.new("worker-log")
    events = [
      { type: "assistant", message: { content: [ { type: "text", text: "[STATUS] Locating the phone demo." } ] } },
      { type: "assistant", message: { content: [ { type: "text", text: "[STATUS] Locating the phone demo." } ] } },
      { type: "assistant", message: { content: [ { type: "text", text: "Not a status message." } ] } },
      { type: "assistant", message: { content: [ { type: "text", text: "[STATUS] Recording the scenario now." } ] } }
    ]
    file.write(events.map(&:to_json).join("\n"))
    file.flush

    expect(described_class.progress_updates(file.path)).to eq([
      "Locating the phone demo.", "Recording the scenario now."
    ])
  ensure
    file&.close!
  end

  it "extracts Claude's final print-mode response" do
    file = Tempfile.new("worker-log")
    file.write({ type: "assistant", message: { content: [] } }.to_json << "\n")
    file.write({ type: "result", result: "Final worker explanation.", usage: {} }.to_json << "\n")
    file.flush

    expect(described_class.claude_final_response(file.path)).to eq("Final worker explanation.")
  ensure
    file&.close!
  end

  it "extracts a claude worker's own minted session id from its first init event" do
    file = Tempfile.new("worker-log")
    # Real shape confirmed live (2026-07-28) against `claude --output-format
    # stream-json --include-partial-messages --verbose -p`: only the
    # fields this method reads are included here, the rest omitted.
    file.write({ type: "system", subtype: "init", session_id: "05ca79c4-3063-4ace-8192-3a8e340a8a88" }.to_json << "\n")
    file.write({ type: "stream_event", event: { type: "message_start" } }.to_json << "\n")
    file.flush

    expect(described_class.claude_session_id(file.path)).to eq("05ca79c4-3063-4ace-8192-3a8e340a8a88")
  ensure
    file&.close!
  end

  it "returns nil for claude_session_id when no init event is present" do
    file = Tempfile.new("worker-log")
    file.write({ type: "assistant", message: { content: [] } }.to_json << "\n")
    file.flush

    expect(described_class.claude_session_id(file.path)).to be_nil
  ensure
    file&.close!
  end

  it "extracts a codex worker's own minted session id from its session_meta event" do
    file = Tempfile.new("worker-log")
    file.write({ type: "session_meta", payload: { session_id: "codex-session-abc" } }.to_json << "\n")
    file.flush

    expect(described_class.codex_session_id(file.path)).to eq("codex-session-abc")
  ensure
    file&.close!
  end

  it "ignores non-object JSON emitted in a Codex log" do
    file = Tempfile.new("worker-log")
    file.write("null\n")
    file.write({ type: "assistant", message: { content: [ { type: "text", text: "[STATUS] Still working." } ] } }.to_json << "\n")
    file.flush

    expect(described_class.progress_updates(file.path)).to eq([ "Still working." ])
    expect(described_class.format_for_display(File.read(file.path))).not_to include("null")
  ensure
    file&.close!
  end

  it "renders the complete readable history from Codex item events" do
    log = [
      { type: "item.completed", item: { type: "agent_message", text: "I am inspecting the current UI." } },
      { type: "item.started", item: { type: "mcp_tool_call", tool: "get_run_context" } },
      { type: "item.completed", item: { type: "mcp_tool_call", tool: "get_run_context" } },
      { type: "item.started", item: { type: "command_execution", command: "bin/rails test" } },
      { type: "item.completed", item: { type: "agent_message", text: "The focused test passed." } }
    ].map(&:to_json).join("\n")

    expect(described_class.format_for_display(log)).to eq(<<~DISPLAY.strip)
      I am inspecting the current UI.
      [tool] get_run_context
      $ bin/rails test
      The focused test passed.
    DISPLAY
  end
end
