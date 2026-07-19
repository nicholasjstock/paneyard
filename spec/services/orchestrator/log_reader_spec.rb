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
end
