require "rails_helper"

RSpec.describe Orchestrator::LogReader do
  it "reads a complete log when no display limit is requested" do
    file = Tempfile.new("worker-log")
    file.write("a" * 20)
    file.close

    log = Orchestrator::LogReader.read_full_content(file.path)

    assert_equal "a" * 20, log[:content]
    assert_not log[:truncated]
  ensure
    file&.unlink
  end

  it "formats Claude stream JSON into readable text and commands" do
    log = <<~LOG
      [workflow] spawned worker
      {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
      {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking "}}}
      {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"the log."}}}
      {"type":"stream_event","event":{"type":"content_block_stop","index":0}}
      {"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"Bash","input":{}}}}
      {"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":\\"bin/rails test\\"}"}}}
      {"type":"stream_event","event":{"type":"content_block_stop","index":1}}
    LOG

    assert_equal "[workflow] spawned worker\nChecking the log.\n$ bin/rails test", Orchestrator::LogReader.format_for_display(log)
  end

  it "retains incomplete streamed text at the end of a log window" do
    log = <<~LOG
      {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
      {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Still working"}}}
    LOG

    assert_equal "Still working", Orchestrator::LogReader.format_for_display(log)
  end

  it "extracts aggregate Claude usage from the final result event" do
    file = Tempfile.new("worker-log")
    file.write({
      type: "result", model: "claude-haiku-4-5", num_turns: 7, total_cost_usd: 0.0123,
      usage: { input_tokens: 12, output_tokens: 34, cache_read_input_tokens: 56, cache_creation_input_tokens: 78 }
    }.to_json)
    file.close

    usage = Orchestrator::LogReader.claude_usage(file.path)

    assert_equal "claude-haiku-4-5", usage[:model]
    assert_equal 7, usage[:agent_turn_count]
    assert_equal 56, usage[:cache_read_input_tokens]
  ensure
    file&.unlink
  end
end
