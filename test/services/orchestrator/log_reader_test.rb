require "test_helper"

class Orchestrator::LogReaderTest < ActiveSupport::TestCase
  test "reads a complete log when no display limit is requested" do
    file = Tempfile.new("worker-log")
    file.write("a" * 20)
    file.close

    log = Orchestrator::LogReader.read_full_content(file.path)

    assert_equal "a" * 20, log[:content]
    assert_not log[:truncated]
  ensure
    file&.unlink
  end

  test "formats Claude stream JSON into readable text and commands" do
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

  test "retains incomplete streamed text at the end of a log window" do
    log = <<~LOG
      {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
      {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Still working"}}}
    LOG

    assert_equal "Still working", Orchestrator::LogReader.format_for_display(log)
  end
end
